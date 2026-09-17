#!/usr/bin/env bash
# Closes the residual race left by 04-pin-interface-names.sh (see
# docs/TROUBLESHOOTING.md #11). The MAC-pinned .link files usually get
# wlan0/wlan1 right, but if both the onboard chip and the Alfa already
# claimed conflicting kernel-default names before udev got to apply the
# .link rename, the rename deadlocks ("File exists" -- neither can move
# to the other's current name) and can sit wrong for minutes, or
# indefinitely, until something else happens to re-trigger a udev event.
# Confirmed happening live: onboard/Alfa took ~32 minutes to
# self-correct on one boot.
#
# This installs a oneshot service that runs after udev has settled and,
# only if the names are still wrong, corrects them via a two-phase
# rename through unique scratch names -- which never collides, unlike a
# direct swap. It's ordered strictly BEFORE ifup@wlan0.service,
# ifup@wlan1.service, and alfa-monitor-mode.service, i.e. before either
# interface has been given an IP or used for networking at all. That
# ordering is what makes this safe to install: there is no live
# SSH session or traffic on either interface yet when the rename runs.
#
# Depends on scripts/setup/04-pin-interface-names.sh having already run
# -- this reads the MACs straight out of its .link files as the single
# source of truth, rather than re-deriving them.
#
# Idempotent: overwrites any existing script/unit with the same name.
# Takes effect on next boot -- does NOT touch live interfaces when run.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (via sudo)." >&2
  exit 1
fi

LINK_DIR=/etc/systemd/network
if [[ ! -f "${LINK_DIR}/70-wlan0-onboard.link" || ! -f "${LINK_DIR}/71-wlan1-alfa.link" ]]; then
  echo "[07] ERROR: ${LINK_DIR}/70-wlan0-onboard.link and/or 71-wlan1-alfa.link" >&2
  echo "     not found. Run scripts/setup/04-pin-interface-names.sh first." >&2
  exit 1
fi

cat > /usr/local/sbin/fix-wlan-names.sh <<'EOF'
#!/usr/bin/env bash
# Self-healing pass for the wlan0/wlan1 naming race -- see the header
# comment in scripts/setup/07-fix-wlan-name-race.sh in the pifi repo for
# the full explanation. Safe by construction: this only ever runs before
# ifup@wlan0.service / ifup@wlan1.service / alfa-monitor-mode.service, so
# neither interface has an IP or active traffic yet when it renames them.

set -euo pipefail

LINK_DIR=/etc/systemd/network
ONBOARD_MAC="$(grep -oP 'MACAddress=\K.*' "${LINK_DIR}/70-wlan0-onboard.link")"
ALFA_MAC="$(grep -oP 'MACAddress=\K.*' "${LINK_DIR}/71-wlan1-alfa.link")"

find_iface_by_mac() {
  local mac="$1" iface addr
  for iface in /sys/class/net/*/; do
    iface="$(basename "${iface}")"
    addr="$(cat "/sys/class/net/${iface}/address" 2>/dev/null || true)"
    if [[ "${addr,,}" == "${mac,,}" ]]; then
      echo "${iface}"
      return 0
    fi
  done
  return 1
}

# The Alfa enumerates over USB and can take longer than the onboard SDIO
# chip to show up -- wait for it rather than failing outright.
ONBOARD_IFACE=""
ALFA_IFACE=""
for _ in $(seq 1 30); do
  ONBOARD_IFACE="$(find_iface_by_mac "${ONBOARD_MAC}" || true)"
  ALFA_IFACE="$(find_iface_by_mac "${ALFA_MAC}" || true)"
  [[ -n "${ONBOARD_IFACE}" && -n "${ALFA_IFACE}" ]] && break
  sleep 1
done

if [[ -z "${ONBOARD_IFACE}" || -z "${ALFA_IFACE}" ]]; then
  echo "[fix-wlan-names] Timed out waiting for both adapters to appear -- onboard='${ONBOARD_IFACE}' alfa='${ALFA_IFACE}'. Leaving names as-is." >&2
  exit 0
fi

if [[ "${ONBOARD_IFACE}" == "wlan0" && "${ALFA_IFACE}" == "wlan1" ]]; then
  echo "[fix-wlan-names] Already correct (onboard=wlan0, alfa=wlan1). Nothing to do."
  exit 0
fi

echo "[fix-wlan-names] Names are swapped (onboard=${ONBOARD_IFACE}, alfa=${ALFA_IFACE}) -- correcting via scratch names."

# Two-phase rename through unique scratch names: neither rename ever
# targets a name the other interface currently holds, which is exactly
# what deadlocks with "File exists" in a direct swap.
ip link set dev "${ONBOARD_IFACE}" down
ip link set dev "${ALFA_IFACE}" down
ip link set dev "${ONBOARD_IFACE}" name tmp-onboard
ip link set dev "${ALFA_IFACE}" name tmp-alfa
ip link set dev tmp-onboard name wlan0
ip link set dev tmp-alfa name wlan1

echo "[fix-wlan-names] Corrected: onboard is now wlan0, Alfa is now wlan1."
EOF
chmod +x /usr/local/sbin/fix-wlan-names.sh

cat > /etc/systemd/system/fix-wlan-names.service <<'EOF'
[Unit]
Description=Correct wlan0/wlan1 naming if the onboard/Alfa naming race left them swapped
After=systemd-udev-settle.service
Before=network-pre.target ifup@wlan0.service ifup@wlan1.service alfa-monitor-mode.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/fix-wlan-names.sh

[Install]
WantedBy=network-pre.target
EOF

systemctl daemon-reload
systemctl enable fix-wlan-names.service

echo "[07] Installed fix-wlan-names.service (runs after udev settles, before"
echo "     either interface is used for networking)."
echo "[07] Takes effect on next boot -- does NOT touch live interfaces now."
echo "[07] Do NOT run /usr/local/sbin/fix-wlan-names.sh manually over an active"
echo "     wlan0 SSH session: it brings wlan0 down as part of the rename check,"
echo "     which would drop your connection. To verify, reboot and check:"
echo "       iw dev   (wlan0 should be the onboard chip, wlan1 the Alfa)"
echo "       journalctl -u fix-wlan-names.service -b"
