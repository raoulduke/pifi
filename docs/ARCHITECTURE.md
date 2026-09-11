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

Kali pi-tail's own documentation recommends USB OTG tethering as the primary,
lowest-friction control method — a single cable, no hotspot broadcast
required. We are **not** using it, and this is a hardware constraint, not an
oversight to revisit:

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
- The main benefit of Bluetooth (not broadcasting a hotspot) matters for
  covert on-site engagements. This project targets the operator's own home
  network from their own desk, where that benefit doesn't apply.

So: WiFi hotspot control-plane is the deliberate choice for this specific
combination of goals (Pi Zero W + external monitor-mode adapter + reliable
remote control for home-network testing), not a workaround for something
that "should" have been USB tethering.

## USB power domain

The Pi's own 5V rail is separate from the hub's 12V/2A wall supply. The Alfa
draws from the hub's supply, not the Pi's — see
[HARDWARE.md](HARDWARE.md#why-the-hub-must-be-independently-ac-powered) for
why this separation is required.
