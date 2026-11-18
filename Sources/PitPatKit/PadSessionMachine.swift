import Foundation

public enum PadGoal: Equatable {
    case readOnly
    case setSpeed(units: Int)
    /// One panel step faster (+1) or slower (-1). Only valid while the belt runs.
    case adjust(direction: Int, imperial: Bool)
    case stop
}

public enum PadFailure: Equatable {
    case notRunning
    case ignored
}

public enum PadReply: Equatable {
    case heartbeat
    case send(PadCommand)
    case succeed
    case fail(PadFailure)
}

/// Decides what to say to the pad after each status notification it pushes.
/// No Bluetooth, clocks or logging in here, so every case is a plain test.
public struct PadSessionMachine {
    public private(set) var goal: PadGoal
    private var sent = 0
    private var statusesSinceSend = 0
    private var statusesWhileStarting = 0

    static let maxSends = 3
    /// The pad needs a moment to act on a command. Do not repeat one before this many statuses.
    static let statusesBeforeResend = 3
    static let maxStatusesWhileStarting = 15

    public init(goal: PadGoal) {
        self.goal = goal
    }

    public mutating func onStatus(_ status: PadStatus) -> PadReply {
        if case .adjust(let direction, let imperial) = goal {
            guard status.state == .running else { return .fail(.notRunning) }
            goal = .setSpeed(units: PadSpeed.step(from: status.targetUnits, direction: direction, imperial: imperial))
        }

        statusesSinceSend += 1

        switch goal {
        case .readOnly:
            return .succeed
        case .adjust:
            return .heartbeat
        case .stop:
            if status.state == .stopped { return .succeed }
            return sendUnlessWaiting(.stop)
        case .setSpeed(let units):
            let wanted = PadSpeed.clamp(units)
            switch status.state {
            case .running:
                if status.targetUnits == wanted { return .succeed }
                return sendUnlessWaiting(.setSpeed(units: wanted))
            case .starting:
                statusesWhileStarting += 1
                return statusesWhileStarting > Self.maxStatusesWhileStarting ? .fail(.ignored) : .heartbeat
            case .stopped, .paused:
                return sendUnlessWaiting(.start(units: wanted))
            }
        }
    }

    private mutating func sendUnlessWaiting(_ command: PadCommand) -> PadReply {
        if sent > 0 && statusesSinceSend < Self.statusesBeforeResend { return .heartbeat }
        if sent >= Self.maxSends { return .fail(.ignored) }
        sent += 1
        statusesSinceSend = 0
        return .send(command)
    }
}
