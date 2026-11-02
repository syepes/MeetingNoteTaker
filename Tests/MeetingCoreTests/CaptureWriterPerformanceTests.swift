import XCTest
import AVFoundation
import AudioDSP
import Darwin
import CoreAudio
@testable import MeetingCore

/// Frozen pre-optimization writer, used only by the opt-in paired benchmark.
private final class LegacyCaptureWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "MeetingNoteTaker.audio.writer", qos: .userInitiated)
    let rings: CaptureRings
    let folder: URL
    let startHost: Double
    var handles: [AudioSource: FileHandle] = [:]
    var journal: CaptureEventJournal?
    var events: [CaptureEvent] = []
    var timer: DispatchSourceTimer?
    var failure: Error?
    var lastSync: Double = 0
    var pausedAt: Double?
    var pauses: [(Double, Double)] = []
    var onUpdate: (@Sendable (Float, Float, Int64?, String?) -> Void)?
    init(rings: CaptureRings, folder: URL, startHost: Double, session: MeetingSession?) throws {
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
        timer.schedule(deadline: .now(), repeating: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.drain() }; self.timer = timer; timer.resume()
    }
    func event(_ event: CaptureEvent) { queue.async { self.append(event) } }
    private func append(_ event: CaptureEvent) {
        if event.kind == .paused { pausedAt = event.time }
        if event.kind == .resumed, let start = pausedAt { pauses.append((start, event.time)); pausedAt = nil }
        // Heartbeats preserve elapsed silence on crash without filling UI/Markdown.
        if event.kind != .heartbeat { events.append(event) }
        do { try journal?.append(event, synchronize: event.kind != .heartbeat) }
        catch { failure = error }
    }
    func drain() {
        var levels: [Float] = []
        for (source, ring) in [(AudioSource.microphone, rings.mic), (.computer, rings.computer)] {
            var packet = MNTPacket(); var peak: Float = 0
            while mnt_ring_pop(ring, &packet) {
                guard failure == nil else { continue }
                do {
                    var data = Data()
                    withUnsafeBytes(of: packet.time) { data.append(contentsOf: $0) }
                    withUnsafeBytes(of: packet.rate) { data.append(contentsOf: $0) }
                    withUnsafeBytes(of: packet.count) { data.append(contentsOf: $0) }
                    let packetTime = packet.time, packetRate = packet.rate, packetCount = Int(packet.count)
                    withUnsafeMutablePointer(to: &packet) { pointer in
                        let samples = UnsafeMutablePointer(mutating: mnt_packet_samples(pointer)!)
                        for i in 0..<packetCount {
                            let time = packetTime + Double(i)/packetRate
                            if (pausedAt.map { time >= $0 } ?? false) || pauses.contains(where: { time >= $0.0 && time < $0.1 }) { samples[i] = 0 }
                            peak = max(peak, abs(samples[i]))
                        }
                        data.append(UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: packetCount*4)
                    }
                    try handles[source]?.write(contentsOf: data)
                } catch { failure = error }
            }
            levels.append(peak)
        }
        let elapsed = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - startHost
        var free: Int64?
        if elapsed-lastSync >= 5 {
            lastSync = elapsed
            free = (try? FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber)?.int64Value
            if let free, free < 128*1024*1024 { failure = MeetingError.message("Less than 128 MB of disk space remains. Recording stopped; saved chunks are recoverable.") }
            do {
                for handle in handles.values { try handle.synchronize() }
                // Force the heartbeat to stable storage with the audio checkpoint.
                try journal?.append(.init(time: elapsed, message: "", kind: .heartbeat), synchronize: true)
            } catch { failure = error }
        }
        // A processed packet cannot arrive before its ring's previous packet. Retain
        // only pause intervals that can still intersect delayed buffers (10 seconds).
        pauses.removeAll { $0.1 < elapsed-10 }
        onUpdate?(levels[0], levels[1], free, failure?.localizedDescription)
    }
    func stop(at time: Double) async throws -> [CaptureEvent] {
        timer?.cancel(); timer = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.drain(); self.append(.init(time: time, message: "Recording stopped.", kind: .stopped))
                var closeError: Error?
                for handle in self.handles.values { do { try handle.synchronize(); try handle.close() } catch { closeError = error } }
                self.handles = [:]
                do { try self.journal?.close() } catch { closeError = error }; self.journal = nil
                if let error = self.failure ?? closeError { continuation.resume(throwing: error) }
                else { continuation.resume(returning: self.events) }
            }
        }
    }
}


final class CaptureWriterPerformanceTests: XCTestCase {
    @MainActor func testDiscoveryPollingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MNT_CAPTURE_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in discovery benchmark") }
        for cached in [false, true] {
            var t = timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)
            let start = Double(t.tv_sec)+Double(t.tv_nsec)/1e9
            var ids: [AudioObjectID] = []; var reads = 0
            for second in 0..<100 {
                if !cached || second % 5 == 0 {
                    _ = AudioDevices.microphones(); ids = AudioApplications.resolve(.init()).ids; reads += 1
                }
                _ = ids.contains { AudioApplications.property($0, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) != 0 }
            }
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)
            print("CAPTURE_DISCOVERY cached=\(cached) enumerations=\(reads) cpu=\(Double(t.tv_sec)+Double(t.tv_nsec)/1e9-start)")
        }
    }

    func testPairedWriterBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["MNT_CAPTURE_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in synthetic recording benchmark") }
        func cpu() -> Double { var t = timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t); return Double(t.tv_sec)+Double(t.tv_nsec)/1e9 }
        for visible in [false, true] {
            for trial in 0..<5 {
                var results: [Double] = []; var bytes: [Data] = []
                for legacy in (trial % 2 == 0 ? [true, false] : [false, true]) {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: root) }
                    let session = MeetingSession(folder: root.path, stem: "fixture", speech: .init(), echoReduction: false)
                    try FileManager.default.createDirectory(at: session.stagingURL, withIntermediateDirectories: true)
                    let rings = CaptureRings()
                    let host = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                    let old = legacy ? try LegacyCaptureWriter(rings: rings, folder: root, startHost: host, session: session) : nil
                    let new = legacy ? nil : try CaptureWriter(rings: rings, folder: root, startHost: host, session: session)
                    new?.metersEnabled = visible
                    let samples = (0..<256).map { Float(sin(Double($0)*0.13)) }
                    let start = cpu()
                    for batch in 0..<1000 {
                        for n in 0..<6 {
                            samples.withUnsafeBufferPointer { buffer in
                                var pointer = buffer.baseAddress
                                for ring in [rings.mic, rings.computer] {
                                    XCTAssertTrue(mnt_ring_push(ring, &pointer, 1, 1, 256, 48000, Double(batch*6+n)*256/48000, false))
                                }
                            }
                        }
                        if let old { old.queue.sync { old.drain() } }
                        if let new { new.queue.sync { new.drain() } }
                    }
                    if let old { _ = try await old.stop(at: 32) }
                    if let new { _ = try await new.stop(at: 32) }
                    let elapsed = cpu()-start
                    if legacy { results.insert(elapsed, at: 0) } else { results.append(elapsed) }
                    bytes.append(try Data(contentsOf: session.stagingURL.appendingPathComponent("microphone.packets")))
                    XCTAssertEqual(mnt_ring_dropped(rings.mic), 0); XCTAssertEqual(mnt_ring_dropped(rings.computer), 0)
                }
                XCTAssertEqual(bytes[0], bytes[1])
                print("CAPTURE_WRITER visible=\(visible) trial=\(trial) baseline_cpu=\(results[0]) optimized_cpu=\(results[1])")
            }
        }
    }
}
