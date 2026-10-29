#!/usr/bin/env bash
#
# setup-git-mirror.sh - point the Hermes Agent repository at a working GitHub mirror
#
# The official Hermes desktop installer clones
#   https://github.com/NousResearch/hermes-agent.git
# which is unreachable on many mainland-China networks. This writes a single
# transport-level rewrite into the global git config so that clone resolves
# through a mirror. Only that one repository is affected.
#
# Because the rewrite lives in git's transport layer and git runs as a child
# process of the installer, an already-running installer picks it up immediately.
# Click "Retry install" afterwards - no restart needed.
#
# Usage:
#   ./setup-git-mirror.sh                 # apply (default mirror: gh-proxy.com)
#   ./setup-git-mirror.sh -m https://other.mirror
#   ./setup-git-mirror.sh --undo          # remove the rewrite
#   ./setup-git-mirror.sh --skip-verify   # apply without probing the mirror
#
# Verified working 2026-10-29: gh-proxy.com (main SHA matches upstream, 221 tags).

set -euo pipefail

REPO_URL="https://github.com/NousResearch/hermes-agent.git"
MIRROR="https://gh-proxy.com"
UNDO=0
SKIP_VERIFY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--mirror)   MIRROR="$2"; shift 2 ;;
    --undo)        UNDO=1; shift ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    -h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

MIRROR_BASE="${MIRROR%/}"
REWRITE_URL="${MIRROR_BASE}/${REPO_URL}"
CONFIG_KEY="url.${REWRITE_URL}.insteadOf"
GLOBAL_CONFIG="${HOME}/.gitconfig"

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m[OK] %s\033[0m\n' "$1"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$1"; }
err()  { printf '\033[31m[X] %s\033[0m\n' "$1"; }

command -v git >/dev/null 2>&1 || { err "git not found on PATH"; exit 1; }

if [ "$UNDO" -eq 1 ]; then
  step "Removing rewrite for ${REPO_URL}"
  if git config --global --get-all "$CONFIG_KEY" >/dev/null 2>&1; then
    git config --global --unset-all "$CONFIG_KEY"
    ok "Rewrite removed."
  else
    warn "No rewrite configured; nothing to undo."
  fi
  exit 0
fi

# --- backup ----------------------------------------------------------------
if [ -f "$GLOBAL_CONFIG" ]; then
  BACKUP="${GLOBAL_CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$GLOBAL_CONFIG" "$BACKUP"
  ok "Backed up git config to ${BACKUP}"
else
  warn "No existing ~/.gitconfig; a new one will be created."
fi

# --- probe the mirror before committing ------------------------------------
if [ "$SKIP_VERIFY" -eq 0 ]; then
  step "Probing mirror ${MIRROR_BASE}"

  if ! HEADS=$(git ls-remote --heads "$REWRITE_URL" main 2>&1); then
    err "Mirror does not serve this repository:"
    echo "$HEADS" >&2
    warn "Try another mirror, e.g. -m https://gitclone.com/github.com"
    warn "Note: gitclone.com has been observed to serve 0 tags, which breaks the installer."
    exit 1
  fi
  SHA=$(echo "$HEADS" | head -1 | cut -f1)
  ok "Mirror reachable, main = ${SHA}"

  TAG_COUNT=$(git ls-remote --tags --refs "$REWRITE_URL" 2>/dev/null | wc -l | tr -d ' ')
  if [ "${TAG_COUNT:-0}" -eq 0 ]; then
    warn "Mirror serves branches but NO tags."
    warn "The installer resolves a stable tag (e.g. v0.22.5) and will fail at the fetch step."
    warn "Aborting. Pick a mirror that mirrors tags too."
    exit 1
  fi
  ok "Mirror serves ${TAG_COUNT} tags"
fi

# --- apply -----------------------------------------------------------------
step "Configuring rewrite: ${REPO_URL} -> ${REWRITE_URL}"
git config --global "$CONFIG_KEY" "$REPO_URL"
ok "Rewrite applied."

# --- post-check ------------------------------------------------------------
if [ "$SKIP_VERIFY" -eq 0 ]; then
  step "Verifying through the original github.com URL"
  if git ls-remote --heads "$REPO_URL" main >/dev/null 2>&1; then
    ok "Rewrite is active - the github.com URL now resolves through the mirror."
  else
    err "Verification failed."
    exit 1
  fi
fi

echo
ok 'Done. Go back to the installer window and click "Retry install".'
echo "    The clone stage moves ~400 MB and looks frozen for several minutes. Do not close it."
echo
printf '\033[90m    To undo later:  %s --undo\033[0m\n' "$0"
