# After the clone: the three walls that come next

**English** | [简体中文](TROUBLESHOOTING.zh-CN.md)

The [README](README.md) covers "can't reach GitHub". This document covers what happens **after**
the clone succeeds: the system security policy blocking Python, the Electron binary failing to
download, and electron-builder's own toolchain failing to download.

Everything here comes from one real machine on 2026-10-29 (Windows 11 25H2, build 26200.9711,
Home China edition, AMD64). Every claim is backed by a log line or command output — nothing is inferred.

---

## Symptom index

| What you see | Actual cause | Jump to |
|---|---|---|
| `bootstrap Python lookup failed` / `exit code: 0xc0e90002` | Smart App Control blocked `python.exe` | [Wall 1](#wall-1-smart-app-control-blocks-python) |
| `ImportError: DLL load failed while importing unicodedata: 应用程序控制策略已阻止此文件。` | Same root cause | [Wall 1](#wall-1-smart-app-control-blocks-python) |
| `electron-runtime: preparing locked Electron 44.9.3 ... TypeError: fetch failed` | Electron binary download from GitHub | [Wall 2](#wall-2-the-electron-binary-will-not-download) |
| `✗ Packaging the desktop app failed` + `TypeError: fetch failed` | electron-builder toolset download from GitHub | [Wall 3](#wall-3-the-packaging-toolchain-and-why-electron_mirror-does-nothing) |
| Env var set but no effect | The installer process was never restarted | [Wall 4](#wall-4-env-vars-do-not-reach-an-already-running-installer) |
| `✓ Install complete!` in the log, yet the UI says failed | Publication runs after that line | [Wall 5](#wall-5-the-log-lies-install-complete-is-not-the-last-step) |

---

## Wall 1: Smart App Control blocks Python

### Symptoms

At the `venv` stage:

```
-> Downloading Python 3.14
Installed Python 3.14.9 in 6.60s
error: Failed to inspect Python interpreter from managed installations at
  ...\uv\python\cpython-3.14-windows-x86_64-none\python.exe
  cause: Querying Python ... failed with exit status exit code: 0xc0e90002
[X] bootstrap Python lookup failed
```

At the `python-deps` stage (after one retry — the problem just moves one stage later):

```
ImportError: DLL load failed while importing unicodedata: 应用程序控制策略已阻止此文件。
```

### These are the same root cause

`0xc0e90002` is **not a Python error**. The process is killed at startup by a code-integrity policy.

At first glance it looks like a transient failure — a freshly extracted `.exe` being held by
antivirus real-time scanning — so the obvious advice is "just hit Retry". **That advice is wrong.**
Retrying only moves the symptom to a later stage.

### Diagnosing it (three commands)

```powershell
# 1. SAC state: 0=off 1=enforced 2=evaluation
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -Name VerifiedAndReputablePolicyState

# 2. Who is blocking: Policy IDs in the code-integrity event log
Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -MaxEvents 50 |
  Where-Object { $_.Message -match "Policy ID" } |
  ForEach-Object { [regex]::Match($_.Message, "Policy ID:\{[0-9a-fA-F\-]+\}").Value } |
  Group-Object | Sort-Object Count -Descending

# 3. Active policy files
ls "C:\Windows\System32\CodeIntegrity\CiPolicies\Active\"
```

Measured output:

```
VerifiedAndReputablePolicyState = 1        (enforced)
Policy ID = {0283ac0f-fff1-49ae-ada1-8a933130cad6}  x 35 events
C:\Windows\System32\CodeIntegrity\CiPolicies\Active\{0283AC0F-...}.cip  present
```

`{0283ac0f-...}` is the **Smart App Control** policy ID.

### The key fact: it judges by build age, it does not block Python wholesale

This is the counter-intuitive part. Six Python installations on the same machine:

| Interpreter | Blocked modules |
|---|---|
| workbuddy 3.13.12 | `_zstd` only |
| system 3.11.9 | `_zstd` only |
| system 3.12.4 | `_zstd` only |
| uv-managed 3.14.9+20261021 | `_zstd` only |
| uv-managed 3.11.15 | `_zstd` only |
| **hermes toolchain 3.14.9+20261021** | **`unicodedata`, `_bz2`, `_zstd`** |

Now compare the same version, different build date:

| Python build | Released | Result |
|---|---|---|
| **3.14.7+20260901** | 2026-09-01 (two months old) | **all 21 modules load, zero failures** (even `_zstd`) |
| 3.14.9+20261021 | 2026-10-21 (**8 days old**) | `unicodedata` / `_bz2` / `_zstd` blocked |

SAC decides by **file hash plus cloud reputation**. There is no exclusion list and no allowlist.
A brand-new build has not accumulated reputation yet, so its `.pyd` files are rejected.
An older build has already been vouched for.

> Side note, a longer-term problem: `_zstd` is blocked in **every** Python on this machine, which
> means `compression.zstd` (new in 3.14) is unusable system-wide. Nobody notices because nothing
> touches it by default.

### Why Hermes is affected specifically

Commit `e31fa4cab9` (2026-10-22, *fix(deps): update python to 3.14.9*) moved the pin from
`3.14.7+20260901` to `3.14.9+20261021` — **seven days before the install failed**. `v0.22.5`
contains that commit.

Meanwhile `uv.lock` declares `requires-python = ">=3.11, <3.15"`, so **3.14.7 is perfectly legal**.
Nothing pins 3.14.9 except the toolchain manifest.

### Two approaches that do not work

**1. Copy a loadable DLL over the blocked one.** uv's `unicodedata.pyd` loads; Hermes' does not
(same version, same 744960 bytes, different SHA256). Overwriting it *does* make
`import unicodedata` succeed — **but** `hermes\tools\facts.json` records a tree digest per
toolchain, the modification fails verification, and pm decides Python must be reinstalled.
The patch is undone on the spot.

**2. Point Hermes at another Python.** `pm/environment.py` hardcodes
`UV_PYTHON=<its own toolchain>` plus `UV_PYTHON_DOWNLOADS="never"`, and `_base_environment()`
strips every `PYTHON*` / `UV_*` variable. There is no supported override.

### What does work: swap the toolchain tree and recompute the digest

The trick is understanding how pm verifies, otherwise you waste another round:

- `pm.store.tree_digest(entry)` hashes the whole tree
- `pm.lock.Facts.installed()` validates **only `version` / `target` / `artifacts` (sha256)**
- `digest` is **self-recorded** — it is compared against `tree_digest`, not against a signed value

So: **change only the `digest` field.** Leave `version`, `target`, and `artifacts` untouched and
identity validation still passes. That is exactly why swapping two DLLs failed while swapping the
whole tree plus recomputing the digest succeeds.

Helper script: [`scripts/fix-sac-python.py`](scripts/fix-sac-python.py)

```powershell
# Must run under the uv-managed interpreter that SAC already allows
& "$env:APPDATA\uv\python\cpython-3.14.7-windows-x86_64-none\python.exe" `
  .\scripts\fix-sac-python.py
```

The script backs up the original tree, copies 3.14.7 in, recomputes the digest with pm's own
`tree_digest()`, and writes it back to `facts.json`. It does **not** touch SAC settings, the Hermes
source tree, or `lock.json`.

> If the source interpreter is missing: `uv python install 3.14.7`

### The cost

**`hermes update` will move Python back to 3.14.9 and everything breaks again.** The script is
idempotent — just re-run it.

The only real fixes are waiting for the new build to accumulate reputation (unpredictable timing),
or installing into WSL2, where SAC does not exist.

### On "just turn SAC off"

This machine's Settings page is explicit: the `Evaluation` option is greyed out (it was already
auto-promoted to enforced), and under `Off` it reads **"if Smart App Control is turned off, it
cannot be turned back on without reinstalling Windows."**

Microsoft's support page does claim that recent updates allow re-enabling it, but this build
(26200.9711 with KB5127648 installed) does not have that change.

**Check the Settings page first: if the three options are not clickable, do not turn it off.**

---

## Wall 2: the Electron binary will not download

### Symptom

```
electron-runtime: preparing locked Electron 44.9.3 (win32-x64)...
TypeError: fetch failed
```

The installer then degrades to "build without the desktop app": TUI ✓, Web UI ✓, 58 bundled skills
synced ✓, `hermes.exe` published successfully — but the `products` stage still returns exit 1, so
the UI reports failure.

The Electron runtime is 100+ MB served from GitHub, which is effectively unreachable from many
mainland connections.

### Fix

`scripts/build/electron-runtime.mjs` passes `process.env` straight through to `install.js`
(excluding six specific keys), so `ELECTRON_MIRROR` is honoured here.

```powershell
[Environment]::SetEnvironmentVariable(
  "ELECTRON_MIRROR", "https://npmmirror.com/mirrors/electron/", "User")
```

Verify the mirror actually has the artifact:

```bash
curl -sIL "https://npmmirror.com/mirrors/electron/44.9.3/electron-v44.9.3-win32-x64.zip" \
  -o /dev/null -w "%{http_code}\n"          # expect 200
curl -sL "https://npmmirror.com/mirrors/electron/44.9.3/SHASUMS256.txt" | grep win32-x64.zip
```

### How it decides whether to download at all

`prepared()` checks exactly three things; if all are present the download is skipped:

- `node_modules/electron/path.txt` contains `electron.exe`
- `node_modules/electron/dist/version` matches the target version
- `node_modules/electron/dist/electron.exe` exists

---

## Wall 3: the packaging toolchain, and why `ELECTRON_MIRROR` does nothing

This is the sneaky one. With `ELECTRON_MIRROR` configured, the Electron binary passes and the
failure moves one step later:

```
→ Building desktop packaged app…      ✓
→ Packaging the desktop app…
✗ Packaging the desktop app failed
  TypeError: fetch failed
```

### Root cause: electron-builder deliberately ignores `ELECTRON_MIRROR`

In `node_modules/app-builder-lib/dist/util/electronGet.js`:

```js
// Use resolveAssetURL so @electron/get's ELECTRON_MIRROR env var check cannot override
// the builder-binaries URL we've already resolved (see getArtifactRemoteURL in @electron/get).
const mirrorOptions = { resolveAssetURL: async () => Promise.resolve(fullUrl) };
```

It has its own mirror variable and builds URLs as `baseUrl + releaseName + "/" + filename`:

```js
export function getBinariesMirrorUrl(githubOrgRepo) {
    for (const envVar of [
        "NPM_CONFIG_ELECTRON_BUILDER_BINARIES_MIRROR",
        "npm_config_electron_builder_binaries_mirror",
        "npm_package_config_electron_builder_binaries_mirror",
        "ELECTRON_BUILDER_BINARIES_MIRROR",
    ]) { /* ... */ }
    return `https://github.com/${githubOrgRepo}/releases/download/`;
}
```

**Defaults to GitHub. `ELECTRON_MIRROR` has zero effect here.**

### What it downloads

`app-builder-lib 27.0.0-alpha.6` on Windows needs (no overrides in the project config, so these are
the default pins):

| File | Purpose |
|---|---|
| `7zip@1.0.0/7zip-win-x64.tar.gz` | archive extraction |
| `icons@1.2.1/icons-bundle.tar.gz` | icon conversion |
| `win-codesign@1.3.0/win-codesign-windows-x64.zip` | signing tools |
| `win-codesign@1.3.0/windows-kits-bundle-10_0_26100_0.zip` | `makeappx.exe` / `signtool.exe` |
| `win-codesign@1.3.0/ats-bundle-1_0_95.zip` | ATS signing dlib |
| `win-codesign@1.3.0/dotnet-runtime-win-x64-8_0_28.zip` | matching .NET runtime |
| `win-codesign@1.3.0/rcedit-windows-2_0_0.zip` | PE resource editing |

All from the GitHub releases of `electron-userland/electron-builder-binaries`.

### Fix

```powershell
[Environment]::SetEnvironmentVariable(
  "ELECTRON_BUILDER_BINARIES_MIRROR",
  "https://npmmirror.com/mirrors/electron-builder-binaries/",
  "User")
```

Helper: [`scripts/set-electron-mirror.ps1`](scripts/set-electron-mirror.ps1) sets both variables.

### The checksums must match byte-for-byte

electron-builder hardcodes a sha256 per archive. A same-named file is not enough. Two measured
samples:

```
icons-bundle.tar.gz   193241afc7c81ab165fa0af15ef0af88f796eb69e8e5bb4249a49310d8be242a  ✓ match
7zip-win-x64.tar.gz   be071f15bd6da2f78fe81c6ddef2009b0c4d8a51f36b780cb806c7e6df95e1b3  ✓ match
```

Verify yourself:

```bash
M=https://npmmirror.com/mirrors/electron-builder-binaries
curl -sL "$M/7zip@1.0.0/7zip-win-x64.tar.gz" -o /tmp/a.tgz && sha256sum /tmp/a.tgz
grep -A9 'const checksums' node_modules/app-builder-lib/dist/toolsets/7zip.js
```

### Cache layout (for manual pre-warming)

```
<repo>/.cache/desktop-inputs/packager/
├── builder/          # = ELECTRON_BUILDER_CACHE
│   ├── 7zip@1.0.0/7zip-win-x64.tar.gz
│   ├── icons@1.2.1/icons-bundle.tar.gz
│   └── win-codesign@1.3.0/*.zip
└── electron/         # Electron archive
```

Archives live at `<releaseName>/<filename>`. If present, they are used directly with no network
round-trip — pre-warm this and the retry needs no network at all.

---

## Wall 4: env vars do not reach an already-running installer

Dumb, but it costs people several wasted retries.

`Retry install` re-runs the stages **inside the same process**. Environment variables are a snapshot
taken at process start, so **clicking Retry will not pick up newly set variables.**

You must: **close the installer window completely → relaunch `Hermes-Setup.exe` → then click Retry.**

To confirm a real restart happened, check the bootstrap start timestamp and the
`[bootstrap] downloading install.ps1 ...` line at the top of the log — both should be new.

---

## Wall 5: the log lies, `Install complete!` is not the last step

When the `products` stage fails, the log may already contain:

```
✓ Install complete! [detached @ bf0203a794]
```

That is because `products` covers both "build artifacts" and "publish commands". The first part
succeeding prints that line. **Publication runs afterwards, and if it fails the whole stage still
returns exit 1.**

So do not read `Install complete!` as success, and do not read `exit 1` as total failure. Check
whether the CLI actually got published:

```powershell
ls "$env:LOCALAPPDATA\hermes\bin\"
Get-Command hermes
```

In the measured case `hermes.exe` and `hermes-acp.exe` were fine; only `apps/desktop/dist` was
missing.

### Reading the log properly

Log: `%LOCALAPPDATA%\hermes\logs\bootstrap-installer.log`

```bash
# only the most recent run
awk '/bootstrap starting/{n=NR} {a[NR]=$0} END{for(i=n;i<=NR;i++) print a[i]}' \
  "$LOCALAPPDATA/hermes/logs/bootstrap-installer.log" | tail -80

# per-stage duration and outcome — the single most useful view
grep "stage transition" "$LOCALAPPDATA/hermes/logs/bootstrap-installer.log" | tail -20
```

The second one tells you which stage died and how long it took, without scrolling through hundreds
of progress lines.

---

## Fast triage order

1. Read the `stage transition` lines to find the failing stage
2. `repository` → network. Back to the [README](README.md)
3. `venv` / `python-deps` → most likely [Wall 1](#wall-1-smart-app-control-blocks-python); check SAC state first
4. `products` → is it `fetch failed`? Then determine whether it failed on the **Electron binary**
   or on the **packaging toolchain** (the latter logs `Packaging the desktop app failed`)
5. After changing env vars → **close and relaunch the installer**, not just Retry

---

## Rollback

```powershell
# undo the Python toolchain swap
Move-Item "$env:LOCALAPPDATA\hermes\backup-python-before-sac-fix" `
          "$env:LOCALAPPDATA\hermes\tools\<original python dir name>" -Force

# undo the mirror variables
[Environment]::SetEnvironmentVariable("ELECTRON_MIRROR", $null, "User")
[Environment]::SetEnvironmentVariable("ELECTRON_BUILDER_BINARIES_MIRROR", $null, "User")
```

`facts.json` is backed up as `facts.json.bak-sac`; restore it and run `hermes update` to return to
the official state.

---

## Disclaimer

Same as the [README](README.md): not affiliated with Nous Research. Everything here is a workaround
for specific system policies and network conditions, not officially supported behaviour. Hermes
Agent is MIT-licensed at
[`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent).
