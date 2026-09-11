# Architecture

## Network topology

```
┌─────────────┐        WiFi (P7802)         ┌──────────────────┐
│  Pixel 3     │◄───────────────────────────►│  wlan0 (onboard) │
│  hotspot     │        managed mode          │  Pi Zero W       │
└─────────────┘        SSH control-plane      └──────────────────┘
       ▲                                              │
       │ WiFi (also P7802,                            │ Micro-USB OTG (host mode)
       │ same hotspot)                                ▼
┌─────────────┐                              ┌──────────────────┐
│  Laptop /    │                              │  Powered USB hub │
│  WSL2        │                              └──────────────────┘
│  (this repo) │                                       │ USB-A downstream
└─────────────┘                                        ▼
                                              ┌──────────────────┐
                                              │  Alfa AWUS036ACH │
                                              │  wlan1, monitor   │
                                              │  mode, pentest    │
                                              └──────────────────┘
```

Two independent wireless interfaces on the Pi:

| Interface | Chip / driver | Role | Mode |
|---|---|---|---|
| `wlan0` | Broadcom BCM43430, `brcmfmac` (onboard) | Control-plane — SSH reachability, survives regardless of what `wlan1` is doing | `managed`, associated to `P7802` |
| `wlan1` | Realtek RTL8812AU, `88XXau` (Alfa, via hub) | Pentest interface — capture/injection | `monitor` (switchable) |

They're on separate physical radios and separate USB paths from the driver's
perspective, so putting `wlan1` into monitor mode, changing its channel, or
running injection against it never affects the Pi's own SSH reachability
over `wlan0`.

## Why WiFi hotspot for control-plane, not USB tethering

The device's own bundled `/boot/firmware/Pi-Tail.README` actually
recommends *this exact architecture directly*, not just USB tethering as a
generic default:

> *"Bluetooth/Wifi: OTG adapter in smartphone, standard cable in Pi-Tail
> power (USB is free for dongles)"*
>
> *"TIPS: I'd use — Wifi tethering for smartphone or tablet connections
> (Use an external dongle for wifi attacks)"*

So this isn't a workaround diverging from the documented setup — WiFi
tethering plus a USB attack dongle is the author's own stated preferred
combination. USB OTG *tethering* (a different mode, using the same port
for phone connectivity instead of a dongle) is presented as an
alternative for PC/laptop connections specifically, not as universally
preferred over the WiFi+dongle combination.

The underlying hardware reason both the README's tip and our own build
converge on this: we are **not** using USB tethering, and this is a
hardware constraint, not an oversight to revisit:

**The Pi Zero W has exactly one USB-capable port**, driven by a single `dwc2`
controller. That controller can be in exactly one role at a time:
- **gadget mode** (`g_ether`) — what USB tethering uses, the Pi appears as a
  USB Ethernet device to the phone/PC it's plugged into, or
- **host mode** (`dr_mode=host`, what we've configured) — required so the Pi
  can drive the external USB hub and, through it, the Alfa adapter.

These are mutually exclusive on this hardware — there's no way to have the
same physical port both tether to a phone *and* drive an external USB wifi
adapter at the same time. Since the whole point of this build is the
external adapter (the onboard chip's monitor-mode/injection support is far
weaker), host mode is non-negotiable, which rules out USB tethering entirely
for this specific hardware combination.

**Bluetooth tethering** (pi-tail's third method) was also considered, since
it doesn't use the USB port and would avoid broadcasting a hotspot. Rejected
for this project because:
- Bluetooth PAN tethering tops out around 1-3 Mbps — too slow for pulling
  capture files back for analysis.
- Pairing has to happen within a 3-minute window after boot, or you need to
  reboot to get another window — meaningfully more fragile than a WiFi
  hotspot, which reconnects any time.
- **Confirmed from the device's own HOWTO, not just inferred:** Bluetooth
  tethering has **no internet access at all** ("Cons: Slowest mode and no
  Internet access"). This would have made the RTL8812AU driver build
  (which needs to `git clone` from GitHub) impossible over Bluetooth —
  not just slower, actually unworkable.
- The main benefit of Bluetooth (not broadcasting a hotspot) matters for
  covert on-site engagements. This project targets the operator's own home
  network from their own desk, where that benefit doesn't apply.

So: WiFi hotspot control-plane is the deliberate choice for this specific
combination of goals (Pi Zero W + external monitor-mode adapter + reliable
remote control for home-network testing), not a workaround for something
that "should" have been USB tethering.

## A note on the stock single-radio approach

The device also ships `mon0up`/`mon0down` helper scripts that put the
**onboard** chip itself into monitor mode (as a virtual `mon0` interface)
for a single-radio setup. The device's own docs flag the tradeoff this
creates: *"You're including your own traffic when sniffing wifi"* — because
your own control-plane traffic and the traffic you're monitoring both ride
the same radio.

Our two-radio setup (separate physical chips for control-plane vs.
monitoring) sidesteps that tradeoff entirely — `wlan1`'s captures never
include the Pi's own SSH/control traffic, since that rides a completely
separate radio (`wlan0`) that never needs to go anywhere near monitor mode.

## Interface naming is pinned, not assumed

`wlan0`/`wlan1` names are assigned by the kernel in **enumeration order**
at boot, not by fixed hardware identity — there's no inherent guarantee
that the onboard chip is always `wlan0`. We observed the Alfa win that race
at least once, which (since `/etc/network/interfaces` only has an explicit
stanza for `wlan0`) meant the Alfa auto-connected to the hotspot instead of
the onboard chip, silently breaking the control-plane assumption this whole
document is built on. See docs/TROUBLESHOOTING.md #11.

Fixed via `systemd-networkd` `.link` files matching each chip's MAC address
(`scripts/setup/04-pin-interface-names.sh`), so the names in the table
above are now guaranteed, not just the common case.

## USB power domain

The Pi's own 5V rail is separate from the hub's 12V/2A wall supply. The Alfa
draws from the hub's supply, not the Pi's — see
[HARDWARE.md](HARDWARE.md#why-the-hub-must-be-independently-ac-powered) for
why this separation is required.
