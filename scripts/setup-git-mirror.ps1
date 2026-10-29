#Requires -Version 5.1
<#
.SYNOPSIS
    Point the Hermes Agent repository at a working GitHub mirror, so the official
    desktop installer can get past its "git clone" stage on networks where
    github.com is unreachable.

.DESCRIPTION
    Writes a single git transport-level rewrite into the global git config:

        url.<mirror>/https://github.com/NousResearch/hermes-agent.git.insteadOf
            https://github.com/NousResearch/hermes-agent.git

    Only that one repository is affected. No hosts file edits, no proxy, no admin rights.

    Because the rewrite lives in git's transport layer and git is invoked as a child
    process by the installer, an already-running installer picks it up immediately.
    Click "Retry install" afterwards - no restart needed.

.PARAMETER Mirror
    Mirror base URL. Defaults to https://gh-proxy.com (verified working 2026-10-29).

.PARAMETER Undo
    Remove the rewrite instead of adding it.

.PARAMETER SkipVerify
    Do not run the post-change connectivity probe.

.EXAMPLE
    .\setup-git-mirror.ps1

.EXAMPLE
    .\setup-git-mirror.ps1 -Undo
#>
[CmdletBinding()]
param(
    [string]$Mirror = 'https://gh-proxy.com',
    [switch]$Undo,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'

$RepoUrl = 'https://github.com/NousResearch/hermes-agent.git'
$MirrorBase = $Mirror.TrimEnd('/')
$RewriteUrl = "$MirrorBase/$RepoUrl"
$ConfigKey = "url.$RewriteUrl.insteadOf"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[X] $msg" -ForegroundColor Red }

# --- preflight -------------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Err 'git not found on PATH. Install Git for Windows first.'
    exit 1
}

$globalConfig = Join-Path $HOME '.gitconfig'

# --- undo path -------------------------------------------------------------
if ($Undo) {
    Write-Step "Removing rewrite for $RepoUrl"
    $existing = git config --global --get-all $ConfigKey 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $existing) {
        Write-Warn2 'No rewrite configured; nothing to undo.'
        exit 0
    }
    git config --global --unset-all $ConfigKey
    if ($LASTEXITCODE -ne 0) { Write-Err 'Failed to remove rewrite.'; exit 1 }
    Write-Ok 'Rewrite removed.'
    exit 0
}

# --- backup ----------------------------------------------------------------
if (Test-Path $globalConfig) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$globalConfig.bak-$stamp"
    Copy-Item $globalConfig $backup -Force
    Write-Ok "Backed up git config to $backup"
} else {
    Write-Warn2 'No existing ~/.gitconfig; a new one will be created.'
}

# --- probe the mirror before committing to it ------------------------------
if (-not $SkipVerify) {
    Write-Step "Probing mirror $MirrorBase"
    $probe = git ls-remote --heads $RewriteUrl main 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Mirror does not serve this repository: $probe"
        Write-Warn2 'Try another mirror, e.g. -Mirror https://gitclone.com/github.com'
        Write-Warn2 'Note: gitclone.com has been observed to serve 0 tags, which breaks the installer.'
        exit 1
    }
    $sha = ($probe | Out-String).Trim().Split("`n")[0].Split("`t")[0]
    Write-Ok "Mirror reachable, main = $sha"

    $tagCount = 0
    $tags = git ls-remote --tags --refs $RewriteUrl 2>$null
    if ($LASTEXITCODE -eq 0 -and $tags) {
        $tagCount = @($tags).Count
    }
    if ($tagCount -eq 0) {
        Write-Warn2 'Mirror serves branches but NO tags.'
        Write-Warn2 'The installer resolves a stable tag (e.g. v0.22.5) and will fail at the fetch step.'
        Write-Warn2 'Aborting. Pick a mirror that mirrors tags too.'
        exit 1
    }
    Write-Ok "Mirror serves $tagCount tags"
}

# --- apply -----------------------------------------------------------------
Write-Step "Configuring rewrite: $RepoUrl -> $RewriteUrl"
git config --global $ConfigKey $RepoUrl
if ($LASTEXITCODE -ne 0) { Write-Err 'git config failed.'; exit 1 }
Write-Ok 'Rewrite applied.'

# --- post-check ------------------------------------------------------------
if (-not $SkipVerify) {
    Write-Step 'Verifying through the original github.com URL'
    $check = git ls-remote --heads $RepoUrl main 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'Rewrite is active - the github.com URL now resolves through the mirror.'
    } else {
        Write-Err "Verification failed: $check"
        exit 1
    }
}

Write-Host ''
Write-Ok 'Done. Go back to the installer window and click "Retry install".'
Write-Host '    The clone stage moves ~400 MB and looks frozen for several minutes. Do not close it.'
Write-Host ''
Write-Host "    To undo later:  .\setup-git-mirror.ps1 -Undo" -ForegroundColor DarkGray
