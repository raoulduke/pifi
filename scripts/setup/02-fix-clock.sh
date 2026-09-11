#!/usr/bin/env bash
# Fixes docs/TROUBLESHOOTING.md #7: Pi Zero W has no battery-backed RTC.
# Without internet access at boot (see 01-fix-network-routing.sh), it can
# never NTP-sync, so the clock drifts to whatever it was last set to —
# which breaks TLS certificate validation for anything using HTTPS (apt,
# git clone, curl, etc.) with confusing, unrelated-looking errors.
#
# Must run AFTER network routing is fixed, or the resync will just fail
# again for the same underlying reason.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (via sudo)." >&2
  exit 1
fi

echo "[02] Restarting systemd-timesyncd..."
systemctl restart systemd-timesyncd
sleep 5

if timedatectl show -p NTPSynchronized --value | grep -q "yes"; then
  echo "[02] Clock synchronized: $(date)"
else
  echo "[02] WARNING: clock did not sync. Check network connectivity first"
  echo "     (run 01-fix-network-routing.sh, confirm 'curl -I https://github.com' works)."
  exit 1
fi
