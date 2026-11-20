import AppKit
import AVFoundation
import AudioDSP
import XCTest
@testable import MeetingCore

final class CaptureBacklogTests: XCTestCase {
    private func fixture(limit: Int = 8 * 1024 * 1024, elapsed: Double = 0,
                         free: @escaping (URL) -> Int64? = { _ in Int64.max }) throws -> (MeetingSession, CaptureWriter) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let session = MeetingSession(folder: root.path, stem: "fixture", speech: .init(), echoReduction: false)
        try FileManager.default.createDirectory(at: session.stagingURL, withIntermediateDirectories: true)
        let host = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let writer = try CaptureWriter(rings: CaptureRings(), folder: root, startHost: host - elapsed,
                                       session: session, backlogLimit: limit, freeSpace: free)
        return (session, writer)
    }

    private func push(_ writer: CaptureWriter, tick: Int) {
        // Each tick represents 30 ms of continuous full-duplex audio.
        let values = [Float](repeating: 0.25, count: 1440)
        values.withUnsafeBufferPointer { samples in
            var pointer = samples.baseAddress
            for ring in [writer.rings.mic, writer.rings.computer] {
                XCTAssertTrue(mnt_ring_push(ring, &pointer, 1, 1, 1440, 48000, Double(tick) * 0.03, false))
            }
        }
    }

    func testDiskStallKeepsMetersWindowsAndStopResponsive() async throws {
        let (session, writer) = try fixture(elapsed: 5)
        let windows = await MainActor.run {
            _ = NSApplication.shared
            return (NSPanel(), NSWindow())
        }
        let stallEnded = DispatchSemaphore(value: 0)
        let entered = expectation(description: "disk queue stalled")
        writer.diskQueue.async {
            entered.fulfill()
            Thread.sleep(forTimeInterval: 2)
            stallEnded.signal()
        }
        await fulfillment(of: [entered], timeout: 1)
        let meters = expectation(description: "meter updates during stall")
        meters.expectedFulfillmentCount = 5
        meters.assertForOverFulfill = false
        writer.metersEnabled = true
        writer.onUpdate = { mic, computer, error in
            if mic > 0 && computer > 0 { meters.fulfill() }
            XCTAssertNil(error)
        }
        writer.start()
        let ticks = 45
        var latency: [Double] = []
        for tick in 0..<ticks {
            push(writer, tick: tick)
            let start = ProcessInfo.processInfo.systemUptime
            await MainActor.run {
                if tick == 5 { windows.0.orderFront(nil) }
                if tick == 10 { windows.0.orderOut(nil); windows.1.orderFront(nil) }
                if tick == 15 { windows.1.orderOut(nil) }
            }
            latency.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await Task.sleep(for: .milliseconds(30))
        }
        let p95 = latency.sorted()[Int(Double(ticks - 1) * 0.95)]
        XCTAssertLessThan(p95, 100)
        let before = try CaptureEventJournal.replay(session.stagingURL)
        XCTAssertFalse(before.contains { $0.kind == .heartbeat })
        let stop = await MainActor.run {
            Task { try await writer.stop(at: Double(ticks) * 0.03 + 5) }
        }
        // Both button dispatch and further main-actor work complete before disk unblocks.
        await MainActor.run { XCTAssertEqual(stallEnded.wait(timeout: .now()), .timedOut) }
        _ = try await stop.value
        await fulfillment(of: [meters], timeout: 1)
        for source in AudioSource.allCases {
            let reader = try PacketReader(session.stagingURL.appendingPathComponent(source.rawValue + ".packets"))
            for tick in 0..<ticks {
                XCTAssertEqual(reader.time, Double(tick) * 0.03, accuracy: 1e-9)
                XCTAssertEqual(reader.samples.count, 1440)
                try reader.advance()
            }
            XCTAssertTrue(reader.eof)
        }
        XCTAssertEqual(mnt_ring_dropped(writer.rings.mic) + mnt_ring_dropped(writer.rings.computer), 0)
        let after = try CaptureEventJournal.replay(session.stagingURL)
        XCTAssertTrue(after.contains { $0.kind == .heartbeat })
        XCTAssertEqual(after.last?.kind, .stopped)
        XCTAssertLessThanOrEqual(writer.audioWriteCount, ticks * 2 / 4)
        print("CAPTURE_STALL baseline_writes=\(ticks * 2) batched_writes=\(writer.audioWriteCount) main_p95_ms=\(p95)")
    }

    func testOverflowReportsOnceAndPreservesBufferedPrefix() async throws {
        let (session, writer) = try fixture(limit: 12_000)
        let errors = expectation(description: "one backlog failure")
        writer.onUpdate = { _, _, error in if error != nil { errors.fulfill() } }
        for i in 0..<4 { push(writer, tick: i); writer.queue.sync { writer.drain() } }
        do { _ = try await writer.stop(at: 0.12); XCTFail("Expected storage backlog failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("keep up")) }
        await fulfillment(of: [errors], timeout: 1)
        for source in AudioSource.allCases {
            let detail = try PacketReader.statistics(session.stagingURL.appendingPathComponent(source.rawValue + ".packets"))
            XCTAssertEqual(detail.acceptedFrames, 1440)
        }
    }

    func testRecoverySeesPreviousCheckpointWhileNextIsBlocked() async throws {
        let entered = expectation(description: "second checkpoint reached disk queue")
        let release = DispatchSemaphore(value: 0)
        var checks = 0 // accessed only on the serial disk queue
        let (session, writer) = try fixture(elapsed: 5) { _ in
            checks += 1
            if checks == 2 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
            return Int64.max
        }
        push(writer, tick: 0)
        writer.queue.sync { writer.drain() }
        writer.diskQueue.sync {}
        let durable = try CaptureEventJournal.replay(session.stagingURL)
        XCTAssertEqual(durable.filter { $0.kind == .heartbeat }.count, 1)
        push(writer, tick: 1)
        writer.queue.sync {
            writer.lastSync -= 5
            writer.drain()
        }
        await fulfillment(of: [entered], timeout: 2)
        defer { release.signal() }
        let interrupted = try CaptureEventJournal.replay(session.stagingURL)
        XCTAssertEqual(interrupted.map(\.time), durable.map(\.time))
        for source in AudioSource.allCases {
            let packets = try PacketReader(session.stagingURL.appendingPathComponent(source.rawValue + ".packets"))
            XCTAssertEqual(packets.time, 0)
            XCTAssertEqual(packets.samples, [Float](repeating: 0.25, count: 1440))
        }
        release.signal()
        _ = try await writer.stop(at: 6)
        XCTAssertEqual(try CaptureEventJournal.replay(session.stagingURL).filter { $0.kind == .heartbeat }.count, 2)
    }

    func testLowSpaceStopsAfterDurableCheckpoint() async throws {
        let (session, writer) = try fixture(elapsed: 5, free: { _ in 1024 })
        push(writer, tick: 0)
        writer.queue.sync { writer.drain() }
        do { _ = try await writer.stop(at: 5.1); XCTFail("Expected low space failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("disk space")) }
        XCTAssertTrue(try CaptureEventJournal.replay(session.stagingURL).contains { $0.kind == .heartbeat })
        for source in AudioSource.allCases {
            XCTAssertEqual(try PacketReader.statistics(session.stagingURL.appendingPathComponent(source.rawValue + ".packets")).acceptedFrames, 1440)
        }
    }
}
