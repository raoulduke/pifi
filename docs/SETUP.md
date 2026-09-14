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
3. `05-enable-mdns.sh` — turns on `avahi-daemon` (installed but inactive
   by default on this image) so the Pi is reachable at
   `pitail.local` instead of needing to look up
   its current IP every time. Matters most for
   [phone-only operation](#5-phone-only-operation-as-pi-tail-intends).
4. `03-install-rtl8812au-driver.sh` — builds and installs the Alfa's
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
sudo scripts/setup/06-enable-alfa-monitor-boot.sh
sudo reboot
```
5. `04-pin-interface-names.sh` — pins `wlan0`/`wlan1` to fixed names by MAC
   address. Without this, which physical adapter ends up named `wlan0` vs
   `wlan1` is a boot-time race that can silently disconnect the intended
   control-plane interface — see
   [TROUBLESHOOTING.md #11](TROUBLESHOOTING.md). **Reboot after running
   this** to confirm it actually took effect; don't just trust that it
   silently worked.
6. `06-enable-alfa-monitor-boot.sh` — a systemd service that puts `wlan1`
   into monitor mode automatically on every boot, bound to the `wlan1`
   device unit (which only reliably means the Alfa because of step 5's
   naming pin). Without this, monitor mode does not persist across
   reboots — `wlan1` comes back up in plain `managed` mode every time, and
   you'd need `sudo scripts/pentest/set-alfa-mode.sh monitor` manually
   before every session.

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
iw dev wlan1 info          # if 06-enable-alfa-monitor-boot.sh has been run
                            # and the Pi rebooted since, this already shows
                            # "type monitor" with no manual step needed
```
If `wlan1` isn't already in monitor mode (e.g. you haven't run
`06-enable-alfa-monitor-boot.sh`/rebooted yet), set it manually:
```
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

## 5. Phone-only operation (as pi-tail intends)

The whole point of pi-tail is not needing a laptop — the device's own
bundled README says as much: *"Install your favourite ssh and vnc client
on your smartphone."* This is the primary intended way to run it day to
day. Below is the actual working setup on a Pixel 3 with **no Google Play
Store access** (Termux installed via F-Droid/sideload) — everything here
uses only Termux's own package repo.

1. Turn on the Pixel 3's hotspot. The Pi auto-connects to it (already
   configured via the `mobile-1`/`mobile-2` WiFi profiles).
2. In Termux, get a real SSH client and `nmap` (both from Termux's own
   repo, nothing Play-Store-related):
   ```
   pkg install openssh nmap
   ```
   If `pkg update`/`install` fails with **"No mirror or mirror group
   selected"**, run `termux-change-repo`, pick a mirror group, then a
   region close to you (not "All" — regional mirrors are more reliable),
   and retry.
3. **`.local` (mDNS) hostname resolution does not work from Termux's
   command-line `ssh`**, even though it works fine from Windows/macOS —
   Android's underlying C library doesn't do mDNS resolution for plain
   POSIX tools the way desktop OSes do. Don't rely on
   `ssh kali@pitail.local` working here. Find the Pi by IP instead:
   ```
   ip addr show wlan1
   ```
   (**not** `wlan0` — on this phone, `wlan0` is the *regular* WiFi client
   connection, e.g. to home WiFi; `wlan1` is the hotspot's own AP
   interface. This can vary by phone/Android version — check both if
   unsure.) Note the IP shown (e.g. `192.168.3.130`), then scan that
   `/24` specifically for the SSH port, which isolates the Pi
   unambiguously without needing MAC visibility (unprivileged Termux
   can't do ARP-level MAC discovery anyway):
   ```
   nmap -p22 --open 192.168.3.0/24
   ```
4. Connect:
   ```
   ssh kali@<ip-found-above>
   ```
   password `kali`.
5. **Set up SSH keys once, so it never prompts for a password again:**
   ```
   ssh-keygen -t ed25519
   ssh-copy-id kali@<ip>
   ```
6. **Make future connects one command**, immune to the hotspot's subnet
   changing (observed to happen between sessions), *and* to the Pi
   itself falling back to a saved home-WiFi profile instead of the
   hotspot (see [TROUBLESHOOTING.md #15](TROUBLESHOOTING.md)): add
   [`scripts/pentest/termux-bashrc-snippet.sh`](../scripts/pentest/termux-bashrc-snippet.sh)'s
   contents to `~/.bashrc` in Termux (create the file if it doesn't
   already exist — `cat >> ~/.bashrc` works either way), then
   `source ~/.bashrc`. From then on, just run:
   ```
   pi
   ```
   and it finds and connects to the Pi automatically — it tries both
   `wlan0` (regular WiFi client) and `wlan1` (hotspot AP), scanning
   whichever one actually has an address, so it works whether the Pi is
   on the phone's own hotspot or has fallen back to home WiFi. If a
   given Android/Termux version blocks `ip addr` on an interface with a
   netlink permission error, it says so explicitly rather than
   misreporting that interface as simply "not up." It also remembers
   the last IP the Pi was actually found at
   (`~/.cache/pi_last_ip` in Termux) and tries a plain, near-instant TCP
   connect to it first — the common case is the Pi hasn't actually
   moved, so this skips the multi-second subnet scan entirely most of
   the time, only falling back to the full scan when that quick check
   fails.
7. From there, the workflow is identical to the laptop path (below) — run
   your tools on `wlan1` (already in monitor mode automatically if
   `06-enable-alfa-monitor-boot.sh` was run during setup — see below),
   write notes into `pentest-logs/`.

### Taking pi-tail somewhere else entirely (no laptop, no home network)

Nothing about phone-only operation is tied to being at home — the Pi
joining the phone's hotspot is a plain WiFi association (SSID +
password + in range), independent of physical location. Before relying
on this away from home, where there's no laptop to fall back on for
troubleshooting:

1. **Confirm the Pi actually has a saved profile for the hotspot
   you'll use.** Check `id_str="mobile-1"`/`"mobile-2"` entries in
   `/etc/wpa_supplicant/wpa_supplicant.conf` on the Pi against the
   phone's *current* hotspot SSID (Settings → Network & internet →
   Hotspot & tethering → WiFi hotspot) — Android doesn't normally
   regenerate a hotspot's name/password on its own, but confirm rather
   than assume, since there's no way to add a new profile remotely if
   it's changed. A `home` profile (lower priority, for a saved home
   WiFi network) doesn't help away from home — it simply won't be in
   range, which is fine, not a fallback risk.
2. **The hotspot doesn't need internet access.** If the phone has no
   mobile data to share, the hotspot still works fine as a plain local
   access point for SSH — the Pi doesn't need internet for that, only
   for things like NTP time sync (see
   [TROUBLESHOOTING.md #7](TROUBLESHOOTING.md)).
3. **Do a live end-to-end test before you're out of reach of the
   hardware**, not just before you leave the house: turn the phone's
   hotspot on, power-cycle the Pi, wait ~1-2 minutes for it to fully
   boot and associate, then run `pi` in Termux and confirm it actually
   connects. This is the one check that catches a real problem while
   it's still fixable, instead of at the remote location.
4. `pi`'s IP cache (`~/.cache/pi_last_ip`) will hold whatever address
   worked last, which won't match a new location's subnet — that's
   fine, it just falls through to the normal full scan after a quick
   failed check, costing a couple of extra seconds, not a failure.

## 6. Day to day (laptop-assisted alternative)

If you do have a laptop on the same hotspot and prefer it for a given
session:

- `scripts/pentest/find-pi.sh` — finds and connects to the Pi regardless
  of which network it's currently on. Sweeps **every** active network
  interface on the laptop (not just one assumed subnet — this laptop can
  have several active at once: its own WiFi client connection, a hosted
  Windows Mobile Hotspot's virtual AP, VirtualBox/VPN adapters, etc.),
  matching on the onboard chip's fixed MAC address rather than any
  particular IP — reliable even when the Pi has fallen back to a
  completely different saved WiFi profile (e.g. `home`) than the one you
  expected. Reports which network it actually found it on, updates the
  `pifi` SSH alias (`~/.ssh/config`) to the current address automatically,
  and connects. Run from the laptop/WSL side (needs `powershell.exe`, i.e.
  WSL2 on Windows — plain WSL/Linux networking can't see the Windows
  host's other interfaces). Add `--no-connect` to just locate it and
  update the alias without opening a session.
- `scripts/pentest/set-alfa-mode.sh monitor|managed` — flip the Alfa's mode
  without touching `wlan0`/SSH reachability.
- `scripts/pentest/attack-menu.sh` (run on the Pi itself, `sudo` — aliased
  to `attack` in the Pi's own `~/.bashrc`) — interactive arrow-key menu,
  structured as three nested screens you can back out of at any level
  without re-scanning:

  > **Alternative:** `scripts/pentest/attack-tui.py` (`sudo python3
  > scripts/pentest/attack-tui.py`) is a from-scratch curses rewrite of
  > this same tool, built to fix a real limitation `whiptail` can't be
  > worked around within: every `whiptail` screen briefly closes and
  > reopens the terminal (confirmed via the raw byte stream — see
  > `docs/TROUBLESHOOTING.md` #23/#25), since each separate `whiptail`
  > invocation toggles the terminal's alternate-screen buffer on its
  > own. The curses version holds the screen continuously for the whole
  > session instead — confirmed, same way, to toggle it exactly once.
  > It also doesn't disable the terminal's interrupt character the way
  > `whiptail` does, so Ctrl+C works on every screen there, not just the
  > live deauth view. Kept alongside `attack-menu.sh` (the `attack`
  > alias still points at the bash version) until it's had more
  > real-world use.
  1. **Networks**, from a scan (2.4GHz + 5GHz, live progress gauge)
     sorted strongest signal first, showing signal strength, name,
     encryption, and band (not MAC/channel — not useful to look at
     here).
  2. **Devices** connected to the picked network, from a second scan,
     sorted strongest signal first and labeled with a resolved device
     name/vendor plus signal strength (the one per-device factor that
     affects whether an injected deauth frame reliably reaches it —
     RF path loss is roughly symmetric). A `Back` entry returns to the
     network list instantly, reusing the already-scanned results. If
     the network is WPA3, a warning is shown here: WPA3 mandates
     Protected Management Frames, which cryptographically authenticate
     deauth frames — compliant clients ignore forged ones regardless of
     signal, so deauth is unlikely to work at all against anything on
     such a network (this is a network-wide fact, unlike signal
     strength, so it's a warning rather than something to sort by).
  3. **Device info**, once you pick a device: every discovered detail
     (MAC, vendor, resolved name, signal, packet count, probed SSIDs),
     plus `Send Deauth` and a `Back` to the device list. Deauth runs as
     a plain full-screen view (this image's `whiptail` 0.52.25 has no
     `--timeout` flag, so a dialog can't both auto-refresh and take a
     button press) redrawn every second with elapsed time and a
     best-effort "still active / likely dropped" status, based on
     whether the device keeps appearing in a live concurrent capture —
     not a guaranteed disconnect signal. `q` + Enter stops it.

  Uses `whiptail` rather than `fzf` — see
  [TROUBLESHOOTING.md #16](TROUBLESHOOTING.md) for why. Device
  identification is passive-only by default: MAC vendor and previously
  probed SSIDs are always available (cleartext 802.11 management
  frames), but a DHCP/mDNS/NetBIOS device name only resolves on an
  *open* network — WPA/WPA2 encrypts data frames, and no attempt is
  made to obtain or crack a passphrase to get past that. Passive
  capture alone only catches a device if it happens to transmit during
  the scan window — an idle device is invisible to it regardless of
  how long that window is. If `wlan0` happens to be a genuine,
  associated member of the *same* network being scanned (auto-detected
  by comparing `wlan0`'s current SSID to the selected one), an ARP scan
  fills that gap: any device it finds that the passive capture missed
  is added to the list too (just without a signal-strength reading,
  since airodump never saw it) — this is what gets the device list to
  actually match what e.g. `nmap -sn` on the same subnet would show.
  Being on the same network additionally unlocks, per selected device:
  active `nmap -O` OS-family
  fingerprinting, `nbtscan`, and — for actual **model and version**
  info, not just OS family — the `upnp-info` and `dns-service-discovery`
  NSE scripts (both ship with `nmap` itself, nothing extra to install).
  Many consumer/IoT devices actively broadcast their exact model this
  way: a Chromecast's mDNS `_googlecast._tcp` record includes its
  literal model string, and UPnP/SSDP device descriptions often include
  `manufacturer`/`modelName`/`modelNumber`/`serialNumber` directly. All
  of this works regardless of the WiFi link's own encryption, since
  being an authenticated LAN member doesn't depend on decrypting the
  radio traffic at all. Ctrl+C only actually works on the live deauth
  view (`q` also works there) and at a plain shell prompt — it does
  **not** work on any `whiptail` screen (network/device menus, scan
  gauges, device-info), on any client, because `whiptail` disables the
  terminal's interrupt character the instant it takes the screen (see
  `docs/TROUBLESHOOTING.md` #22/#23). Use Esc/Back/Cancel to back out of
  a menu or device-info screen instead — that works fine, since it's a
  plain keypress `whiptail` reads itself rather than something relying
  on the (disabled) interrupt character. Scan gauges have no
  interactive escape at all right now; a scan has to run to completion.
  Wherever Ctrl+C or Back/Cancel *does* end the script, an exit trap
  kills every spawned `airodump-ng`/`aireplay-ng`/`nmap` child so
  nothing is left running as an orphan.
- Write session notes into `pentest-logs/` as you go.

### Laptop-side shell aliases

These live in the laptop's own `~/.bash_aliases` (personal shell config,
not part of this repo) — noted here so the reasoning behind them isn't
lost. All wrap `scripts/pentest/find-pi.sh`.

```bash
alias findpi='bash /mnt/c/Users/mattk/code/pi/pifi/scripts/pentest/find-pi.sh --no-connect'

ssh() {
  if [[ "$1" == "pifi" ]]; then
    local ip
    ip=$(awk '/^Host pifi$/{f=1} f && /HostName/{print $2; exit}' ~/.ssh/config)
    if [[ -n "$ip" ]] && timeout 3 bash -c "echo > /dev/tcp/$ip/22" 2>/dev/null; then
      command ssh "$@"
    else
      echo "pifi unreachable at ${ip:-<unset>} -- searching for it..." >&2
      bash /mnt/c/Users/mattk/code/pi/pifi/scripts/pentest/find-pi.sh
    fi
  else
    command ssh "$@"
  fi
}

syncpifi() {
  local ip
  ip=$(awk '/^Host pifi$/{f=1} f && /HostName/{print $2; exit}' ~/.ssh/config)
  if [[ -z "${ip}" ]] || ! timeout 3 bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null; then
    echo "pifi unreachable at ${ip:-<unset>} -- searching for it..." >&2
    bash /mnt/c/Users/mattk/code/pi/pifi/scripts/pentest/find-pi.sh --no-connect
    ip=$(awk '/^Host pifi$/{f=1} f && /HostName/{print $2; exit}' ~/.ssh/config)
  fi
  rsync -avz --exclude='.git' --delete /mnt/c/Users/mattk/code/pi/pifi/ "kali@${ip}:~/pifi/"
}
```

- **`findpi`** — locate the Pi and update `~/.ssh/config`, without
  connecting.
- **`ssh pifi`** — a shell *function* (not a plain alias — needed for the
  conditional logic), overriding just the `ssh` command name. Every other
  host passes straight through untouched (`command ssh "$@"`). Only
  `pifi` specifically gets the reachability check, falling back to a full
  search if the configured address doesn't answer.
- **`syncpifi`** — pushes the local repo onto the Pi's copy (`~/pifi`
  there) via `rsync`. Needed because that copy can't be `git clone`d
  directly on the Pi (the repo is private) — see
  [TROUBLESHOOTING.md #6](TROUBLESHOOTING.md) for background on why the
  Pi's `~/pifi` isn't its own git checkout. `rsync` spawns its own `ssh`
  subprocess directly, which does **not** go through the `ssh()` function
  above (shell functions aren't visible to child processes), so the same
  reachable-check-then-search fallback is duplicated here rather than
  relying on that function.

A pre-existing, unrelated `pifi` alias (`cd` into this repo's directory)
already existed on this laptop before any of the above — kept as-is, no
naming collision, since the SSH alias is invoked as `ssh pifi` (two
words) rather than a bare `pifi` command.
