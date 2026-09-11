# pifi

Provisioning, configuration, and pentest tooling for a Raspberry Pi Zero W
running Kali Linux ("pi-tail"), used as a portable wireless pentest platform
controlled over a mobile hotspot.

## What this is

A Pi Zero W boots Kali pi-tail and joins a phone hotspot for command/control
(SSH). A powered USB hub, connected via the Pi's single Micro-USB OTG port,
carries an Alfa AWUS036ACH external wireless adapter. The onboard wifi
(`wlan0`) stays in managed mode as the control-plane link; the Alfa
(`wlan1`) runs in monitor mode for testing.

**Intended to run entirely from the phone that hosts the hotspot** — no
laptop required day to day. SSH in from a phone SSH client
(Termux/ConnectBot) at `pitail.local`; the laptop
is only for the one-time build/setup in this repo. See
[docs/SETUP.md](docs/SETUP.md#5-phone-only-operation-as-pi-tail-intends).

```
Phone hotspot ── wlan0 (managed, SSH/control) ── Pi Zero W
                                                       │ Micro-USB OTG
                                                  Powered USB hub (own PSU)
                                                       │ USB-B → USB-A
                                                  Alfa AWUS036ACH
                                                       │
                                                  wlan1 (monitor mode, pentest)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full topology and
[docs/HARDWARE.md](docs/HARDWARE.md) for the parts list.

## Repo layout

```
config/          Backed-up device config (network, boot), sanitized of secrets
docs/            Hardware, architecture, setup, and troubleshooting reference
scripts/setup/   One-time provisioning scripts to recreate this exact setup
scripts/pentest/ Reusable utility scripts for day-to-day pentest work
pentest-logs/    Dated write-ups of testing sessions against the home test network
```

## Recreating this on a new Pi

1. Flash Kali pi-tail to a fresh SD card — image:
   [kali-linux-2025.2-raspberry-pi-zero-w-pitail-armel.img.xz](https://old.kali.org/arm-images/kali-2025.2/kali-linux-2025.2-raspberry-pi-zero-w-pitail-armel.img.xz)
   (hosted on `old.kali.org`, not the current downloads page — see
   [docs/SETUP.md](docs/SETUP.md#1-flash-and-boot) if this version is no
   longer current). Boot it and get it on the network far enough to SSH in
   as `kali`/`kali` (default credentials — change these for anything beyond
   a home lab).
2. Copy this repo onto the Pi (`git clone`, or `scp`) and run:
   ```
   cd pifi/scripts/setup
   sudo ./install.sh
   ```
   (kicks off network/clock fixes immediately, then a 2-4 hour driver
   build in the background)
3. Assemble the USB hardware chain per [docs/HARDWARE.md](docs/HARDWARE.md).
4. Once the driver build finishes, pin interface names and reboot:
   ```
   sudo scripts/setup/04-pin-interface-names.sh
   sudo reboot
   ```
5. Verify:
   ```
   scripts/pentest/set-alfa-mode.sh monitor
   iw dev
   ```
   You should see `wlan0` (onboard, managed, associated to your hotspot)
   and `wlan1` (Alfa, monitor mode).

Full step-by-step narrative, including everything that went wrong the first
time and why, is in [docs/SETUP.md](docs/SETUP.md) and
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — **read the
troubleshooting doc even on a clean setup.** Several of these issues are
baked into the base image/hardware and will recur on a fresh build too:
a stale network route, a missing driver, and a boot-time race that can
silently swap which physical adapter is `wlan0` vs `wlan1`.

## Status

Working as of 2026-09-11: `wlan1` (Alfa) confirmed in monitor mode, driver
built and installed via DKMS, network routing fixed persistently (in
`/boot/firmware/interfaces`, the actual persistent source — not just the
live `/etc/` copy), `wlan0`/`wlan1` naming pinned by MAC address so it no
longer depends on boot-time enumeration order, and `avahi-daemon` enabled
persistently for phone-only `.local` access. All verified across an actual
reboot cycle, not just live/in-session.
