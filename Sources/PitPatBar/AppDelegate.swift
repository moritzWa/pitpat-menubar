import AppKit
import CoreBluetooth
import PitPatKit
import ServiceManagement

private let releasesURL = URL(string: "https://github.com/moritzWa/pitpat-menubar/releases/latest")!
private let bluetoothSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!

private struct PadMenu {
    let top: NSMenuItem
    let statusLine: NSMenuItem
    let faster: NSMenuItem
    let slower: NSMenuItem
    let speeds: [(item: NSMenuItem, units: Int)]
    let stop: NSMenuItem
    let signal: NSMenuItem
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let manager = PadManager()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var padMenus: [UUID: PadMenu] = [:]
    private var builtOrder: [UUID] = []
    private var builtBluetoothState: CBManagerState?
    private var menuIsOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "PitPat Bar")
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        manager.onChange = { [weak self] in self?.sync() }
        sync()
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        manager.refresh()
        sync()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    // MARK: Menu structure

    private func sortedPads() -> [Pad] {
        manager.pads.values.sorted { name(of: $0).localizedCaseInsensitiveCompare(name(of: $1)) == .orderedAscending }
    }

    private func name(of pad: Pad) -> String {
        if let label = manager.label(for: pad) { return label }
        if let serial = pad.serial { return "Pad \(serial.suffix(4))" }
        return "Walking pad"
    }

    private func sync() {
        let pads = sortedPads()
        let order = pads.map(\.id)
        if order != builtOrder || manager.bluetoothState != builtBluetoothState {
            rebuild(pads)
        }
        for pad in pads { update(pad) }
    }

    private func rebuild(_ pads: [Pad]) {
        menu.removeAllItems()
        padMenus = [:]
        builtOrder = pads.map(\.id)
        builtBluetoothState = manager.bluetoothState

        switch manager.bluetoothState {
        case .unauthorized:
            menu.addItem(header("Bluetooth access is off for PitPat Bar"))
            menu.addItem(action("Open Bluetooth Privacy Settings…", #selector(openBluetoothSettings)))
        case .poweredOff:
            menu.addItem(header("Bluetooth is turned off"))
        case .unsupported:
            menu.addItem(header("This Mac has no Bluetooth LE"))
        default:
            if pads.isEmpty {
                menu.addItem(header("Looking for walking pads…"))
            }
        }

        for pad in pads {
            padMenus[pad.id] = addPadMenu(for: pad)
        }

        if !pads.isEmpty || manager.bluetoothState == .poweredOn {
            menu.addItem(.separator())
            if !pads.isEmpty {
                menu.addItem(header("Pads connected to a phone app won't show up"))
            }
            menu.addItem(action("Look Again", #selector(lookAgain)))
        }
        menu.addItem(.separator())
        let login = action("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Check for Updates…", #selector(openReleases)))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(header("PitPat Bar \(version)"))
        menu.addItem(action("Quit", #selector(NSApplication.terminate(_:)), target: NSApp, key: "q"))
    }

    private func addPadMenu(for pad: Pad) -> PadMenu {
        let top = NSMenuItem(title: name(of: pad), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        top.submenu = sub

        let statusLine = header("")
        sub.addItem(statusLine)
        sub.addItem(.separator())

        let faster = action("Faster (+0.1)", #selector(adjustFaster(_:)))
        let slower = action("Slower (−0.1)", #selector(adjustSlower(_:)))
        faster.representedObject = pad.id
        slower.representedObject = pad.id
        sub.addItem(faster)
        sub.addItem(slower)
        sub.addItem(.separator())

        let imperial = pad.status?.imperial ?? true
        var speeds: [(NSMenuItem, Int)] = []
        let choices = imperial
            ? [1.0, 1.5, 2.0, 2.5, 3.0, 3.5].map { (String(format: "%.1f mph", $0), PadSpeed.units(mph: $0)) }
            : [1.0, 2.0, 3.0, 4.0, 5.0, 6.0].map { (String(format: "%.1f km/h", $0), PadSpeed.units(kmh: $0)) }
        for (title, units) in choices {
            let item = action(title, #selector(setSpeed(_:)))
            item.representedObject = [pad.id as Any, units as Any]
            sub.addItem(item)
            speeds.append((item, units))
        }
        sub.addItem(.separator())
        let stop = action("Stop", #selector(stopPad(_:)))
        stop.representedObject = pad.id
        sub.addItem(stop)
        sub.addItem(.separator())
        let rename = action("Rename…", #selector(renamePad(_:)))
        rename.representedObject = pad.id
        sub.addItem(rename)
        let signal = header("")
        sub.addItem(signal)

        menu.addItem(top)
        return PadMenu(top: top, statusLine: statusLine, faster: faster, slower: slower, speeds: speeds, stop: stop, signal: signal)
    }

    // MARK: Live updates (titles and enabled state only, so an open submenu stays open)

    private func update(_ pad: Pad) {
        guard let m = padMenus[pad.id] else { return }
        let status = pad.status
        let imperial = status?.imperial ?? true

        m.top.title = "\(name(of: pad))  ·  \(summary(of: pad, imperial: imperial))"
        m.statusLine.title = detail(of: pad, imperial: imperial)

        let reachable = pad.isInRange && pad.activity == nil
        let running = status?.state == .running
        m.faster.isEnabled = reachable && running
        m.slower.isEnabled = reachable && running
        m.stop.isEnabled = reachable && status?.state != .stopped
        for (item, units) in m.speeds {
            item.isEnabled = reachable
            let current = running || status?.state == .starting ? status?.targetUnits : nil
            item.state = current.map { $0 == units } == true ? .on : .off
        }
        m.signal.title = pad.isInRange ? "Signal: \(signalWord(pad.rssi))" : "Not in range"
    }

    private func summary(of pad: Pad, imperial: Bool) -> String {
        if let activity = pad.activity { return activity }
        if !pad.isInRange { return "out of range" }
        guard let status = pad.status else { return "checking…" }
        switch status.state {
        case .running: return speedText(status.targetUnits, imperial: imperial)
        case .starting: return "starting…"
        case .paused: return "paused"
        case .stopped: return "stopped"
        }
    }

    private func detail(of pad: Pad, imperial: Bool) -> String {
        if let error = pad.error { return "⚠︎ \(error)" }
        guard let status = pad.status else { return "Checking…" }
        let minutes = status.durationSeconds / 60
        let seconds = status.durationSeconds % 60
        let km = Double(status.distanceMeters) / 1000
        let distance = imperial ? String(format: "%.2f mi", km / 1.609344) : String(format: "%.2f km", km)
        let state: String
        switch status.state {
        case .running: state = "Running at \(speedText(status.targetUnits, imperial: imperial))"
        case .starting: state = "Starting…"
        case .paused: state = "Paused"
        case .stopped: state = "Stopped"
        }
        return status.state == .stopped
            ? state
            : "\(state) · \(distance) · \(minutes):\(String(format: "%02d", seconds))"
    }

    private func speedText(_ units: Int, imperial: Bool) -> String {
        imperial
            ? String(format: "%.1f mph", PadSpeed.mph(units: units))
            : String(format: "%.1f km/h", PadSpeed.kmh(units: units))
    }

    private func signalWord(_ rssi: Int) -> String {
        switch rssi {
        case -55...0: return "strong (closest)"
        case -75..<(-55): return "medium"
        default: return "weak"
        }
    }

    // MARK: Actions

    private func pad(from item: NSMenuItem) -> Pad? {
        guard let id = item.representedObject as? UUID else { return nil }
        return manager.pads[id]
    }

    @objc private func setSpeed(_ item: NSMenuItem) {
        guard
            let parts = item.representedObject as? [Any],
            let id = parts[0] as? UUID, let units = parts[1] as? Int,
            let pad = manager.pads[id]
        else { return }
        let imperial = pad.status?.imperial ?? true
        manager.run(.setSpeed(units: units), on: pad, activity: "setting \(speedText(units, imperial: imperial))…")
    }

    @objc private func adjustFaster(_ item: NSMenuItem) {
        guard let pad = pad(from: item) else { return }
        manager.run(.adjust(direction: 1, imperial: pad.status?.imperial ?? true), on: pad, activity: "speeding up…")
    }

    @objc private func adjustSlower(_ item: NSMenuItem) {
        guard let pad = pad(from: item) else { return }
        manager.run(.adjust(direction: -1, imperial: pad.status?.imperial ?? true), on: pad, activity: "slowing down…")
    }

    @objc private func stopPad(_ item: NSMenuItem) {
        guard let pad = pad(from: item) else { return }
        manager.run(.stop, on: pad, activity: "stopping…")
    }

    @objc private func renamePad(_ item: NSMenuItem) {
        guard let pad = pad(from: item) else { return }
        guard pad.serial != nil else {
            let alert = NSAlert()
            alert.messageText = "This pad has not answered yet"
            alert.informativeText = "Open the menu again in a few seconds, then rename it."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Name this pad"
        alert.informativeText = "Pick something your team will recognise, like \"Window pad\"."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = manager.label(for: pad) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            manager.setLabel(field.stringValue, for: pad)
        }
    }

    @objc private func lookAgain() { manager.refresh() }
    @objc private func openReleases() { NSWorkspace.shared.open(releasesURL) }
    @objc private func openBluetoothSettings() { NSWorkspace.shared.open(bluetoothSettingsURL) }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("login item change failed: %@", error.localizedDescription)
        }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Item helpers

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, target: AnyObject? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target ?? self
        return item
    }
}
