#!/usr/bin/env python
"""fix-sac-python.py — make Hermes use a Python build that Windows Smart App Control allows.

The problem
-----------
Hermes v0.22.5 pins Python 3.14.9+20261021 (built 2026-10-21 — very new). Smart App Control
(SAC) judges binaries by cloud reputation, so the freshly built unicodedata.pyd / _bz2.pyd /
_zstd.pyd inside that toolchain are treated as untrusted and blocked. `uv sync` then dies while
building the editable package:

    ImportError: DLL load failed while importing unicodedata: 应用程序控制策略已阻止此文件。

An older build, 3.14.7+20260901, has already accumulated reputation and loads every module.
uv.lock declares requires-python = ">=3.11, <3.15", so 3.14.7 is perfectly legal.

Why the naive patches fail
--------------------------
Overwriting just the blocked .pyd files does not work: hermes/tools/facts.json records a tree
digest per toolchain, so any modification fails verification and pm decides Python needs
reinstalling. The digest is a *self-recorded* value, though — pm.lock.Facts.installed() only
validates version / target / artifacts. So replacing the whole tree and then recomputing the
digest with pm's own tree_digest() passes validation.

What this script does
---------------------
1. Locate the toolchain Python directory from facts.json (no hardcoded paths).
2. Make sure a SAC-allowed 3.14.7 build exists (install it with uv if needed).
3. Back up the current tree, copy 3.14.7 in.
4. Recompute the digest with pm.store.tree_digest() and write it back to facts.json.

It does NOT touch SAC settings, the Hermes source tree, or pm/lock.json.

Usage
-----
    python fix-sac-python.py

Run it with the uv-managed 3.14.7 interpreter, because the toolchain interpreter may be blocked:

    "%APPDATA%\\uv\\python\\cpython-3.14.7-windows-x86_64-none\\python.exe" fix-sac-python.py

Then relaunch the Hermes installer (close it completely first — a Retry in the same process will
not pick up any environment changes) and click "Retry install".

Note: `hermes update` moves Python back to 3.14.9 and re-breaks this. The script is idempotent;
just run it again.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys

TARGET_VERSION = "3.14.7"
SOURCE_DIRNAME = f"cpython-{TARGET_VERSION}-windows-x86_64-none"

LOCALAPPDATA = pathlib.Path(os.environ.get("LOCALAPPDATA", pathlib.Path.home() / "AppData" / "Local"))
APPDATA = pathlib.Path(os.environ.get("APPDATA", pathlib.Path.home() / "AppData" / "Roaming"))

HERMES = LOCALAPPDATA / "hermes"
REPO = HERMES / "hermes-agent"
TOOLS = HERMES / "tools"
FACTS = TOOLS / "facts.json"
SOURCE = APPDATA / "uv" / "python" / SOURCE_DIRNAME
BACKUP = HERMES / f"backup-python-before-sac-fix"


def find_uv() -> pathlib.Path | None:
    """uv ships inside the Hermes tools directory; fall back to PATH."""
    for candidate in sorted(TOOLS.glob("uv-*/uv.exe")):
        return candidate
    for name in ("uv.exe", "uv"):
        found = shutil.which(name)
        if found:
            return pathlib.Path(found)
    return None


def ensure_source() -> bool:
    if (SOURCE / "python.exe").is_file():
        return True
    uv = find_uv()
    if uv is None:
        print(f"[!] missing {SOURCE}")
        print("    and uv was not found. Install uv, then run: uv python install " + TARGET_VERSION)
        return False
    print(f"[*] {TARGET_VERSION} not installed yet, fetching with {uv}")
    result = subprocess.run([str(uv), "python", "install", TARGET_VERSION])
    if result.returncode != 0 or not (SOURCE / "python.exe").is_file():
        print(f"[!] uv python install failed (exit {result.returncode})")
        return False
    return True


def store_python_dir() -> pathlib.Path | None:
    if not FACTS.is_file():
        return None
    try:
        data = json.loads(FACTS.read_text(encoding="utf-8"))
        entry = data["packages"]["python"]["entry"]
    except (KeyError, ValueError):
        return None
    return TOOLS / entry if entry else None


def reported_version(python_exe: pathlib.Path) -> str | None:
    try:
        out = subprocess.run(
            [str(python_exe), "-c", "import sys;print('%d.%d.%d' % sys.version_info[:3])"],
            capture_output=True, text=True, timeout=30,
        )
    except Exception:
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def sac_state() -> str:
    """Best-effort read of Smart App Control state (0=off 1=enforced 2=evaluation)."""
    try:
        import winreg  # noqa: PLC0415
        with winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE,
            r"SYSTEM\CurrentControlSet\Control\CI\Policy",
        ) as key:
            value, _ = winreg.QueryValueEx(key, "VerifiedAndReputablePolicyState")
            return {0: "off", 1: "enforced", 2: "evaluation"}.get(int(value), f"unknown({value})")
    except Exception:
        return "unreadable"


def main() -> int:
    if not FACTS.is_file():
        print(f"[!] {FACTS} not found — has the Hermes install reached the venv stage yet?")
        return 1
    if not (REPO / "pm" / "store.py").is_file():
        print(f"[!] {REPO} does not look like a hermes-agent checkout")
        return 1

    state = sac_state()
    print(f"Smart App Control : {state}")
    if state in ("off", "unreadable"):
        print("    If SAC is off, this script is unnecessary — the failure has another cause.")

    target = store_python_dir()
    if target is None:
        print("[!] facts.json has no python entry")
        return 1

    if not ensure_source():
        return 1

    current = reported_version(target / "python.exe")
    print(f"toolchain dir     : {target}")
    print(f"current version   : {current or 'cannot start (most likely blocked by SAC)'}")
    print(f"target version    : {TARGET_VERSION}")

    if current != TARGET_VERSION:
        if target.exists() and not BACKUP.exists():
            shutil.move(str(target), str(BACKUP))
            print(f"[1/3] original tree backed up to {BACKUP}")
        elif target.exists():
            shutil.rmtree(target)
            print("[1/3] cleared old tree (an earlier backup is kept)")
        shutil.copytree(SOURCE, target)
        print(f"[2/3] copied {TARGET_VERSION} into place")
    else:
        print("[1/3] already on the target version, skipping the swap")

    if reported_version(target / "python.exe") != TARGET_VERSION:
        print("[!] the swapped interpreter still cannot start — SAC may be blocking this build too")
        print("    Try an older build: uv python install 3.14.6, then adjust TARGET_VERSION.")
        return 1

    sys.path.insert(0, str(REPO))
    from pm.store import tree_digest  # noqa: PLC0415

    digest = tree_digest(target)
    data = json.loads(FACTS.read_text(encoding="utf-8"))
    package = data["packages"]["python"]
    if package.get("digest") == digest:
        print("[3/3] facts.json digest already matches, nothing to change")
    else:
        shutil.copy2(FACTS, FACTS.with_suffix(".json.bak-sac"))
        package["digest"] = digest
        FACTS.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"[3/3] facts.json digest updated -> {digest}")

    print()
    print('Done. Close the Hermes installer completely, relaunch it, then click "Retry install".')
    print("Remember: `hermes update` will undo this. Re-run the script afterwards.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
