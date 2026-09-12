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
mode) only actually fires at **boot** — its `BindsTo`/`After` on the
`wlan1` device unit doesn't get re-evaluated for a live hotplug (e.g.
unplugging and reconnecting the Alfa mid-session without rebooting).
Confirmed by unplugging/replugging the Alfa: it came back in `managed`
mode, and the service showed `inactive (dead)` rather than having fired.
If you hotplug it back in without a reboot, just run
`sudo systemctl start alfa-monitor-mode.service` manually afterward.

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
