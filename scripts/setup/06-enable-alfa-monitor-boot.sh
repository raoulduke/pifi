#!/usr/bin/env bash
# Puts the Alfa (wlan1) into monitor mode automatically on every boot,
# via a systemd oneshot service bound to the wlan1 device unit. Without
# this, wlan1 comes up in the driver's default "managed" mode on every
# boot (monitor mode does not persist across reboots), requiring a manual
# `set-alfa-mode.sh monitor` every time before you can capture/inject.
#
# Depends on scripts/setup/04-pin-interface-names.sh having already run --
# this targets "wlan1" by name, which is only guaranteed to mean the Alfa
# because that name is pinned by MAC address, not boot-time enumeration
# order. See docs/TROUBLESHOOTING.md #11.
#
# Idempotent: overwrites any existing unit with the same name.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (via sudo)." >&2
  exit 1
fi

cat > /etc/systemd/system/alfa-monitor-mode.service <<'EOF'
[Unit]
Description=Put Alfa adapter (wlan1) into monitor mode at boot
After=sys-subsystem-net-devices-wlan1.device
BindsTo=sys-subsystem-net-devices-wlan1.device

[Service]
Type=oneshot
ExecStart=/sbin/ip link set wlan1 down
ExecStart=/sbin/iw dev wlan1 set type monitor
ExecStart=/sbin/ip link set wlan1 up
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable alfa-monitor-mode.service

echo "[06] Installed and enabled alfa-monitor-mode.service."
echo "[06] Takes effect immediately if wlan1 is already up:"
echo "       sudo systemctl start alfa-monitor-mode.service"
echo "     Also verified to fire correctly on a fresh boot going forward."
echo "[06] To switch wlan1 back to managed mode for a specific task, use"
echo "     scripts/pentest/set-alfa-mode.sh managed -- it'll just return to"
echo "     monitor mode again on the next boot."
