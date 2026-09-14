#!/usr/bin/env bash
# Syncs the local pifi repo onto the Pi's copy (~/pifi there). Needed
# because that copy is rsync'd, not git-cloned -- the repo is private,
# so an anonymous `git clone` on the Pi itself fails; see
# docs/TROUBLESHOOTING.md #6/#15-adjacent notes on how the Pi's copy is
# maintained. rsync spawns its own ssh subprocess directly, which does
# NOT go through pifi.sh, so the same reachable-check-then-find-pi.sh
# fallback is duplicated here rather than relying on that script.
#
# Run from the laptop/WSL side.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_CONFIG="${HOME}/.ssh/config"
FIND_PI="${REPO_DIR}/scripts/pentest/find-pi.sh"

ip=$(awk '/^Host pifi$/{f=1} f && /HostName/{print $2; exit}' "${SSH_CONFIG}" 2>/dev/null || true)

if [[ -z "${ip}" ]] || ! timeout 3 bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null; then
  echo "pifi unreachable at ${ip:-<unset>} -- searching for it..." >&2
  bash "${FIND_PI}" --no-connect
  ip=$(awk '/^Host pifi$/{f=1} f && /HostName/{print $2; exit}' "${SSH_CONFIG}")
fi

# __pycache__/*.pyc excluded alongside .git -- attack-tui.py (Python)
# means a local `python3 -m py_compile` before syncing leaves one of
# these behind, and without an explicit exclude here it gets shipped
# to the Pi too (rsync only respects .gitignore for what IT tracks,
# not for what it's asked to sync).
rsync -avz --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --delete --delete-excluded "${REPO_DIR}/" "kali@${ip}:~/pifi/"
