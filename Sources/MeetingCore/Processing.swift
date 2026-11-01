import Foundation

public enum TokenCountAccuracy: String, Codable, Sendable { case exactLocal, providerReported, conservative }
public struct InputTokenCount: Sendable {
    public var tokens: Int
    public var accuracy: TokenCountAccuracy
    public init(tokens: Int, accuracy: TokenCountAccuracy) { self.tokens = tokens; self.accuracy = accuracy }
}
public struct ProcessingProgress: Codable, Sendable {
    public var jobID: UUID
    public var stage: String
    public var completed: Int
    public var total: Int?
    public var elapsed: Double
    public var tokenAccuracy: TokenCountAccuracy?
    public var requests: Int?
    public var peakResidentBytes: UInt64?
    public var modelLoadSeconds: Double?
    public var estimatedRemaining: Double? {
        guard completed > 0, let total, total > completed else { return nil }
        return elapsed / Double(completed) * Double(total-completed)
    }
}
public struct AnalysisCheckpoint: Codable, Sendable {
    public var identity: String
    public var consumedUnits: Int
    public var findings: [AnalysisItem]
    public var requests: Int
}

/// Main-actor job ownership prevents cancelled completions from touching a newer
/// job. The task includes provider shutdown, so awaiting it is a cleanup barrier.
@MainActor public final class ProcessingCoordinator {
    public private(set) var id = UUID()
    public var task: Task<Void, Never>?
    public init() {}
    @discardableResult public func begin() -> UUID { id = UUID(); return id }
    public func owns(_ candidate: UUID) -> Bool { id == candidate }
    public func cancelAndWait() async { let previous = task; previous?.cancel(); await previous?.value }
}
