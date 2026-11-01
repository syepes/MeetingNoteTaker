import Foundation

public struct CaptureTarget: Codable, Equatable, Sendable {
    /// nil means all computer audio. Never broaden a missing application to global capture.
    public var bundleID: String?
    public var name: String?
    public init(bundleID: String? = nil, name: String? = nil) { self.bundleID = bundleID; self.name = name }
    public var label: String { bundleID == nil ? "All computer audio" : (name ?? bundleID!) }
}
public enum CapturePhase: String, Sendable { case recording, paused, stopped }
public enum SourceAvailability: String, Sendable { case available, waiting, recovering, disabled }
public struct SourceHealth: Sendable {
    public var availability: SourceAvailability = .waiting
    public var droppedBuffers: UInt64 = 0
    public var lastBufferTime: Double?
    public var recoveryAttempt: Int = 0
    public var message: String = "Waiting for audio"
    public init() {}
}
public struct CaptureHealthSnapshot: Sendable {
    public var phase: CapturePhase = .stopped
    public var microphone = SourceHealth()
    public var computer = SourceHealth()
    public var availableBytes: Int64?
    public var storageWarning: String?
    public init() {}
    public var summary: String {
        if let storageWarning { return storageWarning }
        if phase == .paused { return "Paused — elapsed time is preserved" }
        if microphone.availability == .recovering || computer.availability == .recovering { return "Recording degraded — retrying audio source" }
        if computer.availability == .waiting { return "Recording — waiting for computer audio" }
        return "Recording"
    }
}
public enum CaptureEventKind: String, Codable, Sendable { case started, stopped, paused, resumed, gapBegan, gapEnded, buffersDropped, storageWarning, heartbeat, microphoneChanged }

/// Compact append-only JSON lines: a crash can lose at most the unsynced tail.
/// Only complete lines are replayed. Events are timestamps and diagnostics, never audio.
public final class CaptureEventJournal {
    private let handle: FileHandle
    public init(directory: URL) throws {
        let url = directory.appendingPathComponent("capture-events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
    }
    public func append(_ event: CaptureEvent, synchronize: Bool = false) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event); data.append(10); try handle.write(contentsOf: data)
        if synchronize { try handle.synchronize() }
    }
    public func close() throws { try handle.synchronize(); try handle.close() }
    public static func replay(_ directory: URL) throws -> [CaptureEvent] {
        let url = directory.appendingPathComponent("capture-events.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var pending = Data(), result: [CaptureEvent] = []
        while let bytes = try file.read(upToCount: 65536), !bytes.isEmpty {
            pending.append(bytes)
            while let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                result.append(try decoder.decode(CaptureEvent.self, from: line)); pending.removeSubrange(...end)
            }
            guard pending.count <= 65536 else { throw MeetingError.message("Capture event journal is damaged.") }
        }
        return result
    }
}
public enum CaptureRecoveryPolicy {
    public static func delay(attempt: Int) -> Double { [1.0, 2, 5][min(max(attempt, 0), 2)] + (attempt >= 3 ? 25 : 0) }
    public static func storageState(bytes: Int64) -> String? { bytes < 128*1024*1024 ? "Storage full — stopping recording" : bytes < 1024*1024*1024 ? "Low disk space — less than 1 GB available" : nil }
}
