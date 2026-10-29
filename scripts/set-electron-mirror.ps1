#Requires -Version 5.1
<#
.SYNOPSIS
    Point Electron and electron-builder at domestic mirrors, so the Hermes desktop
    build can finish on networks where GitHub release downloads stall.

.DESCRIPTION
    Two different downloads fail at two different stages, and they do NOT share a
    mirror setting:

      1. The Electron runtime (~100+ MB), fetched by scripts/build/electron-runtime.mjs.
         Honours ELECTRON_MIRROR.

      2. electron-builder's own toolchain (7zip, icons, winCodeSign, .NET runtime),
         fetched during the "Packaging the desktop app" step.
         electron-builder DELIBERATELY IGNORES ELECTRON_MIRROR - see the comment in
         node_modules/app-builder-lib/dist/util/electronGet.js:
             "Use resolveAssetURL so @electron/get's ELECTRON_MIRROR env var check
              cannot override the builder-binaries URL we've already resolved"
         It only reads ELECTRON_BUILDER_BINARIES_MIRROR.

    This script sets both as user-scope environment variables and verifies the mirror
    actually serves the pinned artifacts.

    IMPORTANT: unlike the git rewrite, these are process environment variables. An
    already-running installer will NOT see them. Close it completely and relaunch.

.PARAMETER ElectronMirror
    Defaults to https://npmmirror.com/mirrors/electron/

.PARAMETER BuilderMirror
    Defaults to https://npmmirror.com/mirrors/electron-builder-binaries/

.PARAMETER Undo
    Remove both variables instead of setting them.

.PARAMETER SkipVerify
    Do not probe the mirrors.

.EXAMPLE
    .\set-electron-mirror.ps1

.EXAMPLE
    .\set-electron-mirror.ps1 -Undo
#>
[CmdletBinding()]
param(
    [string]$ElectronMirror = 'https://npmmirror.com/mirrors/electron/',
    [string]$BuilderMirror  = 'https://npmmirror.com/mirrors/electron-builder-binaries/',
    [switch]$Undo,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'

# Pinned by the version of Hermes this was written against. Bump if yours differs.
$ElectronVersion = '44.9.3'
$BuilderArtifacts = @(
    '7zip@1.0.0/7zip-win-x64.tar.gz'
    'icons@1.2.1/icons-bundle.tar.gz'
    'win-codesign@1.3.0/win-codesign-windows-x64.zip'
    'win-codesign@1.3.0/windows-kits-bundle-10_0_26100_0.zip'
    'win-codesign@1.3.0/ats-bundle-1_0_95.zip'
    'win-codesign@1.3.0/dotnet-runtime-win-x64-8_0_28.zip'
    'win-codesign@1.3.0/rcedit-windows-2_0_0.zip'
)

function Write-Step($msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "[X] $msg" -ForegroundColor Red }

function Test-Url([string]$url) {
    try {
        $response = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing `
            -MaximumRedirection 5 -TimeoutSec 30
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    } catch {
        return $false
    }
}

# --- undo ------------------------------------------------------------------
if ($Undo) {
    Write-Step 'Removing mirror environment variables'
    foreach ($name in @('ELECTRON_MIRROR', 'ELECTRON_BUILDER_BINARIES_MIRROR')) {
        $current = [Environment]::GetEnvironmentVariable($name, 'User')
        if ($current) {
            [Environment]::SetEnvironmentVariable($name, $null, 'User')
            Write-Ok "cleared $name"
        } else {
            Write-Warn2 "$name was not set"
        }
    }
    exit 0
}

# --- verify the mirrors actually have the files ----------------------------
if (-not $SkipVerify) {
    Write-Step "Checking Electron mirror for $ElectronVersion"
    $electronZip = "$($ElectronMirror.TrimEnd('/'))/$ElectronVersion/electron-v$ElectronVersion-win32-x64.zip"
    if (Test-Url $electronZip) {
        Write-Ok 'electron-v*-win32-x64.zip reachable'
    } else {
        Write-Err "Not reachable: $electronZip"
        exit 1
    }

    Write-Step 'Checking electron-builder toolchain mirror'
    $missing = @()
    foreach ($artifact in $BuilderArtifacts) {
        $url = "$($BuilderMirror.TrimEnd('/'))/$artifact"
        if (Test-Url $url) {
            Write-Ok $artifact
        } else {
            Write-Warn2 "missing: $artifact"
            $missing += $artifact
        }
    }
    if ($missing.Count -gt 0) {
        Write-Err "$($missing.Count) artifact(s) missing from $BuilderMirror"
        Write-Warn2 'Try another mirror. Note that checksums are hardcoded in electron-builder,'
        Write-Warn2 'so the mirror must serve byte-identical files, not just same-named ones.'
        exit 1
    }
    Write-Host ''
    Write-Warn2 'Existence checked only. electron-builder verifies sha256 against values compiled'
    Write-Warn2 'into app-builder-lib; if a mirror repacks files, the build fails with a checksum'
    Write-Warn2 'error instead. Compare against dist/toolsets/*.js if that happens.'
}

# --- apply -----------------------------------------------------------------
Write-Step 'Setting user environment variables'
[Environment]::SetEnvironmentVariable('ELECTRON_MIRROR', $ElectronMirror, 'User')
[Environment]::SetEnvironmentVariable('ELECTRON_BUILDER_BINARIES_MIRROR', $BuilderMirror, 'User')
Write-Ok "ELECTRON_MIRROR = $ElectronMirror"
Write-Ok "ELECTRON_BUILDER_BINARIES_MIRROR = $BuilderMirror"

Write-Host ''
Write-Err 'These are process environment variables - an already-running installer will not see them.'
Write-Host '  1. Close the Hermes installer window completely' -ForegroundColor White
Write-Host '  2. Relaunch Hermes-Setup.exe' -ForegroundColor White
Write-Host '  3. Click "Retry install"' -ForegroundColor White
Write-Host ''
Write-Host '  Clicking Retry in the existing window is NOT enough.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Artifacts are cached under <repo>\.cache\desktop-inputs\packager\, so a second' -ForegroundColor DarkGray
Write-Host '  attempt after these downloads succeed needs no network at all.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  To undo later:  .\set-electron-mirror.ps1 -Undo' -ForegroundColor DarkGray
