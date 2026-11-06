import XCTest
import AudioDSP
@testable import MeetingCore

final class SourceRecoveryTests: XCTestCase {
    func testSelectedMicrophoneSurvivesDeviceIDChangeWithoutSubstitution() {
        let before = [MicrophoneDevice(id: "chosen", name: "Mic", objectID: 10)]
        let uid = AudioDevices.selectedUID(requested: "", defaultDevice: 10, devices: before)
        let after = [MicrophoneDevice(id: "other", name: "Other", objectID: 11), MicrophoneDevice(id: "chosen", name: "Mic", objectID: 99)]
        XCTAssertEqual(AudioDevices.selectedUID(requested: uid, defaultDevice: 11, devices: after), "chosen")
        XCTAssertEqual(after.first { $0.id == uid }?.objectID, 99)
        XCTAssertEqual(AudioDevices.selectedUID(requested: uid, defaultDevice: 11, devices: Array(after.prefix(1))), "chosen")
    }
    func testPartialExportPreservesChannelsAndRebuildsDiagnostics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = MeetingSession(folder: root.path, stem: "partial", speech: .init(), echoReduction: false)
        session.duration = 0.02; session.captureDiagnostics = .init(microphoneUID: "chosen", microphoneEnabled: true)
        try FileManager.default.createDirectory(at: session.stagingURL, withIntermediateDirectories: true)
        try Data().write(to: session.stagingURL.appendingPathComponent("microphone.packets"))
        var data = Data(); var time = 0.0, rate = 16000.0; var count: UInt32 = 320
        withUnsafeBytes(of: &time) { data.append(contentsOf: $0) }; withUnsafeBytes(of: &rate) { data.append(contentsOf: $0) }; withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        [Float](repeating: 0.25, count: 320).withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: session.stagingURL.appendingPathComponent("computer.packets"))
        let result = try AudioFiles.finalize(session)
        session.captureDiagnostics = result.diagnostics; session.status = .recorded
        XCTAssertEqual(session.captureWarnings.count, 1)
        XCTAssertEqual(result.diagnostics?.computer.acceptedFrames, 320)
        let left = try AudioFiles.samples(session.audioURL, channel: 0, start: 0, duration: 0.02)
        let right = try AudioFiles.samples(session.audioURL, channel: 1, start: 0, duration: 0.02)
        XCTAssertTrue(left.allSatisfy { $0 == 0 }); XCTAssertGreaterThan(right.max() ?? 0, 0.2)
    }
    func testConfigurationStormHasBoundedDebounce() {
        var changes = ConfigurationChangeWindow()
        changes.changed(at: 0); XCTAssertEqual(changes.deadline, 0.5)
        for tick in 1...19 { changes.changed(at: Double(tick)/10) }
        XCTAssertEqual(changes.deadline, 2)
        changes.reset(); changes.changed(at: 10)
        XCTAssertEqual(changes.deadline, 10.5)
    }
    func testMissingBuffersVersusQuietApplicationAndSilentAcceptedAudio() {
        XCTAssertEqual(SourceLiveness.evaluate(attached: true, active: true, lastAccepted: -1, started: 0, now: 5), .stalled)
        XCTAssertEqual(SourceLiveness.evaluate(attached: true, active: false, lastAccepted: -1, started: 0, now: 60), .waiting)
        // Samples containing silence still advance the accepted timestamp.
        XCTAssertEqual(SourceLiveness.evaluate(attached: true, active: true, lastAccepted: 59.9, started: 0, now: 60), .receiving)
        // Stale samples from an earlier engine instance cannot establish recovery.
        XCTAssertEqual(SourceLiveness.evaluate(attached: true, active: true, lastAccepted: 59.9, started: 60, now: 65), .stalled)
        XCTAssertEqual(SourceLiveness.evaluate(attached: false, active: true, lastAccepted: 65, started: 60, now: 65), .detached)
    }
    func testSuccessfulStartWithoutBuffersStillBacksOff() {
        var source = SourceRecovery()
        for (time, delay) in [(0.0, 1.0), (10, 2), (20, 5), (30, 30), (70, 30)] {
            source.started() // Device start returns success, but no usable audio follows.
            source.failed(at: time)
            XCTAssertEqual(source.nextAttempt, time+delay)
            source.failed(at: time+0.1) // Duplicate configuration/disconnect notification.
            XCTAssertEqual(source.nextAttempt, time+delay)
        }
    }
    func testRecoveryRequiresTenStableSecondsAndSourcesStayIndependent() {
        var microphone = SourceRecovery(), computer = SourceRecovery()
        microphone.failed(at: 0); microphone.started()
        microphone.received(at: 1); microphone.received(at: 9)
        XCTAssertEqual(microphone.failures, 1)
        microphone.interrupted(); microphone.received(at: 12); microphone.received(at: 21)
        XCTAssertEqual(microphone.failures, 1)
        microphone.received(at: 22); XCTAssertEqual(microphone.failures, 0)
        computer.failed(at: 30)
        XCTAssertNil(microphone.nextAttempt)
        XCTAssertEqual(computer.nextAttempt, 31)
    }
    func testDeviceReturnGetsPromptAttemptWithoutNotificationStorm() {
        var source = SourceRecovery()
        for time in [0.0, 5, 10, 20] { source.started(); source.failed(at: time) }
        XCTAssertEqual(source.nextAttempt, 50)
        source.returned(at: 21); XCTAssertTrue(source.due(at: 21))
        source.started(); source.failed(at: 21)
        source.returned(at: 21.1); XCTAssertEqual(source.nextAttempt, 51)
    }
    func testRejectedBuffersCannotMakeCaptureHealthy() {
        let ring = mnt_ring_create()!; defer { mnt_ring_destroy(ring) }
        let samples: [Float] = [0, 0]
        samples.withUnsafeBufferPointer { b in
            var pointer = b.baseAddress
            XCTAssertFalse(mnt_ring_push(ring, &pointer, 1, 1, 9000, 48000, 100, false))
            XCTAssertEqual(mnt_ring_last_time(ring), -1)
            XCTAssertEqual(mnt_ring_accepted_frames(ring), 0)
            XCTAssertTrue(mnt_ring_push(ring, &pointer, 1, 1, 2, 48000, 0, false))
        }
        XCTAssertEqual(mnt_ring_accepted_frames(ring), 2)
        XCTAssertEqual(mnt_ring_first_time(ring), 0)
        XCTAssertEqual(mnt_ring_dropped(ring), 1)
        mnt_ring_reset(ring); XCTAssertEqual(mnt_ring_accepted_frames(ring), 0)
    }
    func testEmptyCaptureRejectedAndFilesPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = MeetingSession(folder: root.path, stem: "empty", speech: .init(), echoReduction: false)
        session.duration = 20
        try FileManager.default.createDirectory(at: session.stagingURL, withIntermediateDirectories: true)
        for source in AudioSource.allCases { try Data().write(to: session.stagingURL.appendingPathComponent(source.rawValue+".packets")) }
        XCTAssertThrowsError(try AudioFiles.finalize(session))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.stagingURL.path))
    }
    func testPartialCaptureWarningsAndLegacyCompatibility() throws {
        var session = MeetingSession(folder: "/tmp", stem: "test", speech: .init(), echoReduction: false)
        let legacy = try meetingDecoder.decode(MeetingSession.self, from: meetingEncoder.encode(session))
        XCTAssertNil(legacy.captureDiagnostics); XCTAssertTrue(legacy.captureWarnings.isEmpty)
        session.status = .recorded
        session.captureDiagnostics = .init(microphoneUID: "persistent-uid", microphoneEnabled: true)
        session.captureDiagnostics?.computer.acceptedFrames = 48000
        XCTAssertEqual(session.captureWarnings.count, 1)
        XCTAssertTrue(MarkdownExporter.metadata(session).contains("persistent-uid"))
        XCTAssertTrue(MarkdownExporter.metadata(session).contains("no audio was captured"))
        session.captureDiagnostics?.microphone.expected = false
        XCTAssertTrue(session.captureWarnings.isEmpty)
        session.events.append(.init(time: 1, message: "Disconnected", kind: .gapBegan, source: .computer))
        XCTAssertEqual(session.captureWarnings.count, 1)
    }
}
