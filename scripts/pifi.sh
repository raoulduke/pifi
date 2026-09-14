#!/usr/bin/env bash
# Connects to the pi-tail Pi via its "pifi" SSH alias, checking
# reachability first and falling back to pentest/find-pi.sh's network
# sweep when the alias's cached IP is stale.
#
# Run from the laptop/WSL side.
#
# Usage: pifi.sh [ssh-args...]   (any extra args are passed through to ssh)

set -euo pipefail

SSH_CONFIG="${HOME}/.ssh/config"
FIND_PI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pentest/find-pi.sh"

ip=$(awk '/^Host pifi$/{f=1} f && /HostName/{print $2; exit}' "${SSH_CONFIG}" 2>/dev/null || true)

if [[ -n "${ip}" ]] && timeout 3 bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null; then
  exec ssh pifi "$@"
else
  echo "pifi unreachable at ${ip:-<unset>} -- searching for it..." >&2
  exec bash "${FIND_PI}"
fi
