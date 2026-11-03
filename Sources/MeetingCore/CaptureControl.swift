import Foundation
import AVFoundation

/// Audio service calls can block without consuming CPU. Keep them off the UI
/// executor, and serialize discovery, device lifecycle and recovery together.
final class CaptureSerialExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeetingNoteTaker.capture.control", qos: .userInitiated)
    func enqueue(_ job: UnownedJob) {
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

@globalActor
actor CaptureControl {
    static let shared = CaptureControl()
    nonisolated let executor = CaptureSerialExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
}

/// Main-actor interface only: all hardware operations belong to CaptureWorker.
/// The command chain also prevents stop from overtaking an async start/permission request.
@MainActor public final class CoreAudioCapture: AudioCaptureBackend {
    private let worker = CaptureWorker()
    private let commands = CaptureCommandQueue()
    private var acceptsUpdates = false
    public var metersEnabled = false { didSet { let value = metersEnabled; enqueue { $0.metersEnabled = value } } }
    public var microphoneEnabled = true { didSet { let value = microphoneEnabled; enqueue { $0.microphoneEnabled = value } } }
    public private(set) var health = CaptureHealthSnapshot()
    public private(set) var wallStart = Date()
    public private(set) var fatalError: String?
    public private(set) var stoppedElapsed: Double = 0
    private var startHost: Double = 0
    private var running = false
    public var elapsed: Double { running ? AVAudioTime.seconds(forHostTime: mach_absolute_time()) - startHost : stoppedElapsed }
    public var onLevels: ((Float, Float) -> Void)?
    public var onFailure: ((String) -> Void)?
    public var onFatal: ((String) -> Void)?
    public var onHealth: ((CaptureHealthSnapshot) -> Void)?
    public init() {}

    private func enqueue(_ operation: @escaping @CaptureControl @Sendable (CaptureWorker) -> Void) {
        let worker = worker
        commands.enqueue { operation(worker) }
    }
    private func perform<T: Sendable>(_ operation: @escaping @CaptureControl @Sendable (CaptureWorker) async throws -> T) async throws -> T {
        let worker = worker
        return try await commands.perform { try await operation(worker) }
    }
    private func configureCallbacks() {
        acceptsUpdates = true
        enqueue { [weak self] worker in
            worker.onLevels = { [weak self] mic, computer in
                Task { @MainActor in guard let self, self.acceptsUpdates, self.metersEnabled else { return }; self.onLevels?(mic, computer) }
            }
            worker.onHealth = { [weak self] health in
                Task { @MainActor in
                    guard let self, self.acceptsUpdates else { return }
                    self.health = health; self.onHealth?(health)
                }
            }
            worker.onFatal = { [weak self] error in
                Task { @MainActor in guard let self, self.acceptsUpdates else { return }; self.fatalError = error; self.onFatal?(error) }
            }
        }
    }
    private func readState() async {
        let state = await worker.state
        health = state.health; wallStart = state.wallStart; fatalError = state.fatalError; stoppedElapsed = state.stoppedElapsed; startHost = state.startHost; running = state.running
    }
    public func start(session: MeetingSession, microphoneID: String) async throws {
        configureCallbacks()
        do { try await perform { try await $0.start(session: session, microphoneID: microphoneID) }; await readState() }
        catch { acceptsUpdates = false; throw error }
    }
    public func startCheck(folder: URL, target: CaptureTarget, microphoneID: String) async throws {
        metersEnabled = true; configureCallbacks()
        do { try await perform { try await $0.startCheck(folder: folder, target: target, microphoneID: microphoneID) }; await readState() }
        catch { acceptsUpdates = false; throw error }
    }
    public func pause() { enqueue { $0.pause() } }
    public func resume() { enqueue { $0.resume() } }
    public func stop() async throws -> [CaptureEvent] {
        acceptsUpdates = false
        do { let events = try await perform { try await $0.stop() }; await readState(); return events }
        catch { await readState(); throw error }
    }
}

/// Explicit ordering across suspension points; actor isolation alone would allow
/// a stop or pause to overtake start while it waits for permission.
@MainActor final class CaptureCommandQueue {
    private var tail: Task<Void, Never>?
    func enqueue(_ operation: @escaping @CaptureControl @Sendable () -> Void) {
        let previous = tail
        tail = Task { await previous?.value; await operation() }
    }
    func perform<T: Sendable>(_ operation: @escaping @CaptureControl @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { await previous?.value; return try await operation() }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
