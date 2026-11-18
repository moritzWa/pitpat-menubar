# PitPat Bar

A Mac menu bar app that starts, stops and sets the speed of PitPat walking pads over Bluetooth, without opening the phone app.

**[Download PitPat Bar](https://github.com/moritzWa/pitpat-menubar/releases/latest/download/PitPatBar.zip)** (macOS 13 or newer, Apple silicon and Intel)

## Install

1. Download the zip above and open it.
2. Drag **PitPat Bar** into your **Applications** folder.
3. Open it. Click **Allow** when macOS asks for Bluetooth access.
4. Look for the walking figure in your menu bar.

The app is signed and notarized by Apple, so it opens without a warning. To have it start with your Mac, tick **Open at Login** in its menu.

## Use

Click the walking figure. Every pad in range is listed with its current speed. Open one and pick a speed, press **Faster** or **Slower**, or press **Stop**.

- **Name your pads.** All pads call themselves `PitPat-T01`. Pick **Rename…** (for example "Window pad") and the name sticks, because it is tied to the pad's own serial number. The **Signal** line says which pad is closest to you.
- **Speeds match the pad's display.** Pads that show mph get mph here, with 0.1 steps. Pads that show km/h get km/h. The pad itself only keeps tenths of a km/h, so an mph step can land a hair off the number you picked.
- **Speeds are capped** at 6 km/h (about 3.7 mph) and at the pad's own maximum.

## If a pad does not show up

- **The PitPat phone app is connected to it.** A pad talks to one device at a time and stops advertising while connected. Close the app on the phone, or turn off that phone's Bluetooth.
- **Out of range.** Bluetooth reaches about 10 m, less through walls. Walk closer and choose **Look Again**.
- **The pad is off.** Power it on at the pad.
- **macOS says Bluetooth is off for the app.** Open System Settings, Privacy & Security, Bluetooth, and turn on PitPat Bar.

The app only connects for the moment it takes to read or change a pad, then lets go so phones and teammates can still use it.

For anything else, run this and paste the output into an issue:

```bash
open -W -n --stdout /tmp/pitpat.txt /Applications/PitPatBar.app --args --scan; cat /tmp/pitpat.txt
```

## How it works

PitPat pads speak a small Bluetooth Low Energy protocol (service `FBA0`). The pad pushes a status frame about once a second, and the app answers each frame with a heartbeat or one command. [docs/PROTOCOL.md](docs/PROTOCOL.md) has the byte layout. The decision logic is a pure Swift function with tests; the Bluetooth code only carries its answers to the pad.

Tested on a `PitPat-T01` with firmware 37. A pad with different firmware may send a frame this app does not understand. It then says so instead of guessing, and the frame is written to the system log so it can be added.

This is an unofficial project and is not affiliated with PitPat or SupeRun. The protocol notes build on [PitPat-WebBT](https://github.com/KeiranY/PitPat-WebBT), [treadmill-tray](https://github.com/heilmic/treadmill-tray) and [HomeAssistantWalkingPad](https://github.com/sirfergy/HomeAssistantWalkingPad). Use at your own risk and keep the pad's remote handy.

## Build it yourself

```bash
swift test                 # protocol and decision-logic tests
scripts/build-app.sh       # builds dist/PitPatBar.app, ad-hoc signed
```

`scripts/release.sh` signs with a Developer ID, notarizes, and publishes a GitHub release. It needs `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` and `APPLE_TEAM_ID` in the environment.

`tools/pad.py` is the Python probe used to reverse engineer the pads (`pip install bleak`).

MIT licensed.
