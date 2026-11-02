import XCTest
import AVFoundation
import AudioDSP
@testable import MeetingCore

final class CaptureCPUOptimizationTests: XCTestCase {
    func testBatchedWriterPreservesPacketsAndPauseBoundaries() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = MeetingSession(folder: folder.path, stem: "fixture", speech: .init(), echoReduction: false)
        try FileManager.default.createDirectory(at: session.stagingURL, withIntermediateDirectories: true)
        let rings = CaptureRings()
        let writer = try CaptureWriter(rings: rings, folder: folder, startHost: AVAudioTime.seconds(forHostTime: mach_absolute_time()), session: session)
        writer.event(.init(time: 0.01, message: "", kind: .paused))
        writer.event(.init(time: 0.02, message: "", kind: .resumed))
        var expected = Data()
        for index in 0..<6 {
            var time = Double(index)*1024/48000, rate = 48000.0, count = UInt32(1024)
            let samples = (0..<1024).map { Float(sin(Double($0)*0.13)) }
            samples.withUnsafeBufferPointer { buffer in
                var pointer = buffer.baseAddress
                XCTAssertTrue(mnt_ring_push(rings.mic, &pointer, 1, 1, count, rate, time, false))
            }
            withUnsafeBytes(of: &time) { expected.append(contentsOf: $0) }
            withUnsafeBytes(of: &rate) { expected.append(contentsOf: $0) }
            withUnsafeBytes(of: &count) { expected.append(contentsOf: $0) }
            var masked = samples.enumerated().map { i, x -> Float in
                let t = time + Double(i)/rate
                return t >= 0.01 && t < 0.02 ? 0 : x
            }
            masked.withUnsafeMutableBytes { expected.append(contentsOf: $0) }
        }
        writer.queue.sync { writer.drain() }
        _ = try await writer.stop(at: 0.128)
        XCTAssertEqual(try Data(contentsOf: session.stagingURL.appendingPathComponent("microphone.packets")), expected)
        XCTAssertEqual(mnt_ring_dropped(rings.mic), 0)
    }

    func testHiddenMetersStayQuietAndErrorsStillPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try CaptureWriter(rings: CaptureRings(), folder: root, startHost: AVAudioTime.seconds(forHostTime: mach_absolute_time())-1, session: nil)
        final class Counter: @unchecked Sendable { var value = 0 }
        let updates = Counter()
        writer.onUpdate = { _, _, _, _ in updates.value += 1 }
        writer.queue.sync {
            writer.drain(); XCTAssertEqual(updates.value, 0)
            writer.metersEnabled = true; writer.drain(); XCTAssertEqual(updates.value, 1)
            for _ in 0..<10 { writer.drain() }; XCTAssertEqual(updates.value, 1)
            writer.metersEnabled = false; writer.failure = MeetingError.message("fixture error")
            writer.drain(); XCTAssertEqual(updates.value, 2)
        }
        do { _ = try await writer.stop(at: 1) } catch { }
    }

    func testRingFastPathsMatchScalarReference() {
        let ring = mnt_ring_create()!; defer { mnt_ring_destroy(ring) }
        let samples = (0..<2048).map { Float(sin(Double($0)*0.13)) }
        for channels in [1, 2] {
            for stride in [1, 2] {
                for muted in [false, true] {
                    for start in [-1.0, 0, 0.005, 0.05] {
                        mnt_ring_reset(ring)
                        if start >= 0 { mnt_ring_pause(ring, start); mnt_ring_resume(ring, start+0.01) }
                        var packet = MNTPacket()
                        samples.withUnsafeBufferPointer { buffer in
                            var pointers = [buffer.baseAddress, buffer.baseAddress]
                            XCTAssertTrue(mnt_ring_push(ring, &pointers, UInt32(channels), UInt32(stride), 1024, 48000, 0, muted))
                        }
                        XCTAssertTrue(mnt_ring_pop(ring, &packet))
                        withUnsafePointer(to: &packet) { ptr in
                            let actual = mnt_packet_samples(ptr)!
                            for i in 0..<1024 {
                                let t = Double(i)/48000
                                let paused = start >= 0 && t >= start && t < start+0.01
                                XCTAssertEqual(actual[i], muted || paused ? 0 : samples[i*stride])
                            }
                        }
                    }
                }
            }
        }
    }
}
