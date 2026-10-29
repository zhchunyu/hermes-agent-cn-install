# Hermes Agent — Installation Guide for Users in Mainland China

**English** | [简体中文](README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-blue.svg)](#)
[![Verified](https://img.shields.io/badge/verified-2026--10--29-brightgreen.svg)](#)

Practical, tested workarounds for installing [Nous Research Hermes Agent](https://hermes-agent.nousresearch.com)
from mainland China, where `github.com` is frequently unreachable and the official desktop
installer fails at the `git clone` stage.

Every command and every mirror in this repository was executed and measured on a real machine
(Windows 11 25H2, build 26200, AMD64) on **2026-10-29**. Nothing here is copied from a blog post.

> **Already past `git clone` and stuck further along?**
> Read [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Smart App Control blocking Python, the Electron
> binary failing to download, and electron-builder's toolchain failing to download all happen
> *after* the clone — none of them are covered here.

---

## The problem

The official desktop installer downloads `install.ps1` from GitHub (this works — `raw.githubusercontent.com`
and `api.github.com` are usually reachable), then immediately runs:

```bash
git clone --filter=blob:none --branch main \
  https://github.com/NousResearch/hermes-agent.git
```

That step requires `github.com:443`. In many mainland networks it resolves but never connects,
and a system-level HTTP proxy commonly returns `502` for `github.com` specifically while allowing
other hosts. The installer retries three times, then stops with:

```
INSTALL DIDN'T FINISH
git clone failed; no checkout published:
fatal: unable to access 'https://github.com/NousResearch/hermes-agent.git/':
Failed to connect to github.com port 443 after 2279 ms: Could not connect to server
```

---

## Quick fix

Point **only this one repository** at a working mirror, using git's transport-level URL rewrite.
No hosts file edits, no proxy, no admin rights.

```bash
git config --global \
  'url.https://gh-proxy.com/https://github.com/NousResearch/hermes-agent.git.insteadOf' \
  'https://github.com/NousResearch/hermes-agent.git'
```

Then click **Retry install** in the installer window.

The rewrite happens in git's transport layer, so **an already-running installer picks it up
immediately** — git is a child process and re-reads `~/.gitconfig` on every invocation. No restart needed.

Verify it worked without waiting for the installer:

```bash
git ls-remote --heads https://github.com/NousResearch/hermes-agent.git main
# must print a SHA, not an error
```

One-line helpers are in [`scripts/`](scripts/): `setup-git-mirror.ps1` (Windows) and
`setup-git-mirror.sh` (macOS / Linux / WSL).

### What to expect

| Stage | Duration | Notes |
|---|---|---|
| `repository` (git clone) | 3–10 min | ~400 MB working tree; the UI looks frozen — **do not close it** |
| `venv` + `python-deps` | 2–8 min | downloads from PyPI; see [PyPI](#3-pypi-is-slow-or-times-out) below |
| `products` | 5–20 min | first run downloads Electron (100+ MB) and the packaging toolchain — see [Wall 2](TROUBLESHOOTING.md#wall-2-the-electron-binary-will-not-download) |
| `setup` + `gateway` | 1–2 min | interactive; needs your model API key |

---

## Mirror benchmark

Tested with `git ls-remote`, which is the cheapest reliable probe. A mirror is only usable if
**both** conditions hold:

1. `main` SHA equals `api.github.com/repos/NousResearch/hermes-agent/commits/main` → `sha`
2. `git ls-remote --tags --refs <mirror> | wc -l` is **greater than zero**, and the wanted tag is present

> Condition 2 is the one people forget. The installer resolves the stable release (`v0.22.5`)
> and runs `git fetch origin +refs/tags/v0.22.5:refs/tags/v0.22.5`. A mirror that serves branches
> but not tags will fail *after* the clone appears to succeed.

| Mirror | Result | Detail |
|---|---|---|
| **`gh-proxy.com`** | ✅ **works** | `main` SHA matches upstream; 221 tags including `v0.22.5` |
| `gitclone.com` | ⚠️ unusable | `main` lags behind; **0 tags** — tag fetch will fail |
| `ghfast.top` | ❌ | HTTP 403 |
| `ghproxy.net` | ❌ | `expected flush after ref listing` (truncated response) |
| `kkgithub.com` | ❌ | TLS `SEC_E_WRONG_PRINCIPAL` — certificate name mismatch |
| `ghproxy.cc` | ❌ | TLS `SEC_E_CERT_EXPIRED` |
| `hub.gitmirror.com` | ❌ | DNS resolution failed |
| `github.moeyy.xyz` | ❌ | DNS resolution failed |
| `gitdl.cn` | ❌ | DNS resolution failed |
| `gh.llkk.cc` | ❌ | empty response |

Direct IP fallback, if every mirror is down. Tested with `curl --resolve`:

| IP | Result |
|---|---|
| `140.82.112.3` | ✅ HTTP 200 |
| `20.205.243.166` | ✅ HTTP 200 |
| `140.82.121.4` | ❌ timeout |
| `20.27.177.113` | ❌ timeout |

Using these means editing the hosts file, which needs administrator rights — do it only as a last
resort, and ask before you touch a system file.

---

## Approaches that do NOT work

**Downloading a tarball from `codeload.github.com`.** It gives you the source snapshot, but the
installer specifically wants a git repository with history and tags. A tarball has no `.git`
directory, so `hermes update` and the version-pinning logic both break.

**Setting `HERMES_REPO_URL`.** This environment variable *does* override the clone URL, but it has a
side effect: `Get-StableTarget` only treats the origin as "official" when it matches
`^https://github\.com/NousResearch/hermes-agent(\.git)?/?$`. Any other URL makes it skip stable
resolution and follow `main` instead. You lose the pinned release, and `hermes update` inherits the
non-official remote. Use it only if you deliberately want main.

**`git config --global http.proxy`.** If your system proxy answers `502` for `github.com`
(the common case — the proxy allowlists by domain), routing git through it changes nothing.

**Searching GitHub Releases for an installer.** There are none. Releases in
`NousResearch/hermes-agent` carry **zero assets** — they are source tags only. The Windows
(`Hermes-Setup.exe`) and macOS (`Hermes-Setup.dmg`) installers exist only on
`hermes-assets.nousresearch.com`.

---

## Other China-specific problems

These are the issues that show up *after* the clone succeeds. Listed roughly in the order you hit them.

### 1. The Windows installer is a 7.9 MB stub

`Hermes-Setup.exe` is a bootstrap installer (`apps/bootstrap-installer`), not the full application.
It downloads the runtime at install time. If that download stalls, the installer fails with no
useful error. Budget a few hundred MB of transfer.

### 2. `hermes-assets.nousresearch.com` is reachable but slow

Measured at roughly 200 KB/s from a mainland connection, versus multi-MB/s through a mirror.
The domain resolves and serves fine — it is simply not optimized for this region. Do not assume
it is blocked just because it is slow.

### 3. PyPI is slow or times out

The `python-deps` stage pulls the full dependency tree from PyPI. Switch pip to a domestic index
*before* retrying the installer, or the venv stage will crawl or fail:

```bash
pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
pip config set global.trusted-host pypi.tuna.tsinghua.edu.cn
```

The bundled runtime has its own Python; if the installer's pip ignores your user config, set the
environment variable `PIP_INDEX_URL` instead.

### 4. npm is slow (source builds only)

Only relevant if you build the Electron desktop app from source. Point npm at a domestic registry:

```bash
npm config set registry https://registry.npmmirror.com
```

### 5. MSIX packaging and SmartScreen

Windows desktop builds ship as MSIX, which requires **Windows 11 22H2 (build 22621) or newer**.
On older builds the install simply refuses. Expect a SmartScreen prompt on first launch; the
package is signed by `Nous Research Inc.` (Microsoft ID Verified), so "More info → Run anyway" is
safe — but verify the signature yourself before trusting a download:

```powershell
Get-AuthenticodeSignature .\Hermes-Setup.exe | Format-List Status, SignerCertificate
```

### 6. Model API endpoints are the real blocker

Hermes ships without a model. After installation you must configure a provider. Most Western
endpoints are unreliable from mainland China. Practical options:

- Domestic providers Hermes supports natively: Kimi / Moonshot, z.ai GLM, MiniMax, Xiaomi MiMo
- Or an OpenAI-compatible relay in front of a foreign provider

This is usually the point where a technically successful install becomes unusable, so plan for it
before you start.

### 7. Telegram / Discord / Slack gateway

The gateway process connects to these platforms directly. Without a working route they will fail
to connect; the CLI and local desktop UI still work fine.

### 8. `--filter=blob:none` needs a proxy that forwards git protocol

Partial clone is not plain HTTP file serving. Mirrors that only cache release assets
(as opposed to acting as a git smart-HTTP proxy) will break here. `gh-proxy.com` handles it.

### 9. Windows long paths

The installer passes `--long-paths`, but `core.longpaths` must also be enabled system-wide or
checkout of deep paths fails:

```bash
git config --global core.longpaths true
```

### 10. Three more walls after the clone (not covered here)

Items 1–9 above all happen around the clone. The ones that actually cost days come later:

- **Smart App Control blocks Python** — surfaces as `exit code: 0xc0e90002` or
  `ImportError: DLL load failed while importing unicodedata: 应用程序控制策略已阻止此文件。`
  It judges by build date and cloud reputation, so on the same machine a brand-new Python build
  is blocked while a two-month-old one loads fine.
- **The Electron binary will not download** — `TypeError: fetch failed`; needs `ELECTRON_MIRROR`.
- **The packaging toolchain will not download** — electron-builder **deliberately ignores**
  `ELECTRON_MIRROR` and needs its own `ELECTRON_BUILDER_BINARIES_MIRROR`.

Symptoms, diagnostic commands, and which fixes work versus which do not are all in
[**TROUBLESHOOTING.md**](TROUBLESHOOTING.md), along with two scripts:
`fix-sac-python.py` (swap the Python toolchain and recompute the digest) and
`set-electron-mirror.ps1` (set both mirror variables).

---

## Rollback

The rewrite is a persistent global git setting. Undo it with:

```bash
git config --global --unset \
  'url.https://gh-proxy.com/https://github.com/NousResearch/hermes-agent.git.insteadOf'
```

Back up `~/.gitconfig` before editing — the helper scripts do this automatically and write
`~/.gitconfig.bak-<timestamp>`.

Keeping the rewrite is usually the better choice: `hermes update` will hit the same wall next time.

---

## Scope and disclaimer

This repository documents a workaround for network conditions. It is **not** affiliated with,
endorsed by, or supported by Nous Research. Hermes Agent itself is MIT-licensed and lives at
[`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent) — go there for the
actual software, documentation, and support.

Mirror availability changes constantly. The benchmark table reflects a single measurement on
2026-10-29; if a mirror listed as working fails for you, re-run the two-condition check above
before concluding the method is broken.
