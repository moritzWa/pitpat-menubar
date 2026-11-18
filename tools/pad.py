"""PitPat FBA protocol probe. Usage:
  pad.py status
  pad.py speed <km/h>     start (if stopped) or change speed, 1.0 to 6.0
  pad.py stop
"""
import asyncio
import sys
from bleak import BleakClient, BleakScanner

SERVICE = "0000fba0-0000-1000-8000-00805f9b34fb"
WRITE = "0000fba1-0000-1000-8000-00805f9b34fb"
NOTIFY = "0000fba2-0000-1000-8000-00805f9b34fb"
HEARTBEAT = bytes([0x6A, 0x05, 0xFD, 0xF8, 0x43])
USER_ID = 58965456623
MAX_KMH = 6.0


def make_packet(kind: str, speed_units: int = 1000) -> bytes:
    a = bytearray(23)
    a[0], a[1] = 0x6A, 0x17
    a[6], a[7] = (speed_units >> 8) & 0xFF, speed_units & 0xFF
    a[8] = 5 if kind == "set_speed" else 1
    a[10] = 80
    cmd = {"pause": 2, "stop": 0}.get(kind, 4)
    a[12] = cmd & 0xF7
    a[13:21] = USER_ID.to_bytes(8, "big")
    chk = 0
    for i in range(1, 21):
        chk ^= a[i]
    a[21], a[22] = chk, 0x43
    return bytes(a)


def parse(data: bytes):
    if len(data) < 31:
        return None
    flags = data[26]
    state = {0x18: "starting", 0x08: "running", 0x10: "paused"}.get(flags & 0x18, "stopped")
    return {
        "state": state,
        "speed_kmh": int.from_bytes(data[3:5], "big") / 1000,
        "target_kmh": int.from_bytes(data[5:7], "big") / 1000,
        "max_kmh": int.from_bytes(data[27:29], "big") / 1000,
        "distance_km": int.from_bytes(data[7:11], "big") / 1000,
        "duration_s": int.from_bytes(data[20:24], "big") // 1000,
        "fw": data[25],
    }


async def find_pad(timeout=10):
    dev = await BleakScanner.find_device_by_filter(
        lambda d, adv: SERVICE in [u.lower() for u in adv.service_uuids], timeout=25
    )
    if not dev:
        sys.exit("no pad advertising FBA0 (is the PitPat app connected to it?)")
    return dev


async def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "status"
    command = None
    if mode == "speed":
        kmh = float(sys.argv[2])
        if not 1.0 <= kmh <= MAX_KMH:
            sys.exit(f"speed must be 1.0 to {MAX_KMH}")
        command = ("speed", round(kmh * 1000))
    elif mode == "stop":
        command = ("stop", 0)

    dev = await find_pad()
    print("pad:", dev.name, dev.address)
    seen = []
    state = {"sent": False, "acked_at": None}

    async with BleakClient(dev, timeout=20) as client:
        loop = asyncio.get_running_loop()

        def on_notify(_, data: bytearray):
            data = bytes(data)
            info = parse(data)
            seen.append((data, info))
            print(f"rx[{len(data)}] {data.hex()} -> {info}")
            out = HEARTBEAT
            if command and not state["sent"] and info:
                kind, units = command
                if kind == "stop":
                    out = make_packet("stop")
                elif info["state"] == "running":
                    out = make_packet("set_speed", units)
                else:
                    out = make_packet("start", units)
                state["sent"] = True
                print("tx", out.hex())
            asyncio.ensure_future(client.write_gatt_char(WRITE, out, response=True))

        await client.start_notify(NOTIFY, on_notify)
        await asyncio.sleep(6 if not command else 8)

    if not seen:
        print("no notifications received")


asyncio.run(main())
