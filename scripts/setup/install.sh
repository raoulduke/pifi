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
echo "     -- edits /boot/firmware/interfaces, the REAL persistent source on this"
echo "        image, not /etc/network/interfaces directly (see TROUBLESHOOTING.md #6"
echo "        for why editing only the /etc/ copy silently reverts every boot)"
echo "  2. Force an NTP resync (fixes TLS failures caused by the RTC-less clock)"
echo "  3. Build and install the RTL8812AU driver via DKMS (takes 2-4 hours on a Pi Zero W)"
echo "  4. Pin wlan0/wlan1 to fixed names by MAC address (docs/TROUBLESHOOTING.md #11"
echo "     -- without this, which physical adapter gets called wlan0 vs wlan1 is a"
echo "        boot-time race, and it can silently disconnect the intended"
echo "        control-plane interface)"
echo "  5. Enable persistent mDNS, so the Pi is reachable at"
echo "     <hostname>.local instead of needing to look up its current IP --"
echo "     matters most for phone-only operation with no laptop to run a"
echo "     network sweep from"
echo "  6. (manual follow-up, after driver build + hardware connected) Enable"
echo "     alfa-monitor-mode.service, so wlan1 boots straight into monitor"
echo "     mode instead of needing a manual set-alfa-mode.sh every time"
echo

read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || exit 0

bash "${SCRIPT_DIR}/01-fix-network-routing.sh"
bash "${SCRIPT_DIR}/02-fix-clock.sh"
bash "${SCRIPT_DIR}/05-enable-mdns.sh"
bash "${SCRIPT_DIR}/03-install-rtl8812au-driver.sh"

echo
echo "== Driver build launched in the background =="
echo "Once it finishes (grep BUILT_MODULE_NAME... or check: sudo dkms status),"
echo "run separately:"
echo "  sudo ${SCRIPT_DIR}/04-pin-interface-names.sh"
echo "  sudo reboot"
echo
echo "Then, once the Alfa is plugged in and its driver bound:"
echo "  sudo ${SCRIPT_DIR}/06-enable-alfa-monitor-boot.sh"
echo
echo "Then verify with:"
echo "  iw dev    # should show wlan0 (managed, onboard, associated to your"
echo "            # hotspot) and wlan1 (Alfa, monitor -- automatically, no"
echo "            # manual set-alfa-mode.sh needed anymore)"
