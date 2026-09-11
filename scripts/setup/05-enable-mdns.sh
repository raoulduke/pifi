#!/usr/bin/env bash
# Sets a short hostname and enables persistent mDNS (.local) resolution,
# so the Pi can be reached at pitail.local instead of hunting for its
# current IP -- or typing the stock image's default hostname
# (kali-raspberry-pi-zero-w-pitail), which is impractically long to type
# on a phone keyboard. Matters most for phone-only operation -- see
# docs/SETUP.md "Phone-only operation (as pi-tail intends)".
#
# avahi-daemon ships installed on this image but inactive by default.
#
# Idempotent: safe to re-run.

set -euo pipefail

HOSTNAME_SHORT="pitail"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (via sudo)." >&2
  exit 1
fi

CURRENT="$(hostname)"
if [[ "${CURRENT}" != "${HOSTNAME_SHORT}" ]]; then
  echo "[05] Renaming host: ${CURRENT} -> ${HOSTNAME_SHORT}"
  hostnamectl set-hostname "${HOSTNAME_SHORT}"
  sed -i "s/${CURRENT}/${HOSTNAME_SHORT}/g" /etc/hosts
else
  echo "[05] Hostname already ${HOSTNAME_SHORT} — skipping rename."
fi

systemctl enable --now avahi-daemon
systemctl restart avahi-daemon  # picks up the new hostname if just renamed

if systemctl is-active --quiet avahi-daemon; then
  echo "[05] avahi-daemon active. Reachable at: ${HOSTNAME_SHORT}.local"
else
  echo "[05] WARNING: avahi-daemon did not start. Check 'systemctl status avahi-daemon'." >&2
  exit 1
fi
