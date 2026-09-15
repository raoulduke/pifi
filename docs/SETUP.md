# Setup

Step-by-step to recreate this setup on a new Pi Zero W. For the *why*
behind each step, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## 1. Flash and boot

1. Download the Kali pi-tail image:
   **https://old.kali.org/arm-images/kali-2025.2/kali-linux-2025.2-raspberry-pi-zero-w-pitail-armel.img.xz**
   — not on the current kali.org downloads page; pi-tail builds live on
   the `old.kali.org` ARM images mirror. If 2025.2 is no longer current,
   browse `https://old.kali.org/arm-images/` for the equivalent filename
   under whatever version directory exists.
2. Flash it to a microSD card (Raspberry Pi Imager's "Use custom image,"
   or `dd`/Etcher after decompressing the `.xz`).
3. Boot with just power connected (no hub/Alfa yet) and get it on your
   WiFi hotspot far enough to SSH in as `kali`/`kali`. The onboard chip
   (`wlan0`) stays the control-plane link for the life of this setup.

## 2. Copy this repo onto the Pi and run setup

```
git clone <this-repo-url> pifi
cd pifi/scripts/setup
sudo ./install.sh
```

Runs, in order:

1. `01-fix-network-routing.sh` — removes a stale default route that
   otherwise breaks internet access on every boot.
2. `02-fix-clock.sh` — forces an NTP resync (no RTC on this board).
3. `05-enable-mdns.sh` — enables `avahi-daemon` so the Pi is reachable
   at `pitail.local`.
4. `03-install-rtl8812au-driver.sh` — builds and installs the Alfa's
   driver via DKMS. **Budget 2-4 hours** on a Pi Zero W's single core.
   Runs detached — disconnect and check back later.

Once the driver build finishes (`sudo dkms status` shows `installed`)
**and the Alfa is physically connected** (step 3 below), run the rest
manually — `install.sh` doesn't wait for either:

```
sudo scripts/setup/04-pin-interface-names.sh
sudo scripts/setup/06-enable-alfa-monitor-boot.sh
sudo reboot
```

5. `04-pin-interface-names.sh` — pins `wlan0`/`wlan1` to fixed names by
   MAC address, so which physical adapter gets which name no longer
   depends on boot-time enumeration order. **Reboot after running this.**
6. `06-enable-alfa-monitor-boot.sh` — puts `wlan1` into monitor mode
   automatically on every boot.

## 3. Assemble the USB hardware chain

With the Pi still powered, connect (see [HARDWARE.md](HARDWARE.md) for
exact connector types):

```
Pi (Micro-USB data port)
  → Micro-USB OTG adapter
  → Hub's USB-A cable end
  → Hub (own 12V/2A wall adapter — power this on)
  → Hub downstream USB-A port
  → USB-C/USB-A adapter
  → Alfa AWUS036ACH
```

USB hotplug is safe while the Pi is running.

## 4. Verify

```
lsusb                 # hub (Realtek RTS5411) + Alfa (0bda:8812)
lsmod | grep 88XXau   # driver loaded
iw dev                 # wlan0 (managed, onboard) + wlan1 (Alfa)
iw dev wlan1 info     # "type monitor" if step 2's setup already ran + rebooted
```

If `wlan1` isn't in monitor mode yet, set it manually:

```
sudo scripts/pentest/set-alfa-mode.sh monitor
```

If `wlan1` doesn't appear at all after the driver install finishes,
reboot once.

**Confirm `wlan0` is actually the onboard chip**, not just that both
interfaces exist:

```
iw dev wlan0 info    # should show your hotspot's SSID, not the Alfa's MAC
```

If it doesn't, `04-pin-interface-names.sh` either wasn't run or needs a
reboot to take effect.

## 5. Phone-only operation (as pi-tail intends)

No laptop needed day to day — SSH in from a phone SSH client. Below is
the working setup on Android/Termux (F-Droid, no Play Store).

1. Turn on the phone's hotspot — the Pi auto-connects to it (saved
   `mobile-1`/`mobile-2` WiFi profiles).
2. In Termux: `pkg install openssh nmap`. If that fails with "No mirror
   or mirror group selected," run `termux-change-repo` and pick a
   regional mirror.
3. `.local` (mDNS) resolution doesn't work from Termux's `ssh` — find
   the Pi by IP instead:
   ```
   ip addr show wlan1   # wlan1 is the hotspot's own AP interface on this phone
   nmap -p22 --open <that-subnet>/24
   ```
4. Connect: `ssh kali@<ip>` (password `kali`).
5. Set up SSH keys once: `ssh-keygen -t ed25519 && ssh-copy-id kali@<ip>`.
6. Add [`scripts/pentest/termux-bashrc-snippet.sh`](../scripts/pentest/termux-bashrc-snippet.sh)'s
   contents to `~/.bashrc` in Termux, then `source ~/.bashrc`. From then
   on, just run `pi` — it finds and connects to the Pi automatically,
   whether it's on the phone's hotspot or has fallen back to a saved
   home-WiFi profile (see [TROUBLESHOOTING.md #15](TROUBLESHOOTING.md)).
7. From there, run tools on `wlan1` and write notes into `pentest-logs/`.

### Taking it away from home

Nothing about phone-only operation is tied to being at home. Before
relying on it somewhere without a laptop to fall back on:

- Confirm the Pi has a saved profile for the hotspot you'll use
  (`/etc/wpa_supplicant/wpa_supplicant.conf` on the Pi vs. the phone's
  current hotspot SSID).
- **The hotspot itself doesn't need mobile data/internet** — a phone
  creates its own local WiFi AP regardless of whether it has a working
  data connection; the Pi joins it and gets a local IP the same either
  way. `pifite` works the same with no internet reachable at all:
  `nmap` is run with `-n` (no DNS lookups, which would otherwise hang
  out to their own timeout with no resolver reachable) and every OUI
  vendor source it uses is a local file, not a live lookup. The one
  exception is `update-oui-master.sh` (see below), which is a separate,
  manually-run script — fails cleanly with no internet and leaves
  `pifite` unaffected either way.
- Do a live end-to-end test (power-cycle the Pi, confirm `pi` connects)
  before you're out of reach of the hardware.

## 6. Day to day (laptop-assisted alternative)

- `scripts/pentest/find-pi.sh` — finds the Pi regardless of which
  network it's on (sweeps every active laptop interface, matches by the
  onboard chip's MAC), updates the `pifi` SSH alias in `~/.ssh/config`,
  and connects. Run from WSL2 on Windows (needs `powershell.exe` to see
  the host's other interfaces). `--no-connect` just updates the alias.
- `scripts/pifi.sh` — connects via the `pifi` SSH alias, falling back
  to `find-pi.sh`'s sweep if the saved address doesn't answer. A laptop
  `~/.bash_aliases` typically wraps this as `alias pifi='bash
  .../scripts/pifi.sh'`, plus `findpi`/`syncpifi` for
  `find-pi.sh --no-connect`/`sync-pifi.sh`.
- `scripts/sync-pifi.sh` — pushes this repo onto the Pi's copy
  (`~/pifi`) via `rsync`, since the Pi can't `git clone` it directly
  (private repo).
- `scripts/pentest/set-alfa-mode.sh monitor|managed` — flip the Alfa's
  mode without touching `wlan0`/SSH reachability.
- `scripts/pentest/switch-network.sh` — forces `wlan0` to switch to
  whichever saved network profile is both actually in range and
  highest-priority (`wpa_supplicant` only re-evaluates priority when it
  disconnects on its own, so it won't preempt an already-working
  lower-priority link by itself — e.g. flipping on a phone's hotspot
  while the Pi is still happily on home WiFi). No SSID to specify —
  shows each in-range candidate's details, highest-priority first, and
  confirms before actually switching (declining or a real connection
  failure moves on to the next one). Run on the Pi as `hotspot`
  (aliased to `sudo ~/pifi/scripts/pentest/switch-network.sh` in
  `~/.bash_aliases`, alongside `pifite` — shows up in the `pi-tail
  aliases & functions` login banner).
- `scripts/pentest/update-oui-master.sh` — refreshes `pifite`'s
  third-tier OUI vendor database (run on the Pi, needs `sudo`; safe to
  skip, or add to a monthly cron — see the script).
- `scripts/pentest/pifite.py` — the interactive pentest TUI, run on the
  Pi as `pifite` (aliased to `sudo python3 -B ~/pifi/scripts/pentest/pifite.py`,
  passwordless via `/etc/sudoers.d/pifite-nopasswd`). See below.
- Write session notes into `pentest-logs/` as you go.

### `pifite`

A banner main menu, arrow keys or number keys to select:

1. **Network discovery** — scans continuously (2.4GHz + 5GHz), showing
   results live as they're found, until `q` stops it (elapsed time is
   shown, not a countdown — a generous safety ceiling auto-stops it if
   left running unattended). `s` saves the list to disk for attacks to
   use instead of re-scanning (re-run discovery and save again to
   refresh it); Esc discards without saving. The saved list is removed
   automatically when `pifite` exits.
2. **Deauth attack** — picks a network from the saved list, then scans
   it for connected devices (live, by MAC/signal). This also runs
   continuously until `q`: when on the same network as `wlan0`, ARP/
   `nmap`/NetBIOS/mDNS discovery keeps re-running the whole time
   (each shown as its own step with live status), filling in more
   IP/name/vendor/model detail on already-found devices rather than
   resolving once at the end. Resolved info is cached per network for
   the rest of the session — backing out to the network list and back
   in warm-starts from what's already known instead of losing it; `r`
   on the device list clears that cache and forces a fresh scan.
   Picking a device shows full details (vendor, resolved name, OS
   guess, signal, probed SSIDs) with a `Send Deauth` action; a WPA3
   network gets a warning that deauth is unlikely to work (Protected
   Management Frames).

Device identification is passive by default (MAC vendor, probed SSIDs
always available; a DHCP/mDNS/NetBIOS name only resolves on an *open*
network). MAC vendor lookup checks three independent OUI sources in
turn (`ieee-data`, `nmap`'s bundled prefixes, and — if
[`scripts/pentest/update-oui-master.sh`](../scripts/pentest/update-oui-master.sh)
has been run — a third, community-maintained database), then falls
back to detecting a locally-administered/randomized MAC (common on
modern iPhones/Android phones for privacy) and labels it as such
explicitly rather than an ambiguous "unknown vendor" — no OUI
database can ever resolve an address like that, since it was never a
real vendor-assigned one. Vendor names that are really chip/platform
suppliers rather than a device brand (Espressif, Tuya) get an `(IoT
Device)` hint; Vantiva (a real router OEM) gets `(Router)`. A resolved
name gets the vendor's brand prefixed if it isn't already there (mDNS's
"Hue Bridge - 05AB3A" → "Philips Hue Bridge - 05AB3A"), plus a model
number when the device's own mDNS TXT record advertises one (confirmed
on real hardware: Hue's `modelid=BSB002`). A DHCP fingerprint (Option
55/60) gives a best-effort **OS family** guess — Windows/Android/iOS/
Linux — from well-corroborated public signatures only; this is not the
same as a specific model/version (see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) for why that needs either
full router-level visibility or a crowdsourced fingerprint service
neither of which this tool has). Being on the same network as the
target additionally unlocks active `nmap -O`/`upnp-info`/
`dns-service-discovery` probing per device, which often reveals exact
model info (Chromecast, Hue, etc.) regardless of the target's own WiFi
encryption.

Ctrl+C works on every screen. `q`/Esc backs out one level. Every exit
path kills spawned `airodump-ng`/`aireplay-ng`/`nmap` children.
