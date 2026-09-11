#!/usr/bin/env bash
# Enables persistent mDNS (.local hostname) resolution, so the Pi can be
# reached at kali-raspberry-pi-zero-w-pitail.local instead of hunting for
# its current IP on every connect. This matters most for phone-only
# operation (no laptop to run a network sweep from) -- see
# docs/SETUP.md "Phone-only operation (as pi-tail intends)".
#
# avahi-daemon ships installed on this image but inactive by default.
#
# Idempotent: systemctl enable --now is a no-op if already enabled/active.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (via sudo)." >&2
  exit 1
fi

systemctl enable --now avahi-daemon

if systemctl is-active --quiet avahi-daemon; then
  echo "[05] avahi-daemon active. Reachable at: $(hostname).local"
else
  echo "[05] WARNING: avahi-daemon did not start. Check 'systemctl status avahi-daemon'." >&2
  exit 1
fi
