import XCTest
@testable import PitPatKit

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func status(
    _ state: PadStatus.State,
    target: Int = 0,
    max: Int = 6000
) -> PadStatus {
    PadStatus(
        state: state, speedUnits: target, targetUnits: target, maxUnits: max,
        distanceMeters: 0, calories: 0, steps: 0, durationSeconds: 0,
        firmware: 37, imperial: true, serial: nil
    )
}

final class PacketTests: XCTestCase {
    // Packets captured from the PitPat app, documented in heilmic/treadmill-tray.
    func testPacketsMatchCapturedApp() {
        XCTAssertEqual(hex(PadCommand.start(units: 1000).packet), "6a170000000003e801005000040000000dba9d76ef1a43")
        XCTAssertEqual(hex(PadCommand.setSpeed(units: 1200).packet), "6a170000000004b005005000040000000dba9d76ef4143")
        XCTAssertEqual(hex(PadCommand.pause.packet), "6a1700000000000001005000020000000dba9d76eff743")
        XCTAssertEqual(hex(PadCommand.stop.packet), "6a1700000000000001005000000000000dba9d76eff543")
    }

    func testSpeedIsClampedInThePacket() {
        XCTAssertEqual(PadCommand.setSpeed(units: 9000).packet, PadCommand.setSpeed(units: 6000).packet)
        XCTAssertEqual(PadCommand.start(units: 10).packet, PadCommand.start(units: 1000).packet)
    }

    func testMphConversion() {
        XCTAssertEqual(PadSpeed.units(mph: 2.5), 4000)
        XCTAssertEqual(PadSpeed.units(kmh: 4.2), 4200)
        XCTAssertEqual(PadSpeed.units(mph: 3.7), 6000, "capped")
        XCTAssertEqual(PadSpeed.mph(units: 4000), 2.485, accuracy: 0.001)
    }
}

final class FrameTests: XCTestCase {
    // Captured from a PitPat-T01, firmware 37, running at 4.0 km/h (panel showed 2.5 mph).
    let captured = "6635000fa00fa0000000740000000000000000080001b1984c258b177000050274456376316252736239533067353230000000dd43"

    func testParsesCapturedFrame() throws {
        let data = Data(stride(from: 0, to: captured.count, by: 2).map {
            UInt8(captured[captured.index(captured.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
        })
        let parsed = try XCTUnwrap(PadFrame.parse(data))
        XCTAssertEqual(parsed.state, .running)
        XCTAssertEqual(parsed.speedUnits, 4000)
        XCTAssertEqual(parsed.targetUnits, 4000)
        XCTAssertEqual(parsed.maxUnits, 6000)
        XCTAssertEqual(parsed.distanceMeters, 116)
        XCTAssertEqual(parsed.durationSeconds, 111)
        XCTAssertEqual(parsed.firmware, 37)
        XCTAssertTrue(parsed.imperial)
        XCTAssertEqual(parsed.serial, "tEcv1bRsb9S0g520")
    }

    func testRejectsCorruptFrames() {
        var bytes = [UInt8](repeating: 0, count: 53)
        bytes[1] = 53
        bytes[52] = 0x43
        XCTAssertNil(PadFrame.parse(Data(bytes)), "bad checksum and implausible max speed")
        XCTAssertNil(PadFrame.parse(Data([0x6A, 0x05, 0xFD, 0xF8, 0x43])), "a command is not a status")
    }
}

final class MachineTests: XCTestCase {
    func testStoppedPadIsStartedAtTheWantedSpeed() {
        var m = PadSessionMachine(goal: .setSpeed(units: 4000))
        XCTAssertEqual(m.onStatus(status(.stopped)), .send(.start(units: 4000)))
        XCTAssertEqual(m.onStatus(status(.starting, target: 4000)), .heartbeat)
        XCTAssertEqual(m.onStatus(status(.running, target: 4000)), .succeed)
    }

    func testRunningPadGetsASpeedChange() {
        var m = PadSessionMachine(goal: .setSpeed(units: 4200))
        XCTAssertEqual(m.onStatus(status(.running, target: 4000)), .send(.setSpeed(units: 4200)))
        XCTAssertEqual(m.onStatus(status(.running, target: 4000)), .heartbeat)
        XCTAssertEqual(m.onStatus(status(.running, target: 4200)), .succeed)
    }

    func testAdjustMovesTheDisplayedMphByATenth() {
        // 4.0 km/h shows as 2.5 mph, so one press goes to 2.6 mph = 4.2 km/h.
        var m = PadSessionMachine(goal: .adjust(direction: 1, imperial: true))
        XCTAssertEqual(m.onStatus(status(.running, target: 4000)), .send(.setSpeed(units: 4200)))
    }

    func testEveryMphPressMovesTheDisplayUntilTheCap() {
        var units = 1000
        for _ in 0..<60 where units < 6000 {
            let next = PadSpeed.step(from: units, direction: 1, imperial: true)
            XCTAssertGreaterThan(next, units)
            XCTAssertEqual(
                (PadSpeed.mph(units: next) * 10).rounded() - (PadSpeed.mph(units: units) * 10).rounded(), 1,
                accuracy: 1, "display moves by one tenth, give or take rounding"
            )
            units = next
        }
        XCTAssertEqual(units, 6000)
    }

    func testMetricPressIsATenthOfAKmh() {
        XCTAssertEqual(PadSpeed.step(from: 4000, direction: -1, imperial: false), 3900)
    }

    func testAdjustStopsAtTheCap() {
        var m = PadSessionMachine(goal: .adjust(direction: 1, imperial: false))
        XCTAssertEqual(m.onStatus(status(.running, target: 5900)), .send(.setSpeed(units: 6000)))
    }

    func testAdjustOnAStoppedPadDoesNothing() {
        var m = PadSessionMachine(goal: .adjust(direction: 1, imperial: true))
        XCTAssertEqual(m.onStatus(status(.stopped)), .fail(.notRunning))
    }

    func testIgnoredCommandsGiveUpAfterThreeTries() {
        var m = PadSessionMachine(goal: .setSpeed(units: 4200))
        var sends = 0
        var last = PadReply.heartbeat
        for _ in 0..<30 {
            last = m.onStatus(status(.running, target: 4000))
            if case .send = last { sends += 1 }
            if last == .fail(.ignored) { break }
        }
        XCTAssertEqual(sends, 3)
        XCTAssertEqual(last, .fail(.ignored))
    }

    func testStopWaitsForTheBeltToStop() {
        var m = PadSessionMachine(goal: .stop)
        XCTAssertEqual(m.onStatus(status(.running, target: 4000)), .send(.stop))
        XCTAssertEqual(m.onStatus(status(.running, target: 4000)), .heartbeat)
        XCTAssertEqual(m.onStatus(status(.stopped)), .succeed)
    }

    func testReadOnlyNeverSendsACommand() {
        var m = PadSessionMachine(goal: .readOnly)
        XCTAssertEqual(m.onStatus(status(.running, target: 4000)), .succeed)
    }
}
