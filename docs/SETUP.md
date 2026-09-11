# Setup

Step-by-step to recreate this exact working setup on a new Pi Zero W. For
*why* each step exists, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — this
doc is the "what to do," that one is the "why it's necessary."

## 1. Flash and boot

1. Download the Kali pi-tail image:
   **https://old.kali.org/arm-images/kali-2025.2/kali-linux-2025.2-raspberry-pi-zero-w-pitail-armel.img.xz**

   This is **not** on the current kali.org downloads page — pi-tail builds
   live on the `old.kali.org` ARM images mirror. If 2025.2 is no longer the
   current release, browse
   `https://old.kali.org/arm-images/` for the equivalent
   `-raspberry-pi-zero-w-pitail-armel.img.xz` under whatever version
   directory exists, using the same filename pattern.
2. Flash it to a microSD card (Raspberry Pi Imager's "Use custom image," or
   `dd`/Etcher directly onto the `.img` after decompressing the `.xz`).
3. Boot the Pi with just power connected (no hub/Alfa yet) and get it on
   your WiFi hotspot far enough to SSH in:
   - SSH: `kali` / `kali`
   - The onboard chip is `wlan0` — this stays as the control-plane link for
     the entire life of this setup.

## 2. Copy this repo onto the Pi and run setup

```
git clone <this-repo-url> pifi
cd pifi/scripts/setup
sudo ./install.sh
```

This runs, in order:
1. `01-fix-network-routing.sh` — removes the stale `usb0` default route
   that otherwise breaks internet access on every boot. Fixes
   `/boot/firmware/interfaces` (the actual persistent source on this
   image — **not** `/etc/network/interfaces`, which gets silently
   overwritten from the boot partition on every boot; see
   [TROUBLESHOOTING.md #6](TROUBLESHOOTING.md)) and syncs it live.
2. `02-fix-clock.sh` — forces an NTP resync (the Pi Zero W has no RTC and
   can drift wildly without internet access to correct it, which breaks
   TLS).
3. `03-install-rtl8812au-driver.sh` — builds and installs the Alfa's
   driver via DKMS. **Budget 2-4 hours** for this on a Pi Zero W's single
   core. It runs detached, so you can disconnect and check back later —
   see the script's own output for how to check progress.

Once the driver build finishes (`sudo dkms status` shows `installed`) **and
the Alfa is physically connected** (step 3, below — do that first if you
haven't), run the remaining step separately. `install.sh` doesn't wait
around for the multi-hour build or for you to plug in hardware, so this
has to be a manual follow-up:
```
sudo scripts/setup/04-pin-interface-names.sh
sudo reboot
```
4. `04-pin-interface-names.sh` — pins `wlan0`/`wlan1` to fixed names by MAC
   address. Without this, which physical adapter ends up named `wlan0` vs
   `wlan1` is a boot-time race that can silently disconnect the intended
   control-plane interface — see
   [TROUBLESHOOTING.md #11](TROUBLESHOOTING.md). **Reboot after running
   this** to confirm it actually took effect; don't just trust that it
   silently worked.

## 3. Assemble the USB hardware chain

With the Pi still powered from step 1/2, connect (see
[HARDWARE.md](HARDWARE.md) for the exact connector types):

```
Pi (Micro-USB data port)
  → Micro-USB OTG adapter
  → Hub's USB-A cable end
  → Hub (own 12V/2A wall adapter — power this on)
  → Hub downstream USB-A port
  → USB-C/USB-A adapter
  → Alfa AWUS036ACH
```

USB hotplug is safe while the Pi is running — no need to power-cycle the Pi
for this step.

## 4. Verify

```
lsusb                      # should show the hub (Realtek RTS5411) and the
                            # Alfa (0bda:8812)
lsmod | grep 88XXau        # driver loaded
iw dev                      # wlan0 (managed, onboard) + wlan1 (Alfa)
sudo scripts/pentest/set-alfa-mode.sh monitor
iw dev wlan1 info          # confirms "type monitor"
```

If `wlan1` doesn't appear at all after the driver install finishes, reboot
once — the USB modalias-based auto-load sometimes needs a fresh device
enumeration to trigger.

**Double-check which physical adapter got which name** — don't just check
that `wlan0` and `wlan1` both exist, check that `wlan0`'s MAC is the
onboard chip's and it's actually associated to your hotspot:
```
iw dev wlan0 info    # should show "ssid <your hotspot>", not the Alfa's MAC
```
If this doesn't match, `04-pin-interface-names.sh` either wasn't run or
didn't take effect yet (needs a reboot after running) — see
[TROUBLESHOOTING.md #11](TROUBLESHOOTING.md).

## 5. Day to day

- `scripts/pentest/find-pi.sh` — locate the Pi's current IP without
  assuming a fixed address (hotspot DHCP ranges have been observed to
  change between sessions).
- `scripts/pentest/set-alfa-mode.sh monitor|managed` — flip the Alfa's mode
  without touching `wlan0`/SSH reachability.
- Write session notes into `pentest-logs/` as you go.
