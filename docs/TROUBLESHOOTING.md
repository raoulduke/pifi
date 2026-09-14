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
period). This applies to other Go-based CLI tools too, not just `fzf`.

**Fix:** use `whiptail` instead for anything needing an interactive
arrow-key menu — it's a small, old, C-based (`newt`) tool with real armel
support, and it's already installed on this image. `dialog` is also
present as an alternative with a similar API.
`scripts/pentest/attack-menu.sh` uses `whiptail --menu` for exactly this
reason.

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

### 18. `attack` (`attack-menu.sh` via `sudo`) looks like it hangs forever after the password prompt

**Symptom:** Running `attack` (or `sudo scripts/pentest/attack-menu.sh`
directly), entering the `kali` sudo password, and then... nothing.
No output, no menu, no error — indistinguishable from a genuine hang.

**Root cause:** the script is a non-interactive `bash script.sh`
invocation, which means bash's job control (`monitor` mode) is off by
default — that's normally invisible, but this script runs full-screen
terminal programs (`whiptail`, `airodump-ng`) that do real terminal
ioctls (redrawing, or resetting terminal state on exit). Without job
control, bash never hands foreground-process-group ownership of the
terminal over to those child processes when it runs them — so the
first time one of them touches the terminal while not actually the
foreground process group, the kernel stops it with `SIGTTOU`/`SIGTTIN`
(process shows as `T` in `ps`). It isn't backgrounded and isn't making
progress; it's frozen until something sends it `SIGCONT` in the right
context, which won't happen on its own. Confirmed with `ps -eo
pid,ppid,pgid,tty,stat,cmd` showing `airodump-ng` (and its wrapping
`timeout`) sitting in state `T`.

**False lead investigated first:** `/etc/sudoers` has `Defaults
use_pty` set globally (a Debian/Kali hardening default), and `sudo`'s
internal fork/monitor architecture under `use_pty` does put the actual
command on a second, freshly-allocated pty distinct from the invoking
terminal's — which looked like a very plausible cause of exactly this
class of job-control confusion, and was the first fix attempted (a
per-command `Defaults!` override in `/etc/sudoers.d/` disabling
`use_pty` just for this script). That change was verified to actually
take effect (confirmed via `sudo -ll`, and by the process tree
collapsing from two ptys to one) but the hang persisted identically
even on a single pty — proving `use_pty` was not the actual cause. It
was removed again once the real cause (below) was found and confirmed
to fix it on its own. Worth recording so this isn't re-investigated
from scratch next time — the two-pty split from `use_pty` is a red
herring here, not nothing (it's real, and worth knowing about for
other scenarios), just not the cause of *this* symptom.

**Fix:** added `set -m` near the top of `attack-menu.sh`, turning job
control on for this non-interactive script. Confirmed fixed by running
the full flow under a real SSH-allocated pty (not wrapped in `script`,
which turned out to add its own confounding pty layer during
investigation) and checking `ps` throughout — `airodump-ng` and
`whiptail` both ran and rendered correctly with no `T`-state processes
at any point, including at the natural end of the 10-second scan
(previously the exact point it froze).

---

### 19. `attack-menu.sh`: long gap after the scan gauge closes, and menus clipped on the left

**Symptom 1:** After the scan progress gauge reaches 100% and closes,
there's a noticeable multi-second pause with nothing on screen before
the network/device selection menu actually appears.

**Root cause:** parsing the scan CSV forked `echo | xargs` (or
`echo | tr`) up to four times per line just to trim whitespace off each
field. A dense-neighborhood scan easily finds 100+ networks, and on the
Pi Zero W's single slow ARM11 core, hundreds of forked subprocesses for
nothing but string trimming took multiple seconds. Separately, resolving
each device's MAC vendor called `awk` over the full ~215,000-line
`ieee-data` OUI database **once per device** -- measured at ~4.3
seconds *per call* on this board, so even a modest device list added
tens of seconds on top.

**Fix:**
- Added a `trim()` helper using pure bash parameter expansion (no fork)
  in place of every `echo | xargs`/`echo | tr` trim. Benchmarked on a
  synthetic 150-network CSV: **20.1s -> 0.7s**.
- Added `mac_vendors_bulk()`, which resolves every device's vendor in
  **one** pass over the OUI database (a single `awk` invocation matching
  a whole set of wanted prefixes) instead of one full-file scan per
  device. Benchmarked with 30 synthetic MACs: correctly resolved known
  vendors and left unknown ones empty, in ~2.6s total regardless of
  device count -- previously would have been ~30 x 4.3s ≈ 129s.

**Symptom 2:** The network-selection menu's title renders as "elect a
WiFi network" -- the leading "S" is missing, cut off the left edge of
the screen.

**Root cause:** `whiptail --menu`/`--gauge`/`--msgbox` widths were
hardcoded (78, 70, etc.). `whiptail` centers its dialog box on the
terminal's actual column count; if the box is specified wider than the
real terminal (a phone SSH client's terminal can easily be narrower than
78 columns), the excess renders off the *left* edge -- clipped, not
wrapped or shrunk.

**Fix:** added `safe_w()`, which reads the real terminal width via
`tput cols` and caps any requested dialog width to fit it (with a floor
of 20 so a very narrow terminal still gets a usable, if cramped, dialog).
Applied to every `whiptail` call in the script.

---

### 20. No way to build a live-updating `whiptail` dialog with a Cancel button

**Symptom while building the deauth screen:** wanted a dialog showing
elapsed time and a live status, refreshing on its own every second,
while still letting a keypress cancel it at any point -- the natural
way to do that with `whiptail`/`dialog` is a `--timeout` flag that
returns the dialog automatically if no key is pressed within N seconds,
so it can be redrawn in a loop.

**Root cause:** this image's `whiptail` is 0.52.25 (the `newt`-based
build, confirmed via `whiptail --help`), which has no `--timeout`
option at all -- that flag exists in `dialog` and in some other
`whiptail` builds, but not this one. Without it, any `whiptail` call
blocks indefinitely waiting for a keypress; there's no way to have it
return on its own to redraw updated content.

**Fix:** don't fight the missing flag -- the deauth status view
(`run_deauth()` in `attack-menu.sh`) uses a plain full-screen loop
instead of a `whiptail` dialog: `clear` + `echo` the current elapsed
time/status each second, and `read -r -t 1 key` (a real bash builtin
with its own timeout) to both wait ~1s AND check for a `q` keypress in
the same step. Simpler and more reliable here than depending on a flag
this particular build doesn't have.

---

### 21. Two subtle bugs writing the nmap-model-info parsing (UPnP/DNS-SD)

Found while adding active UPnP/DNS-SD device-model lookups to
`attack-menu.sh`'s device-info screen (unable to test against real
devices at the time — the Pi was on an away hotspot unreachable from
the machine doing the writing — caught instead with a synthetic nmap
output sample built from the documented NSE output format). Recording
both since they're generic pitfalls, not specific to this one script.

**Bug 1 — `paste -sd', ' -` doesn't do what it looks like it does.**
`paste -d` treats a *multi-character* delimiter argument as **separate
delimiter characters to cycle through per join**, not one two-character
delimiter — so joining `80/tcp`, `1900/udp`, `5353/udp` with `-d', '`
produces `80/tcp,1900/udp 5353/udp` (alternating comma, then space,
then comma...), not `80/tcp, 1900/udp, 5353/udp`. Easy to miss since
it "looks" correct and the first join happens to come out right.
**Fix:** build the joined string in `awk` directly
(`{if(o)o=o", "$1; else o=$1} END{print o}`) instead of piping to
`paste` for any delimiter longer than one character.

**Bug 2 — extracting one `nmap` NSE script's output block bled into
the next script's block.** Two scripts' output sit back-to-back in
`nmap`'s output with no blank line between them, both just
`|`-prefixed continuation lines — stopping extraction only at the
first *non*-`|` line means a block that reads "keep collecting `|`
lines" doesn't know where one script's output ends and the next
one's begins, and silently merges them. **Fix:** also stop at a new
`| scriptname:` marker line, not just at the first non-`|` line —
i.e. `f && /^\|[_ ]?[a-zA-Z0-9_-]+:/{exit}` *before* the generic
`f && /^\|/{print; next}` continuation rule.

### 22. `attack-menu.sh`: Ctrl+C only stopped the script from some screens

**Symptom:** Ctrl+C during the live deauth status view stopped
everything as documented, but hitting it on a network/device menu, a
scan gauge, or the device-info screen instead just backed out one
level (like pressing Back/Cancel) or did nothing visible, leaving the
script running.

**Cause:** `set -m` job control (needed elsewhere so `airodump-ng`'s
terminal ioctls don't get `SIGTTOU`-stopped, see #18) means every
foreground `whiptail` dialog or gauge runs in its *own* process group
and briefly owns the terminal's foreground control. Ctrl+C (`SIGINT`)
is delivered to *that* process group, not to `attack-menu.sh`'s own
process — the script only learns anything happened via the dialog's
exit code afterward. The live deauth view was the one screen immune
to this: its polling loop uses bash's own `read` builtin, which doesn't
fork a new process group, so the script's own process (with no `INT`
trap, hence bash's default terminate-on-SIGINT) receives the signal
directly and dies — triggering the `EXIT` trap's cleanup normally.
Every other screen's `whiptail` call was only ever checked with a bare
`||`, which can't distinguish "killed by Ctrl+C" (exit 128+signal,
130 for `SIGINT`) from an ordinary Cancel/Esc button (1/255) — both
fell into the same "go back" branch.

**Fix attempted:** added `is_interrupted()` (checks for an exit code
`>= 128`) and call it after every `whiptail` invocation and after the
scan gauge's own pipeline (`PIPESTATUS[1]`, since the gauge's exit code
is otherwise never inspected at all) — an interrupted one now kills any
still-running background scan and `exit`s the whole script instead of
falling through to Back/Cancel handling. Also moved `run_deauth()`'s
per-session scratch dir (`monwork`) into a global (`MONWORK`) so the
top-level `EXIT` trap can remove it even when Ctrl+C terminates the
script straight out of the deauth loop, skipping that function's own
post-loop `rm -rf` entirely.

**This fix turned out to be incomplete/beside the point — see #23.**
The reasoning above about process groups is correct as far as it goes,
but there's a more fundamental blocker underneath it that this fix
doesn't address: keeping `is_interrupted()` and `MONWORK` anyway, since
neither is wrong, just insufficient on its own (`is_interrupted()` in
particular is now dead code for the whiptail-dialog case specifically —
see #23 for why — but harmless, and still correct for a process that's
genuinely signal-killed some other way).

### 23. `attack-menu.sh`: ...and the real reason Ctrl+C still didn't work, even after #22's fix

**Symptom:** after deploying #22's fix, Ctrl+C *still* did nothing on
any `whiptail` screen (network/device menus, scan gauges, device-info)
— confirmed on a real device (Pixel 3 + Termux) over several rounds of
testing, including after ruling out `sudo`'s `Defaults use_pty` (which
really does create a second, nested pty for the command — confirmed
with `ps` showing two separate `sudo` processes on two separate
`pts/N` devices — a very plausible-looking suspect, but proven not the
cause: a directly-sent `SIGINT` to the right process group killed the
whole nested tree just fine even through that nesting).

**Investigation:** every test using `kill -INT <pgid>` from a second
SSH session — simulating what a terminal's Ctrl+C does — showed the
script terminating correctly, cleanup and all. That was the misleading
part: `kill -INT` delivers the signal directly via syscall, which
works regardless of terminal state, so it could never have caught the
real bug. The actual test that mattered was checking the terminal's
own settings live with `stty -a` while a real run was in progress:

```
# Before any whiptail dialog:
intr = ^C; ... isig icanon iexten echo ...

# The instant whiptail takes the screen (gauge OR menu -- checked both):
intr = <undef>; ... isig -icanon -iexten -echo ...
```

`isig` (the terminal mode that turns special characters into signals)
is still nominally on, but `intr` — the character bound to generating
`SIGINT` — has been explicitly unbound. With no character bound to it,
**no keypress can generate `SIGINT` at all** while `whiptail` owns the
terminal. This is `newt` (the library behind `whiptail`) taking over
raw keyboard handling for its own dialogs, deliberately clearing the
interrupt binding so it can interpret every keystroke itself (this is
exactly how Esc-as-Cancel already works — Esc is a plain byte `newt`
reads and acts on in its own input loop, not something signal-based).
It's inherent to `whiptail`/`newt`, true on any client (phone SSH app,
laptop terminal, tmux, anything), and not something this script's own
code can override or work around while a dialog is showing.

**Conclusion / fix:** documented rather than "fixed" — see the Ctrl+C
note near the top of `attack-menu.sh` and in `docs/SETUP.md`. Ctrl+C
genuinely only works on the live deauth view (which never uses
`whiptail` — its polling loop is a plain `read` builtin, so the
terminal stays in normal mode) and at an ordinary shell prompt. Esc
already works to back out of any menu/device-info/yes-no screen. Scan
gauges (`whiptail --gauge`) have no interactive escape at all right
now — `--gauge` takes no keyboard input, period — a scan has to run to
completion; a considered alternative (dropping `whiptail` for a plain
text progress ticker on just the scan screens, which would leave the
terminal in normal mode and make Ctrl+C genuinely work there) was
decided against for now to keep the gauge's visual polish.

### 24. `attack-menu.sh`'s device list found far fewer devices than `nmap -sn` on the same network

**Symptom:** on a home network with 11 live hosts (confirmed with
`sudo nmap -sn 10.0.0.0/24`), the device-selection list showed only 6.

**Cause:** the device list was built purely from the passive
`airodump-ng` capture, which only records a device if it happens to
transmit an 802.11 frame during the (10s) scan window. An idle device,
or one that just doesn't have anything to send right then, is
completely invisible to it no matter how long the window runs — this
is fundamental to passive capture, not a bug in the capture itself.
`nmap -sn` (and the `arp-scan` this script already runs, on the same
network, for per-device IP lookup) instead sends an ARP request to
every address on the subnet and counts who replies — it can't miss a
live host that way, but it only works when actually on that network
(unlike the passive capture, which is the only option at all against a
network you're monitoring but not authenticated on).

**Fix:** when genuinely on the same network via `wlan0` (the existing
`SAME_NETWORK` check), merge in any MAC the ARP scan found that the
passive capture didn't, instead of only using ARP results to enrich
devices airodump already had. These merged-in entries have no signal
reading (airodump never saw them to measure one), which the existing
"show `?`, sort to the bottom" handling for unmeasured signal already
covers without further changes.

**Investigated and decided against — shortening the passive window
to save time now that ARP covers completeness regardless:** tested
live against the real network with a throwaway A/B harness (temporarily
deployed over `attack-menu.sh`'s own path to reuse its scoped
passwordless-sudo grant, then reverted) comparing a 10s and a 5s
capture back-to-back. `arp-scan` alone found all 11 hosts in both
cases (confirming completeness doesn't depend on the passive window at
all anymore), but the *signal-strength data* did: 10s got a real dBm
reading for 7 of the 11 devices, 5s only 5 — two devices (`-11dBm` and
`-25dBm`) dropped out of airodump's capture entirely in the shorter
window and would've shown `?` instead of their real signal. Since
that signal reading is what the device list's sort order (and, by
extension, a rough read on whether a deauth is likely to land) is
based on, the full 10s was kept.

### 25. `attack-menu.sh`'s screen-flicker (#23) doesn't have a fix within whiptail -- rewritten as `attack-tui.py`

**Cause, confirmed in #23:** every `whiptail` invocation independently
toggles the terminal's alternate-screen buffer (`\e[?1049h` on start,
`\e[?1049l` on exit) -- with a *chain* of separate `whiptail` processes
(one per screen), that toggle happens between every single one, which
is what read as the UI "closing and reopening". There's no flag to
make that buffer persistent across separate invocations.

**Fix:** `scripts/pentest/attack-tui.py`, a from-scratch curses
rewrite kept *alongside* `attack-menu.sh` rather than replacing it --
one `curses.wrapper()` for the whole program lifetime, entering/exiting
the alternate screen exactly once total instead of once per screen.
Confirmed directly the same way the original bug was confirmed:
capturing the raw byte stream from a real `ssh -tt` run and counting
`1049` occurrences -- exactly **one**, for a full network-scan →
network-menu transition, versus one pair *per screen* in the bash
version. Every external-tool invocation (`airodump-ng`, `aireplay-ng`,
`arp-scan`, `tshark`, `nmap`, `nbtscan`, the OUI vendor lookup) and
parsing rule is a faithful port of `attack-menu.sh`'s logic, run via
`subprocess` -- not reimplemented from scratch -- so behavior doesn't
drift between the two. Bonus, not the point but confirmed true:
`curses.wrapper()` uses `cbreak()`, not `raw()`, so unlike `whiptail`
it does NOT disable the terminal's interrupt character -- Ctrl+C
generates a real `SIGINT` on every screen here, not just one.

**A bug caught while building it, recorded since it's a generic
pitfall:** `os.environ.setdefault("ESCDELAY", "25")` was originally
set inside the function passed to `curses.wrapper()` -- but
`curses.wrapper()` calls `initscr()` *before* invoking that function,
and `initscr()` is when ncurses actually reads `ESCDELAY`. Setting it
from inside the wrapped function is a silent no-op; it has to be set
in the real environment before `curses.wrapper()` is ever called.

**Verifying interactive input (arrow keys, Enter, Ctrl+C, `q`) over
SSH turned out to be its own rabbit hole, worth recording:** driving
the TUI non-interactively via a FIFO piped into `ssh`'s stdin produced
three separate misleading failures before landing on a real live test
instead of chasing a fourth: (1) closing the FIFO's write end between
sends produced an EOF that got misread as if the user had quit; (2)
the sandboxed test shell's `ssh -tt` had `TERM=dumb`, under which
arrow-key escape sequences have no keymap entry at all, so they were
read as a lone Esc (quit) followed by two stray characters; (3) even
with `TERM` fixed, `ssh` reading from a non-tty, non-EOF'd FIFO
appears to buffer local stdin rather than forwarding it promptly --
confirmed the FIFO mechanism itself was fine via a plain `cat` reader,
but keys sent this way never reached the remote process at all
(logged every `getch()` return value to confirm: consistently `-1`,
i.e. never received). None of these were bugs in the script -- each
was a test-harness artifact specific to scripting a pty-driven
interactive program non-interactively through several extra hops.
**Takeaway:** for anything that depends on real interactive keyboard
timing into curses/whiptail/newt, a real terminal session beats
synthetic input injection; don't sink more time into the latter once
it's producing inconsistent results across otherwise-identical runs.

### 26. Device-discovery-completeness, round 2: `arp-scan` alone still misses devices `nmap -sn` catches

**Symptom:** even after #24's fix (merging in whatever `arp-scan`
found that the passive capture missed), the device list on a real home
network still came up short against `sudo nmap -sn 10.0.0.0/24` --
10 devices found via `attack` vs. 14 via `nmap`. Repeating both
commands 5 times each showed `nmap -sn` finding 1-2 more devices than
`arp-scan` on average, but not the *same* 1-2 extra devices each time.

**Root cause:** the extra devices `nmap -sn` catches that `arp-scan`
sometimes misses (and vice versa, occasionally) are power-saving
smart-home devices (Tuya Smart plugs/bulbs, Espressif/ESP-based
gadgets) whose WiFi radios cycle between asleep and briefly awake to
check in with a cloud service, rather than staying continuously
responsive. A single ARP/ping probe that lands outside a given
device's brief awake window gets no reply -- confirmed this is
inherent to the *devices*, not a difference in scanning technique:
running the identical `nmap -sn` command repeatedly against an
unchanged network gave different host counts (11-14) run to run, with
no `arp-scan` involved at all.

**Investigated and confirmed via a live A/B test** (5 runs each of
`arp-scan` alone, `nmap -sn` alone, and both run concurrently with
their MAC results unioned, against the real network): the combined
approach was `>= max(arp, nmap)` in **every single run**, often
strictly more than either alone (e.g. one run: arp=11, nmap=12,
combined=14). Across all 5 runs, `arp-scan`'s and `nmap`'s own
*best-possible* unions (needing 5 repeated runs each to reach) topped
out at 13 devices each -- one **single** combined run routinely came
within one device of that, and did so in one pass rather than five.
Concurrent runtime (both processes started together, `nmap`'s own
2-11s run mostly overlapping `arp-scan`'s ~2s one) measured at 3.9-6.3s
total, not the sum of the two.

**Fix:** both `attack-menu.sh` and `attack-tui.py` now run `arp-scan`
AND `nmap -sn` concurrently (not sequentially) for the same-network
completeness pass, unioning their MAC→IP results (arp-scan's wins on
overlap, arbitrary -- both are reporting the same live host either
way). Started *before* the passive device-scan gauge, not after it
(previously `arp-scan` ran once the gauge had already finished) --
overlapping the two means the added completeness costs close to
nothing in wall time, since `nmap`'s own runtime mostly fits inside
the already-happening `SCANTIME_DEVICES`-second window instead of
stacking additional time on top of it.

Devices found this way still won't have a signal-strength reading (the
passive capture never saw them), same "show `?`, sort to the bottom"
handling from #24 covers that. This remains fundamentally
probabilistic against the specific class of intermittently-sleeping
devices involved -- no realistic amount of tuning makes a single scan
window deterministic against a device that might simply not be awake
during it -- but the measured data above shows one combined pass gets
close to what repeated single-tool runs need several tries to match.
