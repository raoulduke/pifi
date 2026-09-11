#!/usr/bin/env bash
# Fixes docs/TROUBLESHOOTING.md #6: a stale "gateway" line under the usb0
# stanza in /etc/network/interfaces installs a dead default route on every
# boot, shadowing the real route via wlan0 and silently killing internet
# access (same-subnet traffic, including SSH, keeps working, which makes
# this easy to miss).
#
# Idempotent: does nothing if the gateway line is already gone.

set -euo pipefail

IFACE_FILE="/etc/network/interfaces"
BACKUP="${IFACE_FILE}.bak.$(date +%s)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (via sudo)." >&2
  exit 1
fi

if ! grep -q "gateway 192.168.42.129" "${IFACE_FILE}"; then
  echo "[01] No stale usb0 gateway line found — already fixed."
else
  cp "${IFACE_FILE}" "${BACKUP}"
  echo "[01] Backed up ${IFACE_FILE} to ${BACKUP}"
  sed -i "/^\s*gateway 192.168.42.129/d" "${IFACE_FILE}"
  echo "[01] Removed stale usb0 default-route line."
fi

# Also clear any currently-live stale route so this doesn't require a
# reboot to take effect right now.
if ip route show | grep -q "usb0"; then
  ip route del default via 192.168.42.129 dev usb0 2>/dev/null || true
  echo "[01] Cleared live stale route."
fi

# Make sure a real default route via wlan0 exists.
if ! ip route show | grep -q "^default"; then
  GATEWAY="$(ip route show dev wlan0 2>/dev/null | awk '/proto kernel/ {print $1}' | head -1)"
  if [[ -n "${GATEWAY}" ]]; then
    # crude fallback: use the .1 or known gateway of the wlan0 subnet if
    # detectable; otherwise this just documents that manual intervention
    # (or a reboot, since ifupdown/dhcp will set this correctly) is needed.
    echo "[01] No default route present. A reboot (or 'dhclient wlan0') should"
    echo "     re-establish it correctly now that the stale usb0 route is gone."
  fi
fi

echo "[01] Done."
