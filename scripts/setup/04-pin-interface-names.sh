#!/usr/bin/env bash
# Fixes docs/TROUBLESHOOTING.md #11: wlan0/wlan1 naming is assigned by
# enumeration order at boot, not fixed hardware identity. There's a race
# between the onboard chip's driver (brcmfmac) and the Alfa's USB driver
# (88XXau) attaching — most boots the onboard chip wins and becomes wlan0
# as expected, but it's not guaranteed. When the Alfa wins instead, the
# onboard chip (the intended always-up control-plane link) ends up
# unconfigured and unreachable.
#
# This pins both names permanently by MAC address via systemd-networkd
# .link files, so wlan0 always means the onboard chip and wlan1 always
# means the Alfa, regardless of attach order.
#
# Must run AFTER the Alfa's driver is installed and the adapter is
# physically connected (03-install-rtl8812au-driver.sh), since it needs to
# read the Alfa's actual MAC address — it does not hardcode a MAC, since a
# different physical Alfa unit will have a different one.
#
# Idempotent: overwrites any existing files with the same names.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (via sudo)." >&2
  exit 1
fi

# Find the onboard chip's MAC by driver name (brcmfmac), not by assuming
# it's currently called wlan0 — that's exactly the assumption this script
# exists to stop relying on.
find_mac_by_driver() {
  local driver="$1"
  local iface
  for iface in /sys/class/net/*/; do
    iface="$(basename "${iface}")"
    [[ -e "/sys/class/net/${iface}/device/driver" ]] || continue
    local drv
    drv="$(basename "$(readlink -f "/sys/class/net/${iface}/device/driver")")"
    if [[ "${drv}" == "${driver}" ]]; then
      cat "/sys/class/net/${iface}/address"
      return 0
    fi
  done
  return 1
}

ONBOARD_MAC="$(find_mac_by_driver brcmfmac || true)"
ALFA_MAC="$(find_mac_by_driver 88XXau || true)"

if [[ -z "${ONBOARD_MAC}" ]]; then
  echo "[04] ERROR: couldn't find the onboard chip (brcmfmac driver) — is it present?" >&2
  exit 1
fi
if [[ -z "${ALFA_MAC}" ]]; then
  echo "[04] ERROR: couldn't find the Alfa (88XXau driver) — is it plugged in and the" >&2
  echo "     driver loaded? Run 03-install-rtl8812au-driver.sh first." >&2
  exit 1
fi

echo "[04] Onboard chip MAC: ${ONBOARD_MAC} -> will be pinned to wlan0"
echo "[04] Alfa MAC:         ${ALFA_MAC} -> will be pinned to wlan1"

cat > /etc/systemd/network/70-wlan0-onboard.link <<EOF
[Match]
MACAddress=${ONBOARD_MAC}

[Link]
Name=wlan0
EOF

cat > /etc/systemd/network/71-wlan1-alfa.link <<EOF
[Match]
MACAddress=${ALFA_MAC}

[Link]
Name=wlan1
EOF

echo "[04] Wrote /etc/systemd/network/70-wlan0-onboard.link and 71-wlan1-alfa.link"
echo "[04] Takes effect on next boot. Reboot now to verify:"
echo "       sudo reboot"
echo "     then after it comes back: iw dev   (wlan0 should be the onboard chip,"
echo "     associated to your hotspot; wlan1 should be the Alfa)"
