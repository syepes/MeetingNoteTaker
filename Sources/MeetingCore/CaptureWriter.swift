import Foundation
import AVFoundation
import AudioDSP
import Accelerate

/// The drain queue owns packet batching and meters. Only the disk queue touches open files.
final class CaptureWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "MeetingNoteTaker.audio.writer", qos: .userInitiated)
    let rings: CaptureRings
    let folder: URL
    let startHost: Double
    let diskQueue = DispatchQueue(label: "MeetingNoteTaker.capture.disk", qos: .utility)
    // Disk queue state, initialized before capture starts.
    private var handles: [AudioSource: FileHandle] = [:]
    private var diskFailure: Error?
    private let recording: Bool
    private var pendingBytes = 0
    private var lastFlush: [AudioSource: Double] = [:]
    private var checkpointPending = false
    private var failureReported = false
    private let backlogLimit: Int
    private let freeSpace: (URL) -> Int64?
    private(set) var audioWriteCount = 0 // disk queue; readable after stop

    var journal: CaptureEventJournal?
    var events: [CaptureEvent] = []
    var timer: DispatchSourceTimer?
    var failure: Error?
    var lastSync: Double = 0
    var batches: [AudioSource: Data] = [:]
    var metersEnabled = false
    var lastMeterUpdate: Double = 0
    var meterPeaks: [Float] = [0, 0]
    var pausedAt: Double?
    var pauses: [(Double, Double)] = []
    var onUpdate: (@Sendable (Float, Float, String?) -> Void)?
    init(rings: CaptureRings, folder: URL, startHost: Double, session: MeetingSession?,
         backlogLimit: Int = 8 * 1024 * 1024,
         freeSpace: @escaping (URL) -> Int64? = { (try? FileManager.default.attributesOfFileSystem(forPath: $0.path)[.systemFreeSize] as? NSNumber)?.int64Value }) throws {
        self.backlogLimit = backlogLimit
        self.freeSpace = freeSpace
        recording = session != nil
        self.rings = rings; self.folder = folder; self.startHost = startHost
        if let session {
            journal = try CaptureEventJournal(directory: session.stagingURL)
            for source in AudioSource.allCases {
                let url = session.stagingURL.appendingPathComponent(source.rawValue + ".packets")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handles[source] = try FileHandle(forWritingTo: url)
            }
        }
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(30), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.drain() }; self.timer = timer; timer.resume()
    }
    func event(_ event: CaptureEvent) { queue.async { self.append(event) } }
    private func append(_ event: CaptureEvent) {
        if event.kind == .paused { pausedAt = event.time }
        if event.kind == .resumed, let start = pausedAt { pauses.append((start, event.time)); pausedAt = nil }
        // Heartbeats preserve elapsed silence on crash without filling UI/Markdown.
        if event.kind != .heartbeat { events.append(event) }
        diskQueue.async {
            guard self.diskFailure == nil else { return }
            do { try self.journal?.append(event, synchronize: event.kind != .heartbeat) }
            catch { self.diskFailed(error) }
        }
    }
    private func diskFailed(_ error: Error) {
        guard diskFailure == nil else { return }
        diskFailure = error
        queue.async {
            self.failure = self.failure ?? error
            self.reportFailure()
        }
    }

    private func reportFailure() {
        guard let failure, !failureReported else { return }
        failureReported = true
        onUpdate?(0, 0, failure.localizedDescription)
    }

    private func submit(_ data: Data, source: AudioSource) {
        guard !data.isEmpty else { return }
        diskQueue.async {
            if self.diskFailure == nil {
                do {
                    try self.handles[source]?.write(contentsOf: data)
                    self.audioWriteCount += 1
                } catch { self.diskFailed(error) }
            }
            let size = data.count
            self.queue.async { self.pendingBytes -= size }
        }
    }

    private func flushBatches() {
        for source in AudioSource.allCases {
            if let data = batches.removeValue(forKey: source) { submit(data, source: source) }
        }
        lastFlush.removeAll(keepingCapacity: true)
    }

    private func checkpoint(at elapsed: Double) {
        flushBatches()
        lastSync = elapsed
        checkpointPending = true
        diskQueue.async {
            let free = self.freeSpace(self.folder)
            if self.diskFailure == nil {
                do {
                    let start = ProcessInfo.processInfo.systemUptime
                    for handle in self.handles.values { try handle.synchronize() }
                    try self.journal?.append(.init(time: elapsed, message: "", kind: .heartbeat), synchronize: true)
                    let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    if ms >= 100 {
                        try self.journal?.append(.init(time: elapsed, message: "Audio checkpoint synchronization took \(ms) ms.", kind: .captureDiagnostic))
                    }
                    if let free, free < 128 * 1024 * 1024 {
                        throw MeetingError.message("Less than 128 MB of disk space remains. Recording stopped; saved chunks are recoverable.")
                    }
                } catch { self.diskFailed(error) }
            }
            self.queue.async {
                self.checkpointPending = false
                if let free { self.onStorage?(free) }
            }
        }
    }

    var onStorage: (@Sendable (Int64) -> Void)?
    func drain() {
        drain(at: AVAudioTime.seconds(forHostTime: mach_absolute_time()) - startHost)
    }

    func drain(at elapsed: Double) {
        var levels: [Float] = []
        for (source, ring) in [(AudioSource.microphone, rings.mic), (.computer, rings.computer)] {
            var packet = MNTPacket(); var peak: Float = 0
            var data = batches.removeValue(forKey: source) ?? Data()
            while mnt_ring_pop(ring, &packet) {
                guard failure == nil else { continue }
                if recording {
                    let size = 20 + Int(packet.count) * MemoryLayout<Float>.size
                    guard size <= backlogLimit - pendingBytes else {
                        failure = MeetingError.message("Storage could not keep up with recording. Buffered audio is being saved for recovery.")
                        reportFailure()
                        continue
                    }
                    pendingBytes += size
                    if data.isEmpty { lastFlush[source] = elapsed }
                    withUnsafeBytes(of: packet.time) { data.append(contentsOf: $0) }
                    withUnsafeBytes(of: packet.rate) { data.append(contentsOf: $0) }
                    withUnsafeBytes(of: packet.count) { data.append(contentsOf: $0) }
                }
                let packetTime = packet.time, packetRate = packet.rate, packetCount = Int(packet.count)
                withUnsafeMutablePointer(to: &packet) { pointer in
                    let samples = UnsafeMutablePointer(mutating: mnt_packet_samples(pointer)!)
                    let packetEnd = packetTime + Double(packetCount-1)/packetRate
                    let overlaps = (pausedAt.map { packetEnd >= $0 } ?? false) || pauses.contains { packetEnd >= $0.0 && packetTime < $0.1 }
                    let fullyPaused = (pausedAt.map { packetTime >= $0 } ?? false) || pauses.contains { packetTime >= $0.0 && packetEnd < $0.1 }
                    if fullyPaused { samples.update(repeating: 0, count: packetCount) }
                    else if overlaps {
                        for i in 0..<packetCount {
                            let time = packetTime + Double(i)/packetRate
                            if (pausedAt.map { time >= $0 } ?? false) || pauses.contains(where: { time >= $0.0 && time < $0.1 }) { samples[i] = 0 }
                        }
                    }
                    if metersEnabled {
                        var packetPeak: Float = 0
                        vDSP_maxmgv(samples, 1, &packetPeak, vDSP_Length(packetCount))
                        peak = max(peak, packetPeak)
                    }
                    if recording { data.append(UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: packetCount*4) }
                }
                if data.count >= 256 * 1024 {
                    submit(data, source: source)
                    data = Data()
                }
            }
            if !data.isEmpty, elapsed - (lastFlush[source] ?? elapsed) >= 0.25 {
                submit(data, source: source)
            } else if !data.isEmpty {
                batches[source] = data
            }
            levels.append(peak)
        }
        if elapsed - lastSync >= 5 && !checkpointPending && failure == nil {
            checkpoint(at: elapsed)
        }
        // A processed packet cannot arrive before its ring's previous packet. Retain
        // only pause intervals that can still intersect delayed buffers (10 seconds).
        pauses.removeAll { $0.1 < elapsed-10 }
        meterPeaks[0] = max(meterPeaks[0], levels[0]); meterPeaks[1] = max(meterPeaks[1], levels[1])
        reportFailure()
        if metersEnabled && elapsed-lastMeterUpdate >= 0.1 && failure == nil {
            lastMeterUpdate = elapsed
            onUpdate?(meterPeaks[0], meterPeaks[1], nil)
            meterPeaks = [0, 0]
        }
    }
    func stop(at time: Double) async throws -> [CaptureEvent] {
        timer?.cancel(); timer = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.drain()
                self.flushBatches()
                let stopped = CaptureEvent(time: time, message: "Recording stopped.", kind: .stopped)
                let events = self.events + [stopped]
                let drainError = self.failure
                self.diskQueue.async {
                    var error = drainError ?? self.diskFailure
                    for handle in self.handles.values {
                        do { try handle.synchronize() } catch let issue { error = error ?? issue }
                        do { try handle.close() } catch let issue { error = error ?? issue }
                    }
                    self.handles.removeAll()
                    if error == nil {
                        do { try self.journal?.append(stopped) } catch let issue { error = issue }
                    }
                    do { try self.journal?.close() } catch let issue { error = error ?? issue }
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: events) }
                }
            }
        }
    }
}
