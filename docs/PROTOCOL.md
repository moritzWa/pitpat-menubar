# PitPat BLE protocol

What this app relies on. Verified on a PitPat-T01, firmware 37. Based on the work in
[PitPat-WebBT](https://github.com/KeiranY/PitPat-WebBT),
[treadmill-tray](https://github.com/heilmic/treadmill-tray) and
[HomeAssistantWalkingPad](https://github.com/sirfergy/HomeAssistantWalkingPad).

## Connection

- Advertises service `0xFBA0` (plus `0x1910`). The advertised name varies (`PitPat-T01`, `Mindtree-HID`), so match on the service.
- Write to `0xFBA1`. It supports **write with response only**. Writes without response are silently dropped.
- Subscribe to notifications on `0xFBA2`.
- One central at a time. While connected the pad stops advertising.
- The pad pushes a status frame about once a second. The host answers each one with a heartbeat or a command.
- The `0x2B10` / `0x2B11` characteristics under `0x1910` are the pad's audio speaker control, not used here.

## Status frame (notification)

Big-endian. Length is 53 bytes on firmware 37, and other firmware sends 60.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | `0x66` (firmware 37), `0x67` or `0x68` on others |
| 1 | 1 | Frame length |
| 3 | 2 | Current speed, 1/1000 km/h |
| 5 | 2 | Target speed, 1/1000 km/h |
| 7 | 4 | Distance, metres |
| 14 | 4 | Steps |
| 18 | 2 | Calories |
| 20 | 4 | Elapsed time, milliseconds |
| 25 | 1 | Firmware version |
| 26 | 1 | Flags: `0x80` panel shows mph, `0x18` state bits (`0x18` starting, `0x08` running, `0x10` paused, `0x00` stopped) |
| 27 | 2 | Maximum speed, 1/1000 km/h |
| 32 | 16 | ASCII serial number (53-byte frames), unique per pad |
| n-2 | 1 | XOR of bytes `1 ..< n-2` |
| n-1 | 1 | `0x43` |

The pad reports km/h on the wire even when its panel shows mph. It keeps speed in whole tenths of a km/h: a target of 4361 reads back as 4300.

## Commands (write)

Heartbeat, sent when there is nothing else to say: `6A 05 FD F8 43`.

Control packets are 23 bytes:

| Offset | Field |
| --- | --- |
| 0 | `0x6A` |
| 1 | `0x17` |
| 6-7 | Speed, 1/1000 km/h |
| 8 | `5` when changing speed of a running belt, otherwise `1` |
| 10 | Weight, `80` |
| 12 | Command: `4` start or set speed, `2` pause, `0` stop |
| 13-20 | User id, constant `58965456623` as 8 bytes. The firmware accepts any value |
| 21 | XOR of bytes 1 through 20 |
| 22 | `0x43` |

Starting from stopped takes a short countdown on the pad (state `starting`) before the belt moves.
