#!/usr/bin/env bash
# Orchestrator: runs all one-time setup steps in order, on the Pi itself.
#
# Usage (on the Pi, as the `kali` user):
#   cd pifi/scripts/setup
#   sudo ./install.sh
#
# Each numbered script is idempotent — safe to re-run individually if one
# step fails partway through. See docs/TROUBLESHOOTING.md for what each
# step is actually working around.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this with sudo: sudo ./install.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== pifi setup =="
echo "This will:"
echo "  1. Fix the persistent stale-route network bug (docs/TROUBLESHOOTING.md #6)"
echo "  2. Force an NTP resync (fixes TLS failures caused by the RTC-less clock)"
echo "  3. Build and install the RTL8812AU driver via DKMS (takes 2-4 hours on a Pi Zero W)"
echo

read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || exit 0

bash "${SCRIPT_DIR}/01-fix-network-routing.sh"
bash "${SCRIPT_DIR}/02-fix-clock.sh"
bash "${SCRIPT_DIR}/03-install-rtl8812au-driver.sh"

echo
echo "== Setup complete =="
echo "Reboot, then verify with:"
echo "  ../pentest/set-alfa-mode.sh monitor"
echo "  iw dev    # should show wlan0 (managed) and wlan1 (monitor)"
