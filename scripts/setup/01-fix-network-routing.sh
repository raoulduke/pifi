#!/usr/bin/env bash
# Fixes docs/TROUBLESHOOTING.md #6: a stale "gateway" line under the usb0
# stanza in /boot/firmware/interfaces installs a dead default route on
# every boot, shadowing the real route via wlan0 and silently killing
# internet access (same-subnet traffic, including SSH, keeps working,
# which makes this easy to miss).
#
# IMPORTANT: /boot/firmware/interfaces (the boot-partition template) is
# the real, persistent source of truth on this image — pi-tail.service
# copies it over /etc/network/interfaces on every single boot,
# unconditionally. Editing /etc/network/interfaces directly *looks* like
# it works (it survives until the next reboot) but silently reverts. This
# script fixes the boot-partition copy AND syncs it live, so it's both
# actually-persistent and takes effect immediately.
#
# Idempotent: does nothing if the gateway line is already gone.

set -euo pipefail

BOOT_IFACE_FILE="/boot/firmware/interfaces"
LIVE_IFACE_FILE="/etc/network/interfaces"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (via sudo)." >&2
  exit 1
fi

if [[ ! -f "${BOOT_IFACE_FILE}" ]]; then
  echo "[01] ${BOOT_IFACE_FILE} not found — is this actually a pi-tail image?" >&2
  exit 1
fi

if ! grep -q "gateway 192.168.42.129" "${BOOT_IFACE_FILE}"; then
  echo "[01] No stale usb0 gateway line found in ${BOOT_IFACE_FILE} — already fixed."
else
  BACKUP="${BOOT_IFACE_FILE}.bak.$(date +%s)"
  cp "${BOOT_IFACE_FILE}" "${BACKUP}"
  echo "[01] Backed up ${BOOT_IFACE_FILE} to ${BACKUP}"
  sed -i "/^\s*gateway 192.168.42.129/d" "${BOOT_IFACE_FILE}"
  echo "[01] Removed stale usb0 default-route line from ${BOOT_IFACE_FILE}."
fi

# Sync the fixed boot-partition copy over the live one immediately, so
# this takes effect right now without needing a reboot.
cp "${BOOT_IFACE_FILE}" "${LIVE_IFACE_FILE}"
echo "[01] Synced fixed config to ${LIVE_IFACE_FILE}."

# Clear any currently-live stale route.
if ip route show | grep -q "default via 192.168.42.129"; then
  ip route del default via 192.168.42.129 dev usb0 2>/dev/null || true
  echo "[01] Cleared live stale route."
fi

# Re-apply usb0 config (harmless — it has no real link) and make sure
# wlan0 actually claims the default route now. Some DHCP client hook
# scripts skip installing a default route if one already existed when
# the lease was granted, which can leave NO default route after manually
# deleting the bad one.
ifdown usb0 2>/dev/null || true
ifup usb0 2>/dev/null || true

if ! ip route show | grep -q "^default"; then
  echo "[01] No default route present — forcing a fresh DHCP lease on wlan0..."
  dhclient -v wlan0 2>&1 | tail -5 || true
fi

if ip route show | grep -q "^default.*wlan0"; then
  echo "[01] Default route via wlan0 confirmed."
else
  echo "[01] WARNING: still no default route via wlan0. Check 'ip route show' manually."
fi

echo "[01] Done."
