# Troubleshooting log

Every issue actually hit while building this, in the order encountered, with
root cause and fix. Read this even on a fresh setup — several of these are
baked into the base image/hardware and will recur unless the fixes below are
applied (which `scripts/setup/install.sh` does automatically).

---

### 1. SSH login rejected with `root`/`toor`

**Symptom:** SSH to the Pi's IP is reachable, but `root`/`toor` is rejected
from every client tried.

**Root cause:** `root`/`toor` isn't the actual credential on this image —
**and this isn't a case of outdated user knowledge.** The image's own
bundled `/boot/firmware/Pi-Tail.HOWTO` explicitly lists `root`/`toor` as
the SSH default. That's simply wrong for this build: Kali dropped
root-by-default in 2020.1, and current Kali images (including this
pi-tail build) ship a non-root `kali` user, password `kali`, with root SSH
login disabled — the pi-tail-specific HOWTO text just never got updated to
reflect that org-wide Kali change. The on-device documentation and the
actual image behavior disagree with each other.

**Fix:** Use `kali`/`kali` over SSH (verified working). `kali` is in the
`sudo` group, so `sudo -i` gets you root from there. VNC default is
reportedly `toortoor` per the same HOWTO — not independently verified in
this setup.

**Takeaway:** don't fully trust this image's bundled docs for credentials —
verify empirically.

---

### 2. `mobile-1`/`mobile-2` network profiles hardcoded to the wrong static IP

**Symptom:** Pi unreachable at the address expected.

**Root cause:** `/etc/network/interfaces` had `mobile-1`/`mobile-2` profiles
(matched against WiFi networks by `id_str` in
`/etc/wpa_supplicant/wpa_supplicant.conf`) hardcoded to a static IP that
didn't match the actual hotspot's DHCP range.

**Fix:** Changed both to `inet dhcp` — **but see #6**, changing
`/etc/network/interfaces` directly doesn't stick; the real fix has to be
made to `/boot/firmware/interfaces`.

**Context on the static-IP default:** pi-tail's own HOWTO documents a fixed
default IP of `192.168.43.254` for WiFi tethering. `192.168.43.0/24` happens
to be the conventional default subnet many Android phones use for their own
hotspot, so a fixed client address made sense as a default assuming a
"typical" Android hotspot. Our actual hotspot (a Pixel 3) was observed
handing out a different, and *inconsistent* range across sessions
(`192.168.108.x`, `.145.x`, `.3.x`) — see #3. So the fixed-IP default wasn't
arbitrary, it just didn't match this particular phone's behavior.

---

### 3. Hotspot DHCP range changes between sessions

**Symptom:** The Pi's IP is different every time you reconnect —
`192.168.108.x`, then `192.168.145.x`, then `192.168.3.x` were all observed
from the same Pixel 3 hotspot across different sessions.

**Fix:** Don't assume a fixed IP, or even a fixed *network*. Sweep for the
Pi's MAC (`b8:27:eb:...` for the onboard interface) rather than pinging a
remembered address. `scripts/pentest/find-pi.sh` does this — see #15 for
why it has to sweep every active local interface, not just one.

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
(`gateway 192.168.42.129`). A `g_ether` kernel module is loaded at boot
(via `modules-load=dwc2,g_ether` in `cmdline.txt`) specifically to create
this `usb0` gadget interface, regardless of whether anything's plugged into
the port in gadget mode — so it always exists as a software interface, even
though it has no live physical link in this build (the port itself is
dedicated to the hub/Alfa in host mode). ifupdown still installs its route
as the default, shadowing the real, working route via `wlan0`. Same-subnet
traffic doesn't need a gateway, so local SSH/pings work fine while all
internet-bound traffic silently goes to a dead interface.

**This is persistent, not a one-off, and defeated us twice for two
different reasons:**

1. First, a routing fix applied only live (`ip route del`/`add` over SSH)
   didn't survive a reboot, because it never touched any config file.
2. Second, editing `/etc/network/interfaces` directly *looked* like a
   permanent fix (it survived until the next reboot) but **wasn't** — it
   silently reverted. The actual reason: **`/etc/network/interfaces` is not
   the real source of truth on this image.** `pi-tail.service`
   (`WantedBy=local-fs.target`, i.e. runs on every boot) unconditionally
   does `cp -f /boot/firmware/interfaces /etc/network/`, overwriting
   whatever's in `/etc/` with whatever's on the **boot partition** every
   single time. The Pi-Tail HOWTO says this explicitly and we initially
   missed it: *"Don't edit `/etc/network/interfaces` or
   `/etc/wpa_supplicant.conf` — they are being overwritten at boot time.
   Use their equivalent in `/boot/firmware/`."*
   `/boot/firmware/` is the same FAT32 partition that shows up as a normal
   drive letter on Windows/macOS — the same one referenced throughout this
   project as the boot partition.

**Fix (actually permanent):** remove the `gateway 192.168.42.129` line from
the `usb0` stanza in **`/boot/firmware/interfaces`** (the boot-partition
template — kept the static address line, in case USB tethering is ever
wanted alongside a different setup later, just without it wrongly claiming
the default route), then copy that corrected file over the live
`/etc/network/interfaces` too so it takes effect immediately without a
reboot. Verified across an actual reboot cycle to hold. Automated in
`scripts/setup/01-fix-network-routing.sh`.

**Secondary effect worth knowing about:** once the bad route is removed
live (rather than by fixing the file and rebooting), `wlan0`'s own DHCP
client may not automatically claim the "default route" role either — some
DHCP client hook scripts skip installing a default route if one already
exists at the time, and by then the interface has already missed its
window. If `ip route show` comes back with no `default` line at all after
manually deleting the bad one, force a fresh lease: `sudo dhclient -v
wlan0`.

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

### 11. `wlan0`/`wlan1` swap identities across reboots

**Symptom:** After a reboot, the Pi becomes unreachable at its usual
address and stays that way for several minutes — well past normal boot
time. When it finally does respond, it turns out to be reachable at a
*different* IP than expected, and `iw dev` shows something wrong: the
interface named `wlan0` has the **Alfa's** MAC address, and `wlan1` has the
**onboard chip's** MAC address — the reverse of normal. Checking the
phone's own hotspot client list shows "2 devices connected" the whole
time, which is misleading: one of those two is the Alfa masquerading as
`wlan0`, not the actual intended control-plane interface.

**Root cause:** Linux assigns `wlanN` names to wireless interfaces in
**enumeration order**, not by any fixed hardware identity — and there's a
race between when the onboard SDIO wifi chip's driver (`brcmfmac`) attaches
versus when the Alfa's USB driver (`88XXau`) attaches during boot. Most
boots, the onboard chip wins the race and becomes `wlan0` as expected. At
least once, the Alfa won instead, becoming `wlan0`. Since
`/etc/network/interfaces` has an explicit stanza only for `wlan0` (with
`wpa-roam` pointed at the hotspot credentials) and nothing for `wlan1`, on
that boot the **Alfa** auto-associated to the hotspot (because it was
`wlan0` that boot), while the **actual onboard chip** — now named `wlan1` —
sat down and unconfigured, with no route to it at all. We only regained
access because the Alfa happened to be reachable at its own DHCP-assigned
address as a side effect, not because the intended control-plane path
worked.

**Why this matters:** the entire design in ARCHITECTURE.md assumes `wlan0`
is *always* the reliable, always-up control-plane link, independent of
whatever `wlan1` (the Alfa) is doing. A naming race silently breaks that
assumption on an unpredictable subset of boots.

**Fix:** pin both interfaces to fixed names by MAC address via
`systemd-networkd` `.link` files, so `wlan0` always means the onboard chip
and `wlan1` always means the Alfa, regardless of which driver attaches
first:

```
# /etc/systemd/network/70-wlan0-onboard.link
[Match]
MACAddress=<onboard chip MAC>
[Link]
Name=wlan0

# /etc/systemd/network/71-wlan1-alfa.link
[Match]
MACAddress=<Alfa MAC>
[Link]
Name=wlan1
```

Automated (with MAC addresses detected dynamically, not hardcoded) in
`scripts/setup/04-pin-interface-names.sh`. Verified across an actual
reboot to hold correctly.

**Related:** `alfa-monitor-mode.service` (which puts `wlan1` into monitor
mode) originally only fired at **boot** — its `WantedBy=multi-user.target`
is a boot-time dependency that doesn't get re-evaluated for a live
hotplug (e.g. unplugging and reconnecting the Alfa mid-session without
rebooting). Confirmed by unplugging/replugging the Alfa: it came back in
`managed` mode, and the service showed `inactive (dead)` rather than
having fired.

**Fixed** by adding a udev rule alongside the systemd unit
(`/etc/udev/rules.d/99-alfa-monitor-mode.rules`), which tags the `wlan1`
device's "add" event with `SYSTEMD_WANTS=alfa-monitor-mode.service` —
this gets re-evaluated by systemd on *every* appearance of that device,
not just at boot:
```
ACTION=="add", SUBSYSTEM=="net", NAME=="wlan1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="alfa-monitor-mode.service"
```
Automated in `scripts/setup/06-enable-alfa-monitor-boot.sh`. Verified with
an actual physical unplug/replug of the Alfa: came back in `monitor` mode
automatically, no manual `systemctl start` needed.

(A synthetic `udevadm trigger --action=add` on the already-known device
did **not** reproduce this — the udev property was set correctly
[confirmed via `udevadm info`], but didn't cause systemd to re-evaluate
it. Only a genuine physical replug, generating a real kernel add event,
proved this actually works. Don't trust a synthetic trigger as a
substitute for testing this kind of hotplug behavior.)

**Diagnostic tip:** if a reboot is taking unusually long to become
reachable at the expected address, don't assume a hang — sweep the whole
subnet's ARP table for *both* known MAC prefixes before concluding it's
down. A misnamed interface can leave the Pi fully reachable, just not
where you're looking.

---

### 12. Default hostname is too long to type on a phone

**Symptom:** `kali-raspberry-pi-zero-w-pitail.local` works for mDNS
resolution, but is painful to type on a phone keyboard for phone-only
operation (the whole point of pi-tail).

**Fix:** renamed to `pitail` (`hostnamectl set-hostname pitail`, plus
updating `/etc/hosts` to match, then restarting `avahi-daemon` so it
advertises the new name). Now reachable at `pitail.local`. Automated in
`scripts/setup/05-enable-mdns.sh`, which sets this short hostname on a
fresh setup rather than requiring a manual rename after the fact like we
did here.

---

### 13. Speeding up the DKMS compile

**Question worth pre-empting:** can background services (bluetooth, cron,
ModemManager, etc.) be stopped to speed up the build?

**Answer: no, not meaningfully.** The Pi Zero W has a single CPU core
(`nproc` = 1). Checking `ps aux --sort=-%cpu` / `/proc/loadavg` during the
build shows the compiler already at ~80-128% of the single core, with
everything else at ~0%, and load average pinned at ~1.0 — i.e. the core is
already fully committed to the build. There's no contention to reclaim.

---

### 14. Connecting from Termux (phone-only, no laptop) has several gotchas

Encountered getting phone-only operation actually working on a Pixel 3
with no Google Play Store (Termux via F-Droid/sideload). None of these are
bugs in this project — they're Android/Termux platform quirks worth
knowing up front rather than debugging live.

**`pkg update`/`pkg install` fails with "No mirror or mirror group
selected."** Termux's mirror config sometimes doesn't get set on first
install. Fix: `termux-change-repo`, pick a mirror group, then a specific
region close to you rather than "All" (more reliable). Retry afterward.

**`ssh kali@<hostname>.local` fails to resolve, even though the same
hostname resolves fine from Windows/macOS.** Android's underlying C
library doesn't do mDNS resolution for plain command-line POSIX tools the
way desktop OS resolvers do — this isn't specific to our `avahi-daemon`
setup, it's a Termux/Android platform limitation. Don't rely on `.local`
working from Termux's `ssh`; find the Pi by IP instead (see below).

**The hotspot's own AP interface is not always `wlan0`.** On the Pixel 3
used here, `wlan0` was the phone's *regular* WiFi client connection (e.g.
to home WiFi), while `wlan1` was the hotspot's own AP interface with its
own subnet. Running `ip addr show wlan0` from Termux while troubleshooting
returned an entirely different, unrelated network (a home router's
`10.0.0.0/24`, with 9 other devices on it) — not the hotspot at all. This
interface naming is phone/Android-version-specific; check both `wlan0` and
`wlan1` if scans come up with the wrong network.

**Unprivileged (non-rooted) `nmap` in Termux can't show MAC addresses** —
ARP-level discovery needs raw socket access. Workaround: scan for the SSH
port directly instead of doing a plain ping sweep, which isolates the Pi
without needing MAC at all:
```
nmap -p22 --open <hotspot-subnet>/24
```

**Practical result of all of the above** — the actual working phone-only
flow, and a reusable one-command connect helper, are in
[SETUP.md's phone-only section](SETUP.md#5-phone-only-operation-as-pi-tail-intends)
and
[scripts/pentest/termux-bashrc-snippet.sh](../scripts/pentest/termux-bashrc-snippet.sh).

---

### 15. The Pi can end up on an entirely different network than expected

**Symptom:** Tried standing up a substitute WiFi hotspot (same SSID/
password as the usual one, hosted from the laptop via Windows Mobile
Hotspot, because the phone that normally hosts it was unavailable) — band
confirmed correct (2.4GHz, matching the Pi's onboard-chip-only hardware
capability), password confirmed correct, and still zero clients ever
showed up on that hotspot's subnet.

**Root cause:** the Pi has multiple saved WiFi profiles with different
priorities (`mobile-1`/`mobile-2` high priority for phone hotspots, `home`
low priority as a fallback). When it couldn't successfully join the
freshly-created hotspot for some reason, it didn't just sit disconnected —
it fell through to the next reachable saved network in its list, which
happened to be the actual home WiFi network, landing it on a completely
different subnet than anyone was looking at. This is correct,
expected `wpa_supplicant` priority-fallback behavior, not a bug — but it
means **"which network is the Pi actually on" is not always the one you
just tried to give it.**

**Compounding factor — the laptop itself can have several active network
interfaces simultaneously**, and the Pi could be reachable via any one of
them: its own regular WiFi client connection, a hosted Windows Mobile
Hotspot's virtual AP interface, VirtualBox/VPN virtual adapters, etc. A
sweep of just one assumed subnet (even the "obviously right" one) can
miss it entirely if it's actually sitting on a different interface's
network.

**A related bug hit while building the fix for this:** `arp -a` on
Windows returns **every** interface's ARP table in one combined output.
A naive `arp -a | Select-String <mac>` search — without scoping to the
specific interface section currently being tested — can match a **stale
cached entry from a completely different, previously-swept network**,
producing a result that's the right IP but attributed to the wrong
interface/network (misleading, and in principle could also surface a
now-stale/wrong IP if the real device has since moved on). Fix: parse
`arp -a`'s output section-by-section, matching only within the block
whose own `Interface: <ip>` header corresponds to the subnet just swept.

**Practical fix for all of the above:** don't guess which network or
interface the Pi is on. `scripts/pentest/find-pi.sh` enumerates every
active local interface on the laptop, computes each one's actual subnet
from its own IP/prefix length (not an assumed `/24`), sweeps each in turn,
and correctly scopes the ARP match per-interface as described above. It
reports exactly which interface/network it actually found the Pi on, so
a mismatch like this is visible immediately instead of silently
misleading.

---

### 16. `fzf` isn't available on this board's architecture at all

**Symptom:** `apt-get install fzf` fails with "Unable to locate package,"
even after `apt-get update`.

**Root cause:** the Pi Zero W is `armel` (soft-float ARMv6, for the older
ARM1176 core) — not `armhf`, and not `arm64`. `fzf` is written in Go, and
Kali doesn't build/ship a Go toolchain output for `armel` at all (`apt-cache
search fzf` / `apt-cache policy fzf` come back completely empty, not just
"not installed" — the package doesn't exist for this architecture,
period). This applies to other Go-based CLI tools too, not just `fzf` —
worth checking before picking any new CLI dependency for this board.

**Fix at the time:** used `whiptail` instead (small, old, C-based
`newt` tool with real `armel` support, already installed on this
image) for the interactive menu. That script (`attack-menu.sh`) has
since been replaced by `scripts/pentest/pifite.py`, a Python/curses
TUI — curses is in Python's standard library, so this architecture
constraint doesn't apply to it at all. See #18 for why that rewrite
happened.

---

### 17. Termux's `pi()` helper only worked in hotspot mode, not home-WiFi fallback

**Symptom:** Running `pi` (the Termux `~/.bashrc` helper from
[`scripts/pentest/termux-bashrc-snippet.sh`](../scripts/pentest/termux-bashrc-snippet.sh))
reported `Hotspot interface (wlan1) not up` even though the Pi was
genuinely reachable — it was just on the phone's home WiFi (see #15's
fallback-profile behavior), not the phone's own hotspot, at the time.

**Root cause:** the original `pi()` only ever checked `wlan1` (the
phone's hotspot AP interface on that Pixel 3), because it was written
assuming the Pi would always be reached via the phone's own hotspot. It
had no path for the "Pi fell back to a saved home-WiFi profile" case,
where the relevant interface is instead `wlan0` — the phone's regular
WiFi client connection to that same network.

**Compounding issue found in the same investigation:** `ip addr show
<iface>` can fail outright with `Cannot bind netlink socket: Permission
denied` on some Android/Termux versions (hit on a Pixel 8 in this same
session) — a platform sandboxing restriction on raw netlink access,
unrelated to whether the interface is actually up. The original script
suppressed this error (`2>/dev/null`), so a permission failure and a
genuinely-down interface were indistinguishable — both just silently
produced no IP and were reported as "not up."

**Fix:** `pi()` now tries both `wlan0` and `wlan1` in turn, scanning
whichever one actually has an IPv4 address (works for either the
hotspot-mode or home-WiFi-fallback case without needing to know which
one is active), and explicitly detects and reports the netlink
permission error separately from a genuinely-absent address, so it
doesn't misdiagnose one as the other.

---
### 18. Why the interactive attack menu is Python/curses, not shell+`whiptail`

The original interactive menu (`attack-menu.sh`, removed) was bash +
`whiptail` (see #16 for why `whiptail` over `fzf` in the first place).
It was replaced by `scripts/pentest/pifite.py`, a single persistent
curses program, after `whiptail` turned out to have several problems
with no fix available from within `whiptail` itself. Recorded here so
a future shell+`whiptail` wrapper doesn't get built and rediscover
each of these one at a time:

- **Every `whiptail` call needs job control on, or it hangs silently.**
  A non-interactive `bash script.sh` runs with job control off by
  default; a full-screen program like `whiptail` or `airodump-ng` doing
  real terminal ioctls without the terminal's foreground process group
  gets stopped outright by the kernel (`SIGTTOU`, shows as state `T` in
  `ps`) — indistinguishable from a plain hang. Fix at the time: `set -m`
  near the top of the script. (A plausible-looking but wrong lead
  investigated first: `sudo`'s `Defaults use_pty` — confirmed to take
  effect, confirmed the hang persisted identically anyway, so not the
  cause. Worth knowing `use_pty` creates a second nested pty for other
  reasons, but it wasn't this bug.)
- **No way to build a live-updating dialog with a Cancel button.** The
  natural approach — a `--timeout` flag so a dialog returns on its own
  for a redraw loop — doesn't exist in this image's `whiptail` (0.52.25,
  the `newt` build). Worked around with a plain full-screen loop
  (`clear` + `echo` + `read -r -t 1`) instead of a dialog for the live
  deauth view.
- **Ctrl+C only ever worked on that one plain-loop screen, nowhere
  else, with no fix available.** `newt` (the library behind `whiptail`)
  puts the terminal into a mode that explicitly unbinds the interrupt
  character the instant it takes the screen (confirmed live via
  `stty -a`: `intr = <undef>` while any `whiptail` dialog is showing) —
  no keypress can generate `SIGINT` while it owns the terminal, on any
  client, and this isn't something the calling script's own code can
  override. Esc/Cancel still worked (a plain keystroke `newt` reads
  itself), just not Ctrl+C.
- **Every separate `whiptail` invocation flickers the whole terminal.**
  Confirmed by capturing the raw byte stream: each `whiptail` call
  independently toggles the alternate-screen buffer
  (`\e[?1049h`/`\e[?1049l`) on entry/exit, so a chain of one process per
  screen toggles it between every single screen — this is what read as
  the UI "closing and reopening." No flag makes that buffer persistent
  across separate invocations; the only real fix is one process holding
  the screen for the whole session.

**Fix:** `pifite.py` — one `curses.wrapper()` for the entire program
lifetime (confirmed, same byte-stream method, to toggle the
alternate-screen buffer exactly once for a full multi-screen session),
using `cbreak()` rather than `raw()` so the terminal's interrupt
character is never touched — Ctrl+C generates a real `SIGINT` on every
screen. Every external-tool invocation and parsing rule was ported
faithfully from the bash version's logic rather than rewritten from
scratch, so behavior didn't drift between the two versions.

**A generic pitfall hit while building it:** `ESCDELAY` (how long
curses waits to disambiguate a lone Esc from the start of an arrow-key
escape sequence) has to be set in the environment *before*
`curses.wrapper()` is called — it calls `initscr()` internally, which
is when ncurses actually reads it. Setting it from inside the wrapped
function is a silent no-op.

---

### 19. `nmap` NSE output parsing: one script's block bled into the next

**Symptom:** extracting a specific NSE script's output (e.g.
`upnp-info`) from `nmap`'s text output sometimes captured a second
script's output appended to the end of it.

**Root cause:** consecutive NSE scripts' output sits back-to-back with
no blank line between them, both just `|`-prefixed continuation lines.
Stopping extraction only at the first *non*-`|` line doesn't know where
one script's block ends and the next begins, so it silently merges
them.

**Fix:** also stop at a new `| scriptname:` marker line, not just at
the first non-`|` line. Still the exact rule `pifite.py`'s
`parse_nmap_output()`/`extract_block()` uses today.

---

### 20. Resolving MAC vendors one-by-one against the OUI database was too slow to use

**Symptom:** a scan with a modest device list took tens of extra
seconds just to label each device's vendor.

**Root cause:** the vendor lookup ran a full scan of the ~215,000-line
`ieee-data` OUI database **once per device** — measured at ~4.3 seconds
*per call* on this board's single ARM11 core.

**Fix:** resolve every device's vendor in **one** pass instead — a
single `awk` invocation matching the whole set of wanted prefixes at
once. Benchmarked at ~2.6s total regardless of device count, versus
~4.3s × device count before. Still how `pifite.py`'s
`mac_vendors_bulk()` does it today, falling back to `nmap`'s own bundled
`nmap-mac-prefixes` database for anything the primary one doesn't have
(a different, independently maintained source that sometimes has an
entry the other doesn't). Neither source will ever resolve a
locally-administered/randomized MAC (common on modern phones for
privacy) — that address was never tied to a real hardware vendor in the
first place, by design, not a database gap.

---

### 21. Passive-only device discovery misses devices that a plain `arp-scan`/`nmap -sn` would catch

**Symptom:** on a home network with 11-14 live hosts (confirmed with
`nmap -sn`), the passive device-scan list showed as few as 6.

**Root cause:** a purely passive `airodump-ng` capture only records a
device that happens to transmit an 802.11 frame during the scan
window — an idle device, or one with nothing to send right then, is
invisible to it no matter how long the window runs. Repeating `nmap
-sn` against an unchanged network gave different host counts (11-14)
run to run with no passive capture involved at all — the extra devices
it sometimes catches (and `arp-scan` sometimes catches that it
doesn't) are typically power-saving smart-home devices whose radios
cycle between asleep and briefly awake, so a single probe landing
outside a device's awake window simply gets no reply.

**Fix, confirmed with a live A/B test (5 runs each):** when genuinely
on the same network via `wlan0`, run `arp-scan` **and** `nmap -sn`
**concurrently** (not sequentially, and started *before* the passive
capture rather than after — the point is added completeness for close
to zero added wall time) and union their MAC→IP results. The union
came out `>= max(arp, nmap)` in every run, often strictly more than
either alone, and got within one device of what five *repeated* runs
of either tool alone needed to match — in a single pass. Devices found
this way have no signal-strength reading (the passive capture never
saw them); shown as `?` and sorted to the bottom, same as any
unmeasured signal. This remains fundamentally probabilistic against
this class of intermittently-sleeping device — no scan-window tuning
makes it deterministic — but one combined pass gets close to what
several repeated single-tool runs need to match. Still how
`pifite.py`'s `do_device_scan()` does it today.

---

### 22. Getting real device names (not just vendor) and a real network IP, and a CPU-contention ceiling found along the way

Four related pieces of `pifite.py`'s current device/network resolution,
recorded together since they were built and tuned as one investigation:

- **Network list IPs.** `airodump-ng`'s passively-sniffed `LANIP` field
  needs to catch the AP's own *cleartext* broadcast traffic to populate
  — on any WPA/WPA2/WPA3 network (nearly everything) even the AP's own
  broadcasts are encrypted, so this essentially never resolves (0 of
  135 networks on a real scan). Not fixable with more scan time — it's
  not visible to a passive listener at all on an encrypted network.
  Fix: for whichever *one* network `wlan0` is actually connected to,
  its real gateway IP is already known directly (`ip route show
  default`), no monitoring involved. Every other network in the list
  genuinely has no IP obtainable this way.
- **Hidden SSID resolution (passive only).** A scan also captures a
  pcap and checks it for 802.11 **probe response** frames — cleartext
  management frames regardless of the target network's own encryption
  — so whenever a client happens to probe for a hidden network during
  the scan window, the AP's response reveals its real name. Ceiling: on
  a real scan (135 networks), 70 stayed `<hidden>` — most hidden
  networks simply have no client probing for them during any given
  window, and this isn't worked around by scanning longer; deliberately
  not extended into anything active (e.g. deauthing a client to force a
  reconnect/probe), a materially more invasive technique than the rest
  of this passive-recon flow.
- **Richer device names when on the same network.** Beyond DHCP/mDNS/
  NetBIOS sniffed from the *target* network's own capture (open
  networks only, per #21's neighbor entry), two same-network-only
  sources run concurrently with everything else: a bulk `nbtscan`
  across the subnet, and a short capture on **wlan0 itself** — our own
  already-authenticated link, not the target network's — for the same
  DHCP/mDNS/NetBIOS traffic, which works regardless of the target
  network's encryption since it never touches that network's frames at
  all. Building this surfaced two real bugs (both fixed, still worth
  knowing about as generic pitfalls): the mDNS filter only checked
  query packets, missing devices (e.g. a Philips Hue bridge) whose only
  traffic is periodic *response* self-announcements — now checks both;
  and `tshark`'s default field-joining comma-concatenates every
  instance of a repeated field into one string, so a real value ending
  in `.local` could still come out as an unusable
  `real.name.local,other,junk` blob — fixed with `-E occurrence=f`
  (first instance only).
- **CPU-contention ceiling on the wlan0 capture — mitigated, not
  eliminated.** Five things compete for this board's one ARM11 core at
  once (arp-scan, `nmap -sn`, nbtscan, the wlan0 capture, and the
  airodump-ng device scan itself). The wlan0 capture is the one that
  loses entire packets (not just time) when starved — measured directly
  at 36 packets/12KB caught in isolation vs. as little as 380 bytes
  caught under full contention in the same window. Fix: `nice -n 10` on
  the three lighter helpers (arp-scan, nmap, nbtscan — they matter less
  if delayed) and `nice -n -10` on the wlan0 capture. Verified live: a
  device that previously resolved nothing under contention reliably
  resolved its real name afterward. Still how
  `start_wlan0_discovery()` prioritizes things today — there's a real
  limit to how much this single-core board can do at once, and this is
  the capture most exposed to losing that contention.

---

### 23. `sync-pifi.sh` silently synced nothing -- a `CDPATH` with `.` in it corrupts `$(cd ... && pwd)`

**Symptom:** `rsync` failed with `change_dir "<repo-path>\n<repo-path>" failed: No such file or directory` -- the captured path was the real path **duplicated with a newline in between**.

**Root cause:** a `CDPATH` containing `.` (common, e.g. so a bare `cd <subdir-name>` also matches subdirectories by name) makes bash's `cd` builtin echo the resolved directory to stdout whenever `cd` is *consulted* -- which happens even for the trivial `.` entry, not just a "real" jump via one of the other entries. `REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` was silently getting that extra echoed line prepended to `pwd`'s own output inside the same command substitution, corrupting the captured path.

**Fix:** `unset CDPATH` at the top of `sync-pifi.sh`, before computing `REPO_DIR`. Not this script's business to depend on the caller's `CDPATH` either way.

**Takeaway:** any script that captures `$(cd ... && pwd)` should not assume a "plain" relative `cd` is silent -- `CDPATH` can make it print. `unset CDPATH` defensively in scripts that do this, rather than debugging a mysteriously-duplicated path later.

---

### 24. Running a script under `sudo` leaves a root-owned `__pycache__` that breaks `rsync`/`git`/`rm` afterward

**Symptom:** `sync-pifi.sh` (running as a normal user) failed with `Permission denied` trying to delete one specific file: `scripts/pentest/__pycache__/*.pyc`.

**Root cause:** `pifite.py` runs via `sudo`, i.e. as root. Python auto-writes a compiled bytecode cache the first time it runs a `.py` file, owned by whoever ran it -- root, in this case -- inside a directory (the repo checkout) otherwise owned by the normal user. Every non-root tool that later touches that directory (`rsync`, `git`, a plain `rm -rf`) then fails on that one file.

**Fix:** run with `python3 -B` wherever `pifite.py` is invoked as root (the `pifite` alias and the matching `/etc/sudoers.d/pifite-nopasswd` entry) -- stops the bytecode cache from being written at all. Not worth the cache anyway for a script this short-lived and run this rarely. Removed the existing stray root-owned cache once, by hand, after the fact.

**Takeaway:** any script that's sometimes run via `sudo` and sometimes not, inside a checkout a normal user also needs to write to, should use `-B` (or `PYTHONDONTWRITEBYTECODE=1`) -- the cache is never worth the ownership mismatch it creates.

---

### 25. A `NOPASSWD` sudoers rule stopped matching after renaming the script it pointed at

**Symptom:** `pifite` started prompting for a password again, with no other change to `sudoers` or the alias's *intent*.

**Root cause:** `/etc/sudoers.d/pifite-nopasswd` grants `NOPASSWD` for one **exact, literal command line** -- `sudoers` does not match a command by path/basename alone, the full argument list has to match verbatim. Renaming `attack-tui.py` to `pifite.py` (and, separately, adding a `-B` flag to the invocation) each changed the actual command line the alias runs, silently leaving the old rule matching nothing.

**Fix:** update the `sudoers.d` file's command line to match exactly, every time the aliased command line itself changes -- verified each time with `sudo -l` (confirms the rule as parsed) and a real invocation (confirms it's actually passwordless, not just present).

**Takeaway:** a `NOPASSWD` entry and the alias/script it exempts have to be treated as one unit that changes together -- renaming a script or adjusting its flags is a two-file change (the alias, and the sudoers rule), not one.

---

### 26. Network scan appeared to hang at the end -- misdiagnosed once before finding the real cause

**Symptom:** after the countdown reached `1s`, the screen froze for
several seconds before the network-selection screen appeared.

**First (wrong) theory:** `cmd` is wrapped in `timeout`, which SIGTERMs
the process right at zero, but `airodump-ng` might take a few seconds
to actually exit afterward (flushing files, restoring the interface) --
plausible-sounding, and "fixed" by keeping the live display redrawing
during that gap. **Confirmed wrong** with a standalone timing repro on
real hardware: the wrapped process's exit (`proc.poll()`) returned
immediately, at the same instant the countdown hit zero. No gap there
at all.

**Real cause, found by instrumenting each step:** `do_network_scan`
runs two separate `tshark -r <pcap>` passes afterward (hidden-SSID
resolution, then open-network gateway-IP lookup) with no visible
progress indicator. Measured directly on this hardware: **~5.2s each**,
run back-to-back, so **~10.5s of silent blocking** right after the
countdown ends -- indistinguishable on screen from a hang.

**Fix:** combined into one tshark pass (`resolve_network_extras()`).
tshark's dominant cost here is decoding the whole pcap once, not the
filter matched -- confirmed directly: a single pass with both filters
combined took ~5.5s, the same as running either alone, cutting total
time roughly in half. (Running the two passes *concurrently* instead
of combining them would **not** have helped -- this is single-core
CPU-bound decoding, not I/O wait, so it doesn't get the same win
arp-scan+nmap's concurrency gets elsewhere in this codebase; see #13.)
Also added a visible step-status frame while the combined pass runs,
so a case that's still slow on a busier capture is at least shown as
"running," not silent.

**A second, real bug caught while combining the two passes:**
`wlan.ssid` comes out of `tshark -T fields` as **raw hex** on this
tshark version (e.g. `53756d79`), not text -- confirmed directly
against a real capture. The pre-existing (separate) hidden-SSID
resolution code never decoded this, so a resolved hidden network's
name was silently storing/displaying as a hex string, not its real
name, since that feature was first built. Fixed by hex-decoding in
`resolve_network_extras()`; verified against real captured networks,
correctly decoding to names like `Sumy`, `frey`, `BELL410`.

**Takeaway:** confirm a "probably this" theory against real timing
before fixing it -- the first theory was plausible, had a clean
narrative, and was still wrong; only direct instrumentation (a
standalone repro with timestamped prints around each step) found the
actual bottleneck.

---

### 27. DHCP fingerprinting for an OS-family guess -- what's real, what's excluded, and why

Requested: device discovery closer to what an ISP router app shows
(brand/model/OS). That level of precision needs either (a) being the
actual DHCP server with full visibility into every device's DHCP
transaction, not just whoever's active during a scan window, or (b) a
crowdsourced fingerprint service (Fingerbank-style) built from millions
of real devices -- neither of which this tool has or does without an
explicit, separate decision to start sending discovered devices' data
to a third-party API. What's actually achievable from a WiFi client
sniffing broadcast/multicast traffic: an **OS family** guess (Windows/
Android/iOS/Linux), via passive DHCP fingerprinting -- the same
technique p0f/Fingerbank/enterprise NAC tools use, just applied locally
with a small, offline signature table instead of a live lookup.

**Signatures used, and confidence, from cross-checking three
independently maintained fingerprint databases (p0f-family, Fingerbank,
Cisco ISE docs) plus a real capture on this project's own hardware:**
- Windows: Option 60 vendor class contains `MSFT` -- stable across
  every Windows version since 2000, high confidence, but only
  identifies "Windows," not a version.
- Android: Option 60 matching `android-dhcp-<N>` -- AOSP's own naming
  convention, gives the major version number directly.
- Apple (iPhone/iPad/Mac): Apple's DHCP client sends **no** Option 60
  at all (confirmed fact, not an omission in this table) -- every
  source consulted relies on the device's own DHCP hostname (Option
  12) instead, e.g. a hostname containing "iPhone"/"iPad"/"MacBook".
- Linux: Option 55's parameter-request-list `1,28,2,3,15,6,119,12,44,
  47,26,121,42` -- confirmed to decode exactly to the request list
  Debian/Ubuntu's `isc-dhcp-client` package ships by default, and
  directly verified against a real DHCPREQUEST captured from this
  project's own Pi (running Kali, Debian-based).
- Windows' own hostname pattern (`DESKTOP-`/`LAPTOP-`) and
  `raspberrypi` in the hostname are used as additional direct
  hostname-based signals alongside the above.

**Deliberately excluded -- no reliable signature exists, so nothing
was hardcoded:**
- **Chromecast/Google Cast.** The one DHCP vendor-class string found
  during research (`dhcpcd-5.2.10:Linux-3.0.8-...:MV88DE3100`, an old
  Marvell SoC string) appears only in informal capture discussions, not
  in any maintained fingerprint database, and is stale against current
  hardware anyway. OUI/mDNS-based identification (already in place) is
  the reliable signal for these.
- **Espressif (ESP8266/ESP32) and Tuya-platform devices.** Confirmed no
  stable signature exists: ESP-IDF's DHCP client historically didn't
  even send Option 60 at all (only added incrementally per SDK
  version), and firmware varies hugely across the ESP ecosystem
  (Arduino core vs. raw ESP-IDF vs. Tasmota/ESPHome, each a different
  network stack) -- there is no single "ESP" or "Tuya" DHCP fingerprint
  to match against. `VENDOR_CATEGORY_HINTS`' OUI-based `(IoT device)`
  hint is the right tool for these, not DHCP fingerprinting.

**Implementation note:** folded into the same single tshark pass that
already extracts DHCP hostnames (`_tshark_hostnames_from_pcap()`) --
Option 55/60/12 are all read from one packet in one pass, not a
separate capture or extra decode cost, per #26's lesson above.

---

### 28. A locally-administered MAC will never resolve in any OUI database -- confirmed, not assumed

**Symptom:** a real device on the network (confirmed: an iPhone and, separately, an Android phone) always showed as "unknown vendor," across every OUI source tried.

**Root cause, confirmed rather than assumed:** the MAC's first octet has the IEEE-reserved "locally administered" bit set (the second-least-significant bit) -- `arp-scan`'s own output independently confirms the same read (`Unknown: locally administered`). This is iOS/Android's per-network MAC randomization (Private Wi-Fi Address on iOS, since Android 10 on Android) deliberately marking the address as not a real vendor-assigned one. **No OUI database, however complete or frequently updated, can ever resolve an address like this** -- it isn't a data-completeness gap, the address structurally was never tied to a real hardware vendor in the first place.

**Fix:** `is_locally_administered_mac()` checks this bit directly and labels the result "randomized/private MAC (not a real vendor address)" instead of the ambiguous "unknown vendor" (which doesn't distinguish "not in our database yet" from "structurally unresolvable").

**Investigated and did not pan out -- recorded so it isn't re-attempted:** whether a device's 802.11 vendor-specific information elements (in probe requests, which are cleartext management frames regardless of the target network's own encryption) might reveal a real vendor OUI even when the frame's source MAC is randomized -- plausible in principle, and part of what the 2017 FuriousMAC paper describes for defeating early Android randomization implementations. Tested directly against a live capture of real client probe requests on this network: no vendor-specific IEs or WPS manufacturer/model/device-name fields were present in any of them -- consistent with the 2021 FuriousMAC follow-up paper's own finding that current devices leak less this way than older ones did. Not implemented; nothing to extract on real, current hardware.

---

### 29. Added a third OUI vendor-lookup source, and why it's a real (if modest) improvement

**Requested:** check whether `Ringmast4r/OUI-Master-Database` (a community-maintained, MIT-licensed, monthly-updated aggregate OUI database) would resolve more vendors than the two sources already in use.

**Investigated directly rather than assumed:** fetched the repo and its actual data file. It merges IEEE + nmap-mac-prefixes (both already used directly, see `mac_vendors_bulk()`) with two sources neither of those draws from -- Wireshark's own manufacturer database and HDM Mac-Tracker -- so it can resolve some real vendor OUIs the existing two-source setup misses. It does **not** include any per-model MAC-block mapping (confirmed no such thing exists in the repo), and -- per #28 above -- cannot help at all for a locally-administered/randomized MAC, since no OUI database structurally can.

**A real parsing pitfall caught before shipping it:** the file is CSV with a quoted `address` field containing embedded commas (`"7760 France Ave S Suite 340 Bloomington MN US 55438"`). The existing two sources' lookups use `awk` with a plain field split, which is fine for their simpler formats but would silently misparse this file's columns. Used Python's `csv` module for this third source specifically instead of forcing it through the same `awk` pattern.

**Fix:** `scripts/pentest/update-oui-master.sh` downloads/refreshes the file to `/usr/local/share/pifi/oui-master.csv` (run manually, or add to a monthly cron matching the upstream repo's own update cadence); `mac_vendors_bulk()` checks it as a third-tier fallback, only if the file exists -- skipping the download entirely leaves the tool exactly as it was, no regression risk.

---

### 30. `pifite` needs to work with no internet reachable at all -- confirmed and guarded, not assumed

**Requested:** confirm phone-hotspot-with-no-data still works for running `pifite`, and add guards so nothing that touches the network crashes/hangs when there's genuinely no internet path out (a phone hotspot with no mobile data is a normal, expected case while mobile).

**Confirmed rather than assumed:**
- A phone's hotspot is a plain local WiFi AP -- it works identically whether or not the phone itself has a working data connection. The Pi joining it and getting a local IP doesn't depend on internet reachability at all.
- `sudo` itself isn't at risk of the classic "hangs resolving its own hostname with no DNS reachable" gotcha -- checked `/etc/hosts` directly: `pitail` already resolves to `127.0.1.1` locally, confirmed `sudo` completes in ~0.17s either way.
- Every OUI vendor source `mac_vendors_bulk()` uses (`ieee-data`, `nmap-mac-prefixes`, and the optional third-tier database from `update-oui-master.sh`) is a local file -- no live lookup at scan time, ever.

**The one real gap found, confirmed rather than assumed:** neither `nmap` invocation (same-network device discovery, and the active per-device probe) passed `-n`, so both would fall back to `nmap`'s **default reverse-DNS lookup per host** -- with no resolver reachable (a data-less hotspot forwards nowhere), each one hangs out to its own internal DNS timeout instead of failing fast, slowing down or even eating into the active probe's fixed 20-25s budget for nothing. `pifite` never uses `nmap`'s own resolved-hostname output anyway (name resolution is its own separate mDNS/DHCP/NetBIOS pass) -- fixed by adding `-n` to both. Added the same flag to every `tshark` invocation too, defensively -- confirmed directly against a real capture that it doesn't change any extracted field's value (Hue Bridge name and TXT-record model both still extracted identically), only skips resolution attempts this code never used the results of anyway.

---

### 31. `switch-network.sh` (the `hotspot` alias): a successful switch flapped for 18 minutes with nothing watching

**Symptom:** Ran `hotspot` over SSH (itself connected via `wlan0`, the interface being switched) to force the Pi from home WiFi onto a phone's hotspot. The SSH session hung immediately (expected -- see the script's own header comment: switching `wlan0` kills its own transport). What was *not* expected: after a physical power cycle, the Pi couldn't be found on **any** network -- home, the hotspot, or any other interface on the laptop doing the searching -- across several sweeps (`find-pi.sh`, raw `nmap -sn`, Windows' own ARP/neighbor table) spanning several minutes, despite the phone's own hotspot screen showing "2 devices connected" the whole time.

**Root cause, confirmed via `journalctl` (not guessed):** the switch itself worked correctly on the very first try -- `select_network` disassociated from home, associated to the hotspot, and `dhclient` obtained a real lease (`192.168.250.173`), all within about 9 seconds. Two seconds after that, `wlan0` started a **disconnect/reconnect loop roughly every 12-13 seconds** -- reconnect, get a fresh DHCP lease, hold for ~2 seconds, disconnect again -- confirmed to have repeated **88 times over 18 minutes straight**, until power was physically removed. Each disconnect logged `reason=3 locally_generated=1`, meaning `wlan0` itself chose to leave each time (not the phone kicking it off) -- the standard signature of the AP going quiet from the station's side (beacon loss), not a config bug. Checked and ruled out as the cause: `wpa_supplicant.conf`'s `bgscan` setting (none configured), a `systemd-networkd` `.network` file fighting over `wlan0` (none exists -- `networkd` only passively logs its link state), and any cron/systemd timer touching networking (none). Most likely explanation: the Pixel 3's hotspot radio itself was made unstable by simultaneously toggling the phone's own WiFi client mode on/off during the same window (a known way to bounce a phone's hotspot AP) -- consistent with `TROUBLESHOOTING.md #3`'s existing finding that this same phone's hotspot is not a rock-solid, unchanging AP session across toggles.

**Why every remote check kept failing:** each ~12s cycle only had a ~2 second window where the Pi actually had a working IP -- so a several-second sweep (`nmap`, `find-pi.sh`) had a real but small chance of landing in that window each attempt, explaining the inconsistent "sometimes almost found it, then gone again" pattern rather than a clean "found" or "not found." The phone's own "2 devices connected" display was technically accurate (it kept re-associating) but actively misleading as a health signal, since it doesn't distinguish a stable client from one flapping every 12 seconds.

**Why `switch-network.sh` had no visibility into any of this:** it declared success and exited the instant it saw one good `wpa_state=COMPLETED` snapshot -- which happened to be true in the ~2 second window right before the flapping started. The SSH session that would have shown the flapping died at the exact same moment `wlan0` first switched, for the unrelated, expected reason above (own-transport risk) -- so nobody had a live view into what happened next until physically power-cycling.

**Fix:** `switch-network.sh` now holds and re-checks `wpa_state` for `STABLE_HOLD` (20s) after first reaching `COMPLETED`, instead of trusting one snapshot -- if it drops during that window, the script says so explicitly (`"connected but didn't hold"`) rather than reporting a clean success right before things go wrong. This can't fully solve the underlying visibility gap by itself, though, since the SSH session showing that output still dies the moment `wlan0` switches if run remotely over that same link -- the script's header comment now recommends running it inside `tmux`/`screen` on the Pi specifically because of this incident, so the session (and this stability check's output) survives regardless of what happens to the SSH connection watching it.

**Not a bug in `select_network`/DHCP handling:** confirmed directly in the logs that `wpa_action`'s `ifup`/DHCP flow completed correctly on every single reconnect in the 88-cycle sequence, not just the first -- ruling out an earlier hypothesis that `select_network` might bypass `ifupdown`'s normal DHCP-renewal path.
