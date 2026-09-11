#!/usr/bin/env bash
# Fixes docs/TROUBLESHOOTING.md #5: RTL8812AU (Alfa AWUS036ACH) isn't in
# Kali's mainline kernel. Builds the out-of-tree aircrack-ng/rtl8812au
# driver via DKMS, pinned to a known-working commit.
#
# Idempotent: skips straight to "already installed" if dkms already has
# this package/version built and installed.
#
# WARNING: compiling this on a Pi Zero W's single ARM11 core takes
# roughly 2-4 hours. This script runs the actual build detached
# (nohup + disown) so an SSH disconnect during the build doesn't kill it —
# but if power to the Pi itself is lost mid-build, DKMS does NOT resume;
# just re-run this script, it'll start the build over from scratch.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (via sudo)." >&2
  exit 1
fi

REPO_URL="https://github.com/aircrack-ng/rtl8812au.git"
PINNED_COMMIT="734485506a30d6237c2deaad666a19f8ca5379f2"
CLONE_DIR="/home/kali/rtl8812au"
BUILD_LOG="/home/kali/build.log"

echo "[03] Installing build prerequisites..."
apt-get update -qq
apt-get install -y -qq build-essential dkms git bc "linux-headers-$(uname -r)" 2>&1 | tail -5 || true

if [[ ! -d "${CLONE_DIR}" ]]; then
  echo "[03] Cloning ${REPO_URL} @ ${PINNED_COMMIT}..."
  git clone "${REPO_URL}" "${CLONE_DIR}"
fi
git -C "${CLONE_DIR}" checkout "${PINNED_COMMIT}"

# Read package name/version straight from the repo's own dkms.conf rather
# than hardcoding — these are what the driver project itself calls this
# build, and hardcoding a stale value here is a worse failure mode than
# just reading it.
PKG="$(grep -oP 'PACKAGE_NAME="\K[^"]+' "${CLONE_DIR}/dkms.conf")"
VER="$(grep -oP 'PACKAGE_VERSION="\K[^"]+' "${CLONE_DIR}/dkms.conf")"
echo "[03] Package: ${PKG} / ${VER}"

STATUS="$(dkms status -m "${PKG}" -v "${VER}" 2>/dev/null || true)"
if echo "${STATUS}" | grep -q "installed"; then
  echo "[03] ${PKG}/${VER} already built and installed — skipping compile."
else
  SRC_DIR="/usr/src/${PKG}-${VER}"
  rm -rf "${SRC_DIR}"
  cp -r "${CLONE_DIR}" "${SRC_DIR}"

  dkms remove -m "${PKG}" -v "${VER}" --all 2>/dev/null || true
  dkms add -m "${PKG}" -v "${VER}"

  echo "[03] Starting detached build — this takes 2-4 hours on a Pi Zero W."
  echo "[03] Progress: tail -f ${BUILD_LOG}"
  echo "[03] Or count object files: find ${SRC_DIR} -name '*.o' | wc -l  (out of ~209 total .c files)"

  rm -f "${BUILD_LOG}"
  nohup bash -c "
    dkms build -m ${PKG} -v ${VER} 2>&1
    dkms install -m ${PKG} -v ${VER} 2>&1
    echo BUILD_SCRIPT_DONE
  " > "${BUILD_LOG}" 2>&1 < /dev/null &
  disown

  echo "[03] Build running in background (detached). This script will now"
  echo "     exit — re-run 02-... / just wait, then check:"
  echo "       grep BUILD_SCRIPT_DONE ${BUILD_LOG}"
  echo "       sudo dkms status"
  exit 0
fi

echo "[03] Loading module..."
modprobe 88XXau
if lsmod | grep -q 88XXau; then
  echo "[03] Driver loaded. iw dev should now show a second phy for the Alfa."
else
  echo "[03] WARNING: modprobe ran but module not showing in lsmod — check dmesg."
fi
