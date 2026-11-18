import CoreBluetooth
import Foundation
import PitPatKit
import os

struct PadResult {
    var status: PadStatus?
    var error: String?
}

/// One short connection to one pad: connect, listen to its status pushes, answer each with the
/// next move from `PadSessionMachine`, then disconnect so the pad is free for the next person.
final class PadSession: NSObject, CBPeripheralDelegate {
    private static let log = Logger(subsystem: "io.github.moritzwa.pitpatbar", category: "session")
    private static let timeout: TimeInterval = 20

    private let central: CBCentralManager
    let peripheral: CBPeripheral
    private var machine: PadSessionMachine
    private var completion: ((PadResult) -> Void)?
    private var writeCharacteristic: CBCharacteristic?
    private var lastStatus: PadStatus?
    private var unreadableFrames = 0
    private var writeInFlight = false
    private var timeoutWork: DispatchWorkItem?

    init(central: CBCentralManager, peripheral: CBPeripheral, goal: PadGoal, completion: @escaping (PadResult) -> Void) {
        self.central = central
        self.peripheral = peripheral
        self.machine = PadSessionMachine(goal: goal)
        self.completion = completion
    }

    func start() {
        peripheral.delegate = self
        let work = DispatchWorkItem { [weak self] in self?.finish(error: "Pad did not respond") }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: work)
        central.connect(peripheral)
    }

    // MARK: Connection events, forwarded by PadManager

    func didConnect() {
        peripheral.discoverServices([CBUUID(string: PadBLE.service)])
    }

    func didFailToConnect(_ error: Error?) {
        finish(error: "Could not connect. Is the PitPat app open on a phone?")
    }

    func didDisconnect(_ error: Error?) {
        finish(error: "Pad disconnected")
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: PadBLE.service) }) else {
            return finish(error: "This does not look like a PitPat pad")
        }
        peripheral.discoverCharacteristics([CBUUID(string: PadBLE.write), CBUUID(string: PadBLE.notify)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        guard
            let write = characteristics.first(where: { $0.uuid == CBUUID(string: PadBLE.write) }),
            let notify = characteristics.first(where: { $0.uuid == CBUUID(string: PadBLE.notify) })
        else { return finish(error: "Pad is missing its control channel") }
        writeCharacteristic = write
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard completion != nil, let data = characteristic.value else { return }
        guard let status = PadFrame.parse(data) else {
            unreadableFrames += 1
            let hex = data.map { String(format: "%02x", $0) }.joined()
            Self.log.error("unreadable frame (\(data.count) bytes): \(hex, privacy: .public)")
            if unreadableFrames >= 5 { finish(error: "This pad's firmware is not supported yet") }
            return
        }
        lastStatus = status
        switch machine.onStatus(status) {
        case .heartbeat: write(PadCommand.heartbeat)
        case .send(let command): write(command.packet)
        case .succeed: finish(error: nil)
        case .fail(.notRunning): finish(error: "Pad is not running")
        case .fail(.ignored): finish(error: "Pad ignored the command")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeInFlight = false
        if let error { finish(error: "Write failed: \(error.localizedDescription)") }
    }

    // MARK: Private

    private func write(_ data: Data) {
        guard let characteristic = writeCharacteristic, !writeInFlight else { return }
        writeInFlight = true
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    private func finish(error: String?) {
        guard let completion else { return }
        self.completion = nil
        timeoutWork?.cancel()
        central.cancelPeripheralConnection(peripheral)
        completion(PadResult(status: lastStatus, error: error))
    }
}
