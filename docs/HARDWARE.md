# Hardware

## Core components

| Component | Model | Notes |
|---|---|---|
| SBC | Raspberry Pi Zero W | Single Micro-USB OTG port, no separate power-managed USB hub circuitry |
| OS | Kali Linux "pi-tail" 2025.2 | armv6l, kernel `6.12.20+rpt-rpi-v6`. Image: [kali-linux-2025.2-raspberry-pi-zero-w-pitail-armel.img.xz](https://old.kali.org/arm-images/kali-2025.2/kali-linux-2025.2-raspberry-pi-zero-w-pitail-armel.img.xz) — hosted on `old.kali.org`, **not** the current kali.org downloads page, and easy to miss for that reason |
| Wireless pentest adapter | Alfa AWUS036ACH | Chipset: Realtek RTL8812AU. Cable terminates in USB-C (device end) / USB-A (host end) |
| USB hub | iCAN 5-Port USB 3.0 Hub w/ 12V 2A power adapter (RSH-A35) | **Must be self-powered** — see rationale below. Upstream connector is USB-B (printer-style), not USB-A |
| OTG adapter | Micro-USB (male, OTG) → USB-A (female) | Must be explicitly OTG-wired (ID pin grounded), not a generic charge/sync cable |
| Control-plane link | Pixel 3, WiFi hotspot (`P7802`) | See [ARCHITECTURE.md](ARCHITECTURE.md) for why WiFi hotspot was chosen over USB/Bluetooth tethering |
| Control device | Windows laptop, WSL2 | Runs the SSH session / this tooling |

## Why the hub must be independently (AC) powered

The Pi Zero W's single USB port has no separate current-limiting/power-management
circuitry — it draws straight off the board's own 5V rail, typically fed by a
~1.2A supply. The Alfa AWUS036ACH can pull well over 500mA during active
TX/injection. Running it directly off the Pi's port (or through a bus-powered
hub) risks brownouts, silent reboots, or the adapter dropping mid-capture.

A hub with its own AC adapter sources the Alfa's current independently of the
Pi's own power budget. **A "hub with individual port switches" is a different
feature and does not imply external power** — check specifically for "includes
AC/power adapter" in the spec sheet.

## Physical connection chain

```
Pi Zero W (Micro-USB data port)
  → Micro-USB OTG adapter (Micro-USB male / USB-A female)
  → USB-A end of hub's cable
  → [hub's cable: USB-B male on the hub end — same connector family as a
     printer cable]
  → Hub (own power: 12V/2A wall adapter)
  → Hub downstream port (USB-A)
  → USB-C(female)/USB-A(male) adapter
  → Alfa AWUS036ACH (USB-C)
```

Power-on order: hub's wall adapter first, then the Alfa, then the Pi (or if
the Pi is already running, USB hotplug of the rest is fine — Linux handles it
dynamically).

## Known pitfalls when sourcing replacement parts

- **USB-C/USB-A adapters look identical in both orientations.** What matters
  is the physical socket (female) vs plug (male) on each end, not the label
  printed on the packaging — retailer naming for "USB-A to USB-C" vs
  "USB-C to USB-A" is not standardized.
- **"Powered USB hub" search results often return laptop docks** (USB-C
  3-in-1/4-in-1 travel adapters). Those are designed to be powered *by* a
  laptop host and merely pass through charging current to the laptop — they
  do not independently source current for a downstream peripheral. Look for
  a hub with its own DC barrel-jack power adapter, sold as "USB hub with
  power adapter," not a laptop dock.
- A Micro-USB **OTG** adapter/cable is different from a Micro-USB **charging**
  cable, even though they can look and fit identically. A standard
  charge/sync cable leaves the connector's ID pin floating, which keeps the
  Pi's port in device (peripheral) mode. An OTG-wired adapter grounds that
  pin, which is what tells the Pi's `dwc2` controller to switch into host
  mode. Look for the word "OTG" explicitly on the product.
