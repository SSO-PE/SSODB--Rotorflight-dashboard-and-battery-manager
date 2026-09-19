# SSODB — Battery Manager for Rotorflight

A full-screen EdgeTX widget for Rotorflight helicopters. It keeps track of your
battery packs, tells the flight controller which pack is fitted, counts your
flights, shows live telemetry while you fly, and gives you a summary when you
land.

<img width="480" height="320" alt="flight-screen" src="https://github.com/user-attachments/assets/acd493a2-b074-4ef8-ac8c-b9ec448bdc71" />

> **Installation and setup: see [SSODB-Manual.pdf](SSODB-Manual.pdf).**

---

## Features

### Battery management

- Unlimited battery profiles, each with a name, rated capacity, usable
  percentage, cell chemistry and flight counter
- **Usable capacity** — set what fraction of a pack you actually want to fly
  (e.g. 75% of 5100 mAh), so the flight controller's percentage readout and
  low-capacity warnings leave you a reserve
- Batteries assigned per model, each with a battery-profile number from 1 to 6
- Unassigned packs act as "global" and appear for every model
- Packs filtered by the connected model, so you only see what's relevant
- Full on-screen editor with a touch keyboard and a dedicated numeric pad
- Delete confirmation, because deletions are written to the card immediately
<img width="480" height="320" alt="select-battery" src="https://github.com/user-attachments/assets/3bb379b7-2a2b-4f89-b867-71e6d5d08cf8" />

<img width="480" height="320" alt="edit-battery" src="https://github.com/user-attachments/assets/7feec33d-4bd5-494e-9a6d-f427184647a9" />

### Flight controller integration

Talks to Rotorflight over MSP using the RF2 Lua scripts.

- Writes the selected pack's **usable capacity** to the FC's battery profile
- Sets **maximum cell voltage** automatically from the cell type —
  4.30 V for LiPo, 4.40 V for HV
- Switches Rotorflight's active battery profile through a global variable
- Reads the model name from the flight controller itself, so the widget
  follows the aircraft rather than the radio's model file
- Asynchronous with timeouts throughout — a busy or absent FC never blocks
  the UI, and failures are reported rather than hidden

### Live flight display

- Voltage, cell voltage, current, ESC temperature, BEC voltage, headspeed,
  throttle and link quality
- Battery gauge with the pack name, percentage remaining and mAh consumed,
  colour-coded (orange below 80%, red below 20%)
- Countdown flight timer with the time shown inside the bar
- Throttle bar, sampled once a second so it stays readable in flight
- Engine state card — **ENGINE OFF / IDLE / ENGINE ON / live RPM** — driven by
  the engine switch rather than the headspeed sensor, so it can never read
  "off" while the engine is commanded on
- Session minimum/maximum tracking: lowest cell voltage, highest current,
  highest ESC temperature, worst link quality
- Per-model photo, scaled automatically to fit

### Flight logging

- Flights counted automatically per pack, credited only after six seconds
  armed so bench testing doesn't inflate the count
- Post-flight summary on disconnect: model, flight time, capacity used,
  max ESC temperature, max current, min cell voltage, worst link quality

### PID tuning

<img width="480" height="320" alt="pid-tuning" src="https://github.com/user-attachments/assets/ef4121a2-5773-4dae-8614-ccbcc67fdd85" />

- Live PID, Rates and Governor editing over MSP
- Refuses to open while armed, and closes itself if you arm while it's open

### Interface

- Designed for touch, **fully drivable by encoder and keys** — every control
  is reachable, with a visible focus ring
- On the numeric pad the encoder adjusts the value directly rather than
  cycling through keys
- Destructive dialogs default to *Cancel*
- Layout adapts to the radio's actual font metrics, measured at startup

### Robustness

- **Crash-safe storage** — a verified backup is written before the live file
  is touched, so switching the radio off mid-write cannot lose your battery
  list or flight counts; the widget recovers from the backup and says so
- SD write failures are surfaced, not swallowed
- Telemetry sensor names auto-detected, with manual overrides available
- Model images verified to exist before being offered

---

## Requirements

- EdgeTX colour transmitter — **480 × 320** or **800 × 480**
- Rotorflight 2 flight controller with telemetry
- Rotorflight RF2 Lua scripts present in `/SCRIPTS/RF2/`

Both resolutions are supported from the same source file; the layout profile
is selected at startup from the widget's zone size.

---

## Files

| File | Purpose |
|---|---|
| `main.lua` | The widget |
| `pidtune.lua` | PID / Rates / Governor tuning screen |
| `rf2util.lua` | Shared flight-controller communication |
| `background.png` / `background800.png` | Screen artwork, one per resolution |
| `icons/` | Link-quality icons |
| `Modelimage/` | Your model photos |
| `batteries.lua` | Battery list — created and maintained by the widget |
| `model.lua` | Model-to-image assignments — created by the widget |

`batteries.lua` and `model.lua` are plain text and can be backed up or edited
from a computer.

---

## Notes

- Model photos are **252 × 150** on 800 × 480 and **192 × 114** on 480 × 320.
  Images of any other size are scaled when loaded.
- EdgeTX only delivers touch and key events to a widget in full-screen mode,
  which the firmware requires a long press to enter. This is a firmware
  behaviour, not a widget setting.

---

## Documentation

Full documentation, including installation, first-time setup, every widget
setting and a troubleshooting section: **[SSODB-Manual.pdf](SSODB-Manual.pdf)**
