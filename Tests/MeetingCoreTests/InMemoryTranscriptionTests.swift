import XCTest
import AVFoundation
@testable import MeetingCore

final class InMemoryTranscriptionTests: XCTestCase {
    private func fixture(duration: Double = 26, silent: Bool = false, echo: Bool = false) async throws -> (MeetingSession, SessionStore) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        var settings = AppSettings(); settings.outputFolder = folder.path; settings.echoReduction = echo
        let store = try SessionStore(root: folder.appendingPathComponent("metadata"))
        var session = try await store.reserve(settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2)!
        let count = Int(duration * 16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            let reference = silent ? Float(0) : Float(sin(Double(index) * 0.13)) * 0.3
            buffer.floatChannelData![1][index] = reference
            buffer.floatChannelData![0][index] = silent ? 0 : reference * 0.6 + Float(sin(Double(index) * 0.21)) * 0.1
        }
        let file = try AVAudioFile(forWriting: session.audioURL, settings: [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        session.duration = duration; session.status = .recorded
        try await store.save(session)
        return (session, store)
    }

    func testMemoryPathPreservesChannelsOffsetsAndPartialChunkWithoutWAV() async throws {
        let (session, store) = try await fixture()
        let provider = MemorySpeech(staging: session.stagingURL)
        let pipeline = MeetingPipeline(speechFactory: { _ in provider })
        let result = try await pipeline.transcribe(session, store: store, progress: { _ in })
        XCTAssertEqual(provider.fileCalls, 0)
        XCTAssertEqual(provider.calls.map(\.offset), [0, 0, 25, 25])
        XCTAssertEqual(provider.calls.map(\.duration), [25, 25, 1, 1])
        XCTAssertEqual(provider.calls.map(\.source), [.microphone, .computer, .microphone, .computer])
        for call in provider.calls {
            XCTAssertEqual(call.rate, 16000)
            let expected = try AudioFiles.samples(session.audioURL, channel: call.source == .microphone ? 0 : 1, start: call.offset, duration: call.duration)
            XCTAssertEqual(call.samples, expected)
        }
        XCTAssertEqual(result.completedChunks.count, 4)
        XCTAssertEqual(result.segments.map(\.start), [0, 0, 25, 25])
        XCTAssertEqual(result.status, .complete)
        XCTAssertTrue(provider.stopped)
    }

    func testEchoReductionOccursBeforeMemoryDelivery() async throws {
        let (session, store) = try await fixture(duration: 1, echo: true)
        var expected = try AudioFiles.samples(session.audioURL, channel: 0, start: 0, duration: 1)
        let computer = try AudioFiles.samples(session.audioURL, channel: 1, start: 0, duration: 1)
        AudioFiles.reduceEcho(microphone: &expected, computer: computer)
        let provider = MemorySpeech(staging: session.stagingURL)
        _ = try await MeetingPipeline(speechFactory: { _ in provider }).transcribe(session, store: store, progress: { _ in })
        XCTAssertEqual(provider.calls.first?.samples, expected)
        XCTAssertEqual(provider.calls.last?.samples, computer)
    }

    func testSilenceIsCheckpointedWithoutInference() async throws {
        let (session, store) = try await fixture(silent: true)
        let provider = MemorySpeech(staging: session.stagingURL)
        let result = try await MeetingPipeline(speechFactory: { _ in provider }).transcribe(session, store: store, progress: { _ in })
        XCTAssertTrue(provider.calls.isEmpty)
        XCTAssertEqual(result.completedChunks.count, 4)
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testFailureResumesOnlyUnfinishedChunksWithoutFileFallback() async throws {
        let (session, store) = try await fixture()
        let failing = MemorySpeech(staging: session.stagingURL); failing.failAt = 2
        do {
            _ = try await MeetingPipeline(speechFactory: { _ in failing }).transcribe(session, store: store, progress: { _ in })
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error.localizedDescription, "fixture failure") }
        XCTAssertEqual(failing.fileCalls, 0)
        XCTAssertTrue(failing.stopped)
        let saved = try await store.load()[0]
        XCTAssertEqual(saved.completedChunks, ["microphone-0"])
        let retry = MemorySpeech(staging: session.stagingURL)
        let result = try await MeetingPipeline(speechFactory: { _ in retry }).transcribe(saved, store: store, progress: { _ in })
        XCTAssertEqual(retry.calls.count, 3)
        XCTAssertEqual(result.segments.count, 4)
        XCTAssertEqual(result.completedChunks.count, 4)
    }

    func testFileProvidersKeepWAVPathAndCleanUpOnSuccessAndFailure() async throws {
        for fail in [false, true] {
            let (session, store) = try await fixture(duration: 1)
            let provider = FileSpeech(); provider.failAt = fail ? 1 : nil
            do {
                _ = try await MeetingPipeline(speechFactory: { _ in provider }).transcribe(session, store: store, progress: { _ in })
                XCTAssertFalse(fail)
            } catch { XCTAssertTrue(fail) }
            XCTAssertGreaterThan(provider.fileCalls, 0)
            XCTAssertTrue(provider.stopped)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: session.stagingURL.path).contains { $0.hasSuffix(".wav") })
        }
    }

    func testCancellationDoesNotCommitInFlightMemoryChunk() async throws {
        let (session, store) = try await fixture(duration: 1)
        let provider = MemorySpeech(staging: session.stagingURL); provider.cancelDuringCall = true
        let task = Task { try await MeetingPipeline(speechFactory: { _ in provider }).transcribe(session, store: store, progress: { _ in }) }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let saved = try await store.load()[0]
        XCTAssertTrue(saved.completedChunks.isEmpty)
        XCTAssertTrue(saved.segments.isEmpty)
        XCTAssertTrue(provider.stopped)
    }

    func testParakeetCapabilityAndSampleRateValidation() async throws {
        var settings = SpeechSettings(); settings.engine = .parakeet
        let provider = try XCTUnwrap(try SpeechProviders.make(settings) as? any InMemoryTranscriptionProvider)
        do {
            _ = try await provider.transcribe(samples: [0], sampleRate: 48000, source: .microphone, offset: 0, duration: 1)
            XCTFail("Invalid sample rate must fail before inference")
        } catch { XCTAssertTrue(error.localizedDescription.contains("16 kHz")) }
        for engine in [SpeechEngine.whisper, .apple, .remote] {
            settings.engine = engine
            XCTAssertFalse(try SpeechProviders.make(settings) is any InMemoryTranscriptionProvider)
        }
    }
}

private class FileSpeech: TranscriptionProvider, @unchecked Sendable {
    var fileCalls = 0
    var failAt: Int?
    var stopped = false
    func prepare() async throws {}
    func transcribe(_ url: URL, source: AudioSource, offset: Double, duration: Double) async throws -> [TranscriptSegment] {
        fileCalls += 1
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "wav")
        if fileCalls == failAt { throw MeetingError.message("fixture failure") }
        return [.init(source: source, start: offset, end: offset + duration, text: "File")]
    }
    func cancel() {}
    func shutdown() async { stopped = true }
}

private final class MemorySpeech: FileSpeech, InMemoryTranscriptionProvider, @unchecked Sendable {
    struct Call { let samples: [Float]; let rate: Double; let source: AudioSource; let offset: Double; let duration: Double }
    var calls: [Call] = []
    var cancelDuringCall = false
    let staging: URL
    init(staging: URL) { self.staging = staging }
    func transcribe(samples: [Float], sampleRate: Double, source: AudioSource, offset: Double, duration: Double) async throws -> [TranscriptSegment] {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: staging.path).contains { $0.hasSuffix(".wav") })
        calls.append(.init(samples: samples, rate: sampleRate, source: source, offset: offset, duration: duration))
        if calls.count == failAt { throw MeetingError.message("fixture failure") }
        if cancelDuringCall { withUnsafeCurrentTask { $0?.cancel() } }
        return [.init(source: source, start: offset, end: offset + duration, text: "Memory")]
    }
}
