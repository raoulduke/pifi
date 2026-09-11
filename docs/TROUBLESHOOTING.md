# Troubleshooting log

Every issue actually hit while building this, in the order encountered, with
root cause and fix. Read this even on a fresh setup — several of these are
baked into the base image/hardware and will recur unless the fixes below are
applied (which `scripts/setup/install.sh` does automatically).

---

### 1. SSH login rejected with `root`/`toor`

**Symptom:** SSH to the Pi's IP is reachable, but `root`/`toor` is rejected
from every client tried.

**Root cause:** Not a typo/credential issue — `root`/`toor` simply isn't the
credential on this image. Kali dropped root-by-default in 2020.1; current
Kali images (including pi-tail) ship a non-root `kali` user, password
`kali`, with root SSH login disabled. Per the official pi-tail docs, the
actual defaults are SSH `kali`/`kali`, VNC `toortoor`.

**Fix:** Use `kali`/`kali` over SSH. `kali` is in the `sudo` group, so `sudo
-i` gets you root from there.

---

### 2. `mobile-1`/`mobile-2` network profiles hardcoded to the wrong static IP

**Symptom:** Pi unreachable at the address expected.

**Root cause:** `/etc/network/interfaces` had `mobile-1`/`mobile-2` profiles
(matched against WiFi networks by `id_str` in
`/etc/wpa_supplicant/wpa_supplicant.conf`) hardcoded to a static IP that
didn't match the actual hotspot's DHCP range.

**Fix:** Changed both to `inet dhcp`. Note: pi-tail's *documented* default
(`192.168.43.254`, static, via the `usb0` USB-tether interface — see #7) is
also a fixed address, by design, for the direct-USB-tether path. The
mismatch here was using a WiFi hotspot (which hands out an unpredictable
DHCP range) with a profile that assumed a fixed address instead.

---

### 3. Hotspot DHCP range changes between sessions

**Symptom:** The Pi's IP is different every time you reconnect —
`192.168.108.x`, then `192.168.145.x`, then `192.168.3.x` were all observed
from the same Pixel 3 hotspot across different sessions.

**Fix:** Don't assume a fixed IP. Sweep the subnet for the Pi's MAC
(`b8:27:eb:...` for the onboard interface) instead of pinging a remembered
address. `scripts/pentest/find-pi.sh` does this.

**Pitfall:** the hotspot's own gateway address (the phone itself) will also
show up in a ping sweep and can look like a plausible candidate — check
`arp -a` / the default gateway to rule it out before assuming a swept IP is
the Pi.

---

### 4. Alfa adapter draws no power when connected through the hub

**Symptom:** Alfa's LED lights up when plugged directly into a laptop, but
not when connected via the Pi → OTG adapter → hub chain, even though the
hub's own power LED is lit.

**Root cause (this instance):** turned out to be transient — a hotspot
outage coincided with testing and made the whole chain look dead. Once
reconnected, the device enumerated normally. If it recurs and is **not**
coincidental:
- Confirm the hub itself is genuinely AC-powered, not just alive off Pi bus
  power (a hub can enumerate to the host on bus power alone without
  actually energizing downstream ports).
- Confirm you're not in a charge-only port (this hub has 4 standard USB-A
  3.0 ports plus 1 separate "Quick Charge 3.0" port that expects a
  phone-style charging handshake and may not power a plain USB peripheral).
- Confirm the OTG adapter is actually OTG-wired (see HARDWARE.md).

---

### 5. RTL8812AU driver missing — device enumerates, but no `phy#1`/`wlan1`

**Symptom:** `lsusb` shows the Alfa (`0bda:8812`), but `iw dev` only lists
the onboard chip's `phy#0`. `lsmod | grep 8812` is empty.

**Root cause:** The RTL8812AU chipset isn't in Kali's mainline kernel. It
needs the out-of-tree `aircrack-ng/rtl8812au` driver, built via DKMS against
the running kernel.

**Fix:** `scripts/setup/03-install-rtl8812au-driver.sh` — clones the driver
at a pinned commit, builds/installs via DKMS. See that script for the exact
DKMS package/version and pinned commit hash.

**Time cost:** compiling this on a Pi Zero W's single ARM11 core takes
roughly **2-4 hours**. Run it detached (`nohup ... & disown`) so it survives
an SSH disconnect, and expect to babysit it across a power/network hiccup or
two (see #6, #9).

---

### 6. Pi has no internet access despite being on the local network fine

**Symptom:** SSH works, same-subnet traffic works, DNS resolves — but
`curl`/`git clone` to anything on the internet hangs or fails.

**Root cause:** `/etc/network/interfaces` ships a `usb0` stanza (Android
USB-tethering default — this is pi-tail's **primary documented feature**,
not leftover cruft, see ARCHITECTURE.md) with a **static default route**
(`gateway 192.168.42.129`). `usb0` has no live link in this build (the USB
port is dedicated to the hub/Alfa in host mode), but ifupdown still installs
its route as the default, shadowing the real, working route via `wlan0`.
Same-subnet traffic doesn't need a gateway, so local SSH/pings work fine
while all internet-bound traffic silently goes to a dead interface.

**This is persistent, not a one-off** — it recurs on every boot because it
comes from a config file, not runtime state, and it defeated us once
already after a routing fix that was only applied live (`ip route`
commands) rather than to the file.

**Fix (permanent):** remove the `gateway 192.168.42.129` line from the
`usb0` stanza in `/etc/network/interfaces` (kept the static address line, in
case USB tethering is ever wanted alongside a different USB setup later —
just without it wrongly claiming the default route). Automated in
`scripts/setup/01-fix-network-routing.sh`.

---

### 7. TLS/`curl` failures even after internet routing is fixed

**Symptom:** `curl -sI https://github.com` returns curl exit code 60
(certificate problem) even though routing and DNS both work.

**Root cause:** Pi Zero W has no battery-backed RTC. With no internet access
(see #6), it never got to NTP-sync at boot, so the clock was stuck at
whatever it was last set to — observed over a year and a half stale. A
wrong clock breaks TLS certificate validity checks.

**Fix:** Once routing is actually fixed, force a resync:
`sudo systemctl restart systemd-timesyncd`, confirm with
`timedatectl` (`System clock synchronized: yes`). Automated in
`scripts/setup/02-fix-clock.sh`, which runs after the network fix.

---

### 8. DKMS build died mid-compile, no error — power supply failure

**Symptom:** The Pi went completely unreachable (not even ping) partway
through the multi-hour driver compile. Physical check: activity LED solid,
not blinking.

**Root cause:** the power *source* itself failed (not a software hang, not
an OOM — confirmed by physically checking the supply). Abrupt power loss
mid-write, not a clean shutdown.

**Recovery:**
- After power is restored, check `dmesg` for filesystem recovery messages —
  ext4 journal replay running automatically on remount is normal and not
  itself damage. A FAT32 boot-partition "not properly unmounted" warning is
  also expected after an abrupt cut and is low-priority to clear
  (`fsck.vfat`).
- **DKMS builds do not resume from an interrupted state.** `dkms status`
  will show the package stuck at `added` (never reached `built`/
  `installed`). Just re-run `dkms build` / `dkms install` from scratch —
  don't try to salvage partial build output.
- Solid (non-blinking) activity LED is a genuine "something's wrong" signal
  on this board — but confirm power/network status before assuming a
  software hang; in our case it was coincidental with the LED pattern
  described in a completely separate, later power failure too, so don't
  over-index on the LED alone without also checking reachability.

---

### 9. `dkms-install.sh` not found in the cloned driver repo

**Symptom:** `sudo ./dkms-install.sh` → `command not found`.

**Root cause:** the convenience installer script isn't present in every
commit/branch of `aircrack-ng/rtl8812au`. Check what's actually in the repo
(`ls *.sh`, `cat dkms.conf`) rather than assuming the installer exists.

**Fix:** do the DKMS steps manually using the package name/version from
`dkms.conf`:
```
sudo cp -r <cloned-repo> /usr/src/<PACKAGE_NAME>-<PACKAGE_VERSION>
sudo dkms add -m <PACKAGE_NAME> -v <PACKAGE_VERSION>
sudo dkms build -m <PACKAGE_NAME> -v <PACKAGE_VERSION>
sudo dkms install -m <PACKAGE_NAME> -v <PACKAGE_VERSION>
```

---

### 10. Background SSH command "killed — low memory" but process still alive

**Symptom:** A long-running SSH command shows as `killed` due to low memory
in tooling that was driving it, but the process is still visible running
locally, and the *remote* side may or may not still be alive.

**Root cause:** if the local SSH client process is killed, it sends SIGHUP
to the remote session, which normally kills the remote command too unless
the remote command was explicitly detached.

**Fix:** always run long remote builds detached on the **remote** side —
`nohup ... > logfile 2>&1 < /dev/null & disown` on the Pi — so a local
hiccup (killed tool process, dropped SSH, laptop sleep) can't take the
remote build down with it. Poll the remote log file from a fresh connection
rather than keeping one long-lived SSH session open.

---

### 11. Speeding up the DKMS compile

**Question worth pre-empting:** can background services (bluetooth, cron,
ModemManager, etc.) be stopped to speed up the build?

**Answer: no, not meaningfully.** The Pi Zero W has a single CPU core
(`nproc` = 1). Checking `ps aux --sort=-%cpu` / `/proc/loadavg` during the
build shows the compiler already at ~80-128% of the single core, with
everything else at ~0%, and load average pinned at ~1.0 — i.e. the core is
already fully committed to the build. There's no contention to reclaim.
