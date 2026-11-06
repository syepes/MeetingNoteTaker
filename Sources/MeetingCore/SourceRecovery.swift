import Foundation

/// Shared by both capture sources. A successful device start is not recovery:
/// only ten seconds of fresh, accepted buffers resets the failure budget.
struct SourceRecovery {
    private(set) var failures = 0
    private(set) var nextAttempt: Double?
    private var stableSince: Double?
    private var lastReturnAttempt = -Double.infinity
    mutating func failed(at time: Double) {
        guard nextAttempt == nil else { return }
        nextAttempt = time + CaptureRecoveryPolicy.delay(attempt: failures)
        failures += 1; stableSince = nil
    }
    mutating func started() { nextAttempt = nil; stableSince = nil }
    mutating func received(at time: Double) {
        if stableSince == nil { stableSince = time }
        if time - (stableSince ?? time) >= 10 { failures = 0 }
    }
    mutating func interrupted() { stableSince = nil }
    mutating func returned(at time: Double) {
        if nextAttempt != nil && time-lastReturnAttempt >= 5 { nextAttempt = time; lastReturnAttempt = time }
    }
    func due(at time: Double) -> Bool { nextAttempt.map { time >= $0 } ?? false }
}

public struct SourceCaptureDiagnostics: Codable, Sendable {
    public var expected: Bool
    public var acceptedFrames: UInt64 = 0
    public var rejectedBuffers: UInt64 = 0
    public var firstBufferTime: Double?
    public var lastBufferTime: Double?
    public var recoveryAttempts: Int = 0
    public var lastFailure: String?
    public init(expected: Bool) { self.expected = expected }
}
public struct CaptureDiagnostics: Codable, Sendable {
    public var microphoneUID: String?
    public var microphone: SourceCaptureDiagnostics
    public var computer = SourceCaptureDiagnostics(expected: true)
    public init(microphoneUID: String?, microphoneEnabled: Bool) {
        self.microphoneUID = microphoneUID; microphone = .init(expected: microphoneEnabled)
    }
}

struct ConfigurationChangeWindow {
    private var first: Double?
    private(set) var deadline: Double = 0
    mutating func changed(at time: Double) {
        if first == nil { first = time }
        deadline = min(time + 0.5, first! + 2)
    }
    mutating func reset() { first = nil; deadline = 0 }
}

enum SourceLiveness {
    case receiving, waiting, stalled, detached
    static func evaluate(attached: Bool, active: Bool, lastAccepted: Double, started: Double, now: Double) -> Self {
        guard attached else { return .detached }
        if lastAccepted >= started && now-lastAccepted < 3 { return .receiving }
        if active && now-max(lastAccepted, started) >= 5 { return .stalled }
        return .waiting
    }
}
