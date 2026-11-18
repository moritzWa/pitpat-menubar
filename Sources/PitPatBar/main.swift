import AppKit

if CommandLine.arguments.contains("--scan") {
    // Diagnostic: PitPatBar.app/Contents/MacOS/PitPatBar --scan
    // Lists the pads in range and what each reports, then exits.
    // Add `--adjust 1` or `--adjust -1` to also press + or - on a running pad.
    let manager = PadManager()
    RunLoop.main.run(until: Date().addingTimeInterval(20))
    if let at = CommandLine.arguments.firstIndex(of: "--adjust"), at + 1 < CommandLine.arguments.count,
        let delta = Int(CommandLine.arguments[at + 1]), let pad = manager.pads.values.first
    {
        manager.run(.adjust(direction: delta, imperial: pad.status?.imperial ?? true), on: pad, activity: "adjusting")
        RunLoop.main.run(until: Date().addingTimeInterval(20))
    }
    print("Bluetooth: \(manager.bluetoothState.rawValue) (5 = on, 3 = no permission, 4 = off)")
    for pad in manager.pads.values {
        let status = pad.status.map { "\($0.state) target=\($0.targetUnits) max=\($0.maxUnits) fw=\($0.firmware)" } ?? "no status"
        print("pad \(pad.id) serial=\(pad.serial ?? "?") rssi=\(pad.rssi) \(status) error=\(pad.error ?? "none")")
    }
    if manager.pads.isEmpty { print("No pads found") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
