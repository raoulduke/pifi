#!/usr/bin/env bash
# Puts the Alfa (wlan1) into monitor mode automatically on every boot AND
# on every hotplug (unplug/replug without a reboot), via a systemd
# oneshot service plus a udev rule.
#
# The systemd service alone only covers boot -- WantedBy=multi-user.target
# is a boot-time dependency and does not get re-evaluated for a device
# that appears later. The udev rule is what actually covers hotplug: it
# tags the wlan1 "add" event with SYSTEMD_WANTS=alfa-monitor-mode.service,
# which systemd re-evaluates on every appearance of that device, boot or
# not. Confirmed by physically unplugging/replugging the Alfa: without
# the udev rule it came back in managed mode every time; with it, monitor
# mode every time. See docs/TROUBLESHOOTING.md #11.
#
# Depends on scripts/setup/04-pin-interface-names.sh having already run --
# this targets "wlan1" by name, which is only guaranteed to mean the Alfa
# because that name is pinned by MAC address, not boot-time enumeration
# order.
#
# Idempotent: overwrites any existing unit/rule with the same name.

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

# The udev rule is what covers hotplug -- see the header comment above
# for why the systemd unit alone isn't enough.
cat > /etc/udev/rules.d/99-alfa-monitor-mode.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="net", NAME=="wlan1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="alfa-monitor-mode.service"
EOF
udevadm control --reload

echo "[06] Installed alfa-monitor-mode.service (boot) and a udev rule (hotplug)."
echo "[06] Takes effect immediately if wlan1 is already up:"
echo "       sudo systemctl start alfa-monitor-mode.service"
echo "     Verified to fire correctly both on a fresh boot and on an actual"
echo "     unplug/replug of the Alfa going forward."
echo "[06] To switch wlan1 back to managed mode for a specific task, use"
echo "     scripts/pentest/set-alfa-mode.sh managed -- it'll return to"
echo "     monitor mode again on the next boot or hotplug."
