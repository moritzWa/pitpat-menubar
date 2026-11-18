import CoreBluetooth
import Foundation
import PitPatKit

final class Pad {
    let id: UUID
    let peripheral: CBPeripheral
    var lastSeen = Date()
    var rssi = 0
    var status: PadStatus?
    var statusAt: Date?
    var serial: String?
    var activity: String?
    var error: String?

    init(id: UUID, peripheral: CBPeripheral) {
        self.id = id
        self.peripheral = peripheral
    }

    var isInRange: Bool { activity != nil || Date().timeIntervalSince(lastSeen) < 75 }
}

/// Finds pads, remembers their names, and runs one command at a time.
final class PadManager: NSObject, CBCentralManagerDelegate {
    private static let probeMaxAge: TimeInterval = 20

    private(set) var pads: [UUID: Pad] = [:]
    private(set) var bluetoothState: CBManagerState = .unknown
    var onChange: (() -> Void)?

    private var central: CBCentralManager!
    private var queue: [(pad: Pad, goal: PadGoal, activity: String?)] = []
    private var session: PadSession?
    private var sessionPad: Pad?
    private var scanGeneration = 0
    private var scanTimer: Timer?

    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.scan(for: 4)
        }
    }

    // MARK: Names

    func label(for pad: Pad) -> String? {
        guard let serial = pad.serial else { return nil }
        return (defaults.dictionary(forKey: "labels") as? [String: String])?[serial]
    }

    func setLabel(_ label: String, for pad: Pad) {
        guard let serial = pad.serial else { return }
        var labels = defaults.dictionary(forKey: "labels") as? [String: String] ?? [:]
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        labels[serial] = trimmed.isEmpty ? nil : trimmed
        defaults.set(labels, forKey: "labels")
        onChange?()
    }

    // MARK: Discovery

    func scan(for seconds: TimeInterval) {
        guard bluetoothState == .poweredOn else { return }
        scanGeneration += 1
        let generation = scanGeneration
        central.scanForPeripherals(
            withServices: [CBUUID(string: PadBLE.service)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, generation == self.scanGeneration else { return }
            self.central.stopScan()
            self.onChange?()
        }
    }

    /// Called when the menu opens: look again, and refresh any status older than a few seconds.
    func refresh() {
        scan(for: 6)
        for pad in pads.values where pad.isInRange {
            if let at = pad.statusAt, Date().timeIntervalSince(at) < Self.probeMaxAge { continue }
            enqueue(pad, goal: .readOnly, activity: nil, urgent: false)
        }
    }

    // MARK: Commands

    func run(_ goal: PadGoal, on pad: Pad, activity: String) {
        pad.error = nil
        enqueue(pad, goal: goal, activity: activity, urgent: true)
    }

    private func enqueue(_ pad: Pad, goal: PadGoal, activity: String?, urgent: Bool) {
        if goal == .readOnly, queue.contains(where: { $0.pad === pad }) || sessionPad === pad { return }
        if urgent {
            queue.removeAll { $0.pad === pad && $0.goal == .readOnly }
            queue.insert((pad, goal, activity), at: 0)
        } else {
            queue.append((pad, goal, activity))
        }
        if let activity { pad.activity = activity }
        onChange?()
        runNext()
    }

    private func runNext() {
        guard session == nil, !queue.isEmpty, bluetoothState == .poweredOn else { return }
        let next = queue.removeFirst()
        let pad = next.pad
        if next.activity != nil { pad.activity = next.activity }
        sessionPad = pad
        let session = PadSession(central: central, peripheral: pad.peripheral, goal: next.goal) { [weak self] result in
            self?.finished(pad, result)
        }
        self.session = session
        session.start()
    }

    private func finished(_ pad: Pad, _ result: PadResult) {
        pad.activity = nil
        pad.error = result.error
        if let status = result.status {
            pad.status = status
            pad.statusAt = Date()
            if let serial = status.serial, pad.serial != serial {
                pad.serial = serial
                var serials = defaults.dictionary(forKey: "serials") as? [String: String] ?? [:]
                serials[pad.id.uuidString] = serial
                defaults.set(serials, forKey: "serials")
            }
        }
        session = nil
        sessionPad = nil
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.runNext() }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn { scan(for: 8) }
        onChange?()
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let isNew = pads[peripheral.identifier] == nil
        let pad = pads[peripheral.identifier] ?? Pad(id: peripheral.identifier, peripheral: peripheral)
        pad.lastSeen = Date()
        pad.rssi = RSSI.intValue
        if isNew {
            pad.serial = (defaults.dictionary(forKey: "serials") as? [String: String])?[pad.id.uuidString]
            pads[pad.id] = pad
            onChange?()
            enqueue(pad, goal: .readOnly, activity: nil, urgent: false)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        session?.didConnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        session?.didFailToConnect(error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral.identifier == sessionPad?.id { session?.didDisconnect(error) }
    }
}
