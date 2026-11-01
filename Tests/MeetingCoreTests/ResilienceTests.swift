import XCTest
import AVFoundation
import AudioDSP
@testable import MeetingCore

final class ResilienceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mnt-resilience-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func session() throws -> MeetingSession {
        let folder = try directory()
        let session = MeetingSession(folder: folder.path, stem: "test", speech: .init(), echoReduction: false)
        try FileManager.default.createDirectory(at: session.stagingURL, withIntermediateDirectories: true)
        return session
    }
    func testJournalReplaysCompleteLinesAndIgnoresTruncatedTail() throws {
        let folder = try directory(), journal = try CaptureEventJournal(directory: folder)
        try journal.append(.init(time: 1, message: "Paused", kind: .paused), synchronize: true)
        try journal.append(.init(time: 2, message: "", kind: .heartbeat)); try journal.close()
        let file = try FileHandle(forWritingTo: folder.appendingPathComponent("capture-events.jsonl"))
        try file.seekToEnd(); try file.write(contentsOf: Data("{\"time\":3".utf8)); try file.close()
        let events = try CaptureEventJournal.replay(folder)
        XCTAssertEqual(events.count, 2); XCTAssertEqual(events[0].kind, .paused)
    }
    func testOldSettingsAndSessionDecodeWithoutNewFields() throws {
        let s = try session()
        var object = try JSONSerialization.jsonObject(with: meetingEncoder.encode(s)) as! [String: Any]
        for field in ["captureTarget", "captureStartedAt", "analysisCheckpoints", "processingMetrics"] { object.removeValue(forKey: field) }
        let restored = try meetingDecoder.decode(MeetingSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.captureTarget); XCTAssertNil(restored.analysisCheckpoints)
        let event = try JSONDecoder().decode(CaptureEvent.self, from: Data("{\"time\":0,\"message\":\"old\"}".utf8))
        XCTAssertNil(event.kind)
        let settings = try meetingDecoder.decode(AppSettings.self, from: meetingEncoder.encode(AppSettings()))
        XCTAssertNil(settings.captureTarget)
    }
    func testSilentPausedSessionKeepsStopDuration() throws {
        var s = try session(); s.duration = 0.3
        s.events = [.init(time: 0, message: "Pause", kind: .paused)]
        for source in AudioSource.allCases { FileManager.default.createFile(atPath: s.stagingURL.appendingPathComponent(source.rawValue+".packets").path, contents: Data()) }
        let result = try AudioFiles.finalize(s)
        XCTAssertEqual(result.duration, 0.3, accuracy: 1/48000)
        let file = try AVAudioFile(forReading: s.audioURL)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(file.length, 14400)
    }
    func testPauseMasksPacketsCrossingBothBoundaries() throws {
        var s = try session(); s.duration = 0.1
        s.events = [.init(time: 0.025, message: "Pause", kind: .paused), .init(time: 0.075, message: "Resume", kind: .resumed)]
        var packet = Data()
        var time = 0.0, rate = 48000.0, count: UInt32 = 4800
        withUnsafeBytes(of: &time) { packet.append(contentsOf: $0) }; withUnsafeBytes(of: &rate) { packet.append(contentsOf: $0) }; withUnsafeBytes(of: &count) { packet.append(contentsOf: $0) }
        let samples = [Float](repeating: 0.5, count: 4800); samples.withUnsafeBytes { packet.append(contentsOf: $0) }
        for source in AudioSource.allCases { try packet.write(to: s.stagingURL.appendingPathComponent(source.rawValue+".packets")) }
        _ = try AudioFiles.finalize(s)
        let input = try AVAudioFile(forReading: s.audioURL)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4800)!
        try input.read(into: buffer)
        for channel in 0..<2 {
            XCTAssertEqual(buffer.floatChannelData![channel][100], 0.5, accuracy: 0.001)
            XCTAssertEqual(buffer.floatChannelData![channel][2400], 0)
            XCTAssertEqual(buffer.floatChannelData![channel][4000], 0.5, accuracy: 0.001)
        }
    }
    func testRingPauseKeepsMicrophoneMuteIndependent() {
        let ring = mnt_ring_create()!; defer { mnt_ring_destroy(ring) }
        let samples: [Float] = [1,1,1,1]
        mnt_ring_pause(ring, 0.25); mnt_ring_resume(ring, 0.75)
        samples.withUnsafeBufferPointer { buffer in
            var base = buffer.baseAddress
            _ = withUnsafePointer(to: &base) { mnt_ring_push(ring, $0, 1, 1, 4, 4, 0, false) }
        }
        var packet = MNTPacket(); XCTAssertTrue(mnt_ring_pop(ring, &packet))
        withUnsafePointer(to: &packet) { p in XCTAssertEqual(Array(UnsafeBufferPointer(start: mnt_packet_samples(p), count: 4)), [1,0,0,1]) }
        XCTAssertFalse(mnt_ring_is_muted(ring)); XCTAssertEqual(mnt_ring_last_time(ring), 1)
    }
    func testRecoveryBackoffAndStorageThresholds() {
        XCTAssertEqual((0..<5).map(CaptureRecoveryPolicy.delay), [1,2,5,30,30])
        XCTAssertNil(CaptureRecoveryPolicy.storageState(bytes: 2*1024*1024*1024))
        XCTAssertTrue(CaptureRecoveryPolicy.storageState(bytes: 500*1024*1024)!.contains("Low"))
        XCTAssertTrue(CaptureRecoveryPolicy.storageState(bytes: 127*1024*1024)!.contains("stopping"))
    }
    @MainActor func testStaleJobCannotOwnNewRecording() async {
        let coordinator = ProcessingCoordinator(), old = coordinator.begin()
        let current = coordinator.begin()
        XCTAssertFalse(coordinator.owns(old)); XCTAssertTrue(coordinator.owns(current))
        var cleaned = false
        coordinator.task = Task { do { try await Task.sleep(for: .seconds(60)) } catch {}; cleaned = true }
        await coordinator.cancelAndWait(); XCTAssertTrue(cleaned)
    }
    func testNativeCancellationWaitsForForcedExit() async throws {
        let root = try directory(), process = NativeProcessSupervisor()
        let task = Task { try await process.run(URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready',flush=True); time.sleep(60)"], log: root.appendingPathComponent("process.log")) }
        for _ in 0..<100 {
            if (try? String(contentsOf: root.appendingPathComponent("process.log"), encoding: .utf8))?.contains("ready") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let start = Date(); task.cancel(); await process.shutdown(); _ = try? await task.value
        XCTAssertTrue(process.hasExited); XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testContextOverflowClassificationDoesNotExposeResponseBody() {
        let error = HTTPFailure(status: 400, data: Data("secret transcript context_length_exceeded".utf8))
        XCTAssertTrue(error.contextOverflow); XCTAssertFalse(error.localizedDescription.contains("secret"))
        XCTAssertFalse(HTTPFailure(status: 401, data: Data("context_length_exceeded".utf8)).contextOverflow)
    }
    func testFullRequestIncludesSchemaAndGenerationOptions() async throws {
        var settings = AnalysisSettings(); settings.engine = .ollama; settings.model = "fixture"
        let provider = ChatAnalysisProvider(settings); provider.configureEvidence(["seg-é"])
        let body = provider.requestBody(system: "prompt", input: "input")
        let encoded = try JSONSerialization.data(withJSONObject: body)
        let count = try await provider.countTokens(system: "prompt", input: "input")
        XCTAssertEqual(count.accuracy, .conservative); XCTAssertGreaterThanOrEqual(count.tokens, encoded.count)
        XCTAssertNotNil(body["format"]); XCTAssertNotNil(body["options"])
    }
    func testUnicodeUnitsPreserveEveryCharacterAndEvidenceID() {
        let text = String(repeating: "Échéance vendredi 👨‍👩‍👧‍👦 — français 日本語. ", count: 150)
        let units = AnalysisRunner.units([.init(id: "original", source: .microphone, start: 0, end: 10, text: text)])
        XCTAssertTrue(units.allSatisfy { $0.id == "original" })
        let restored = units.map { String($0.line.dropFirst($0.line.range(of: ": ")!.upperBound.utf16Offset(in: $0.line)).dropLast()) }.joined()
        XCTAssertEqual(restored, text)
    }
    final class CounterProvider: AnalysisProvider {
        var inputs: [String] = [], evidence: Set<String> = [], overflow = 0, malformed = false
        func prepare() async throws {}
        func cancel() {}
        func configureEvidence(_ ids: Set<String>) { evidence = ids }
        func countTokens(system: String, input: String) async throws -> InputTokenCount { .init(tokens: (system.utf8.count+input.utf8.count)/4 + evidence.count*5 + 100, accuracy: .exactLocal) }
        func generate(system: String, input: String) async throws -> String {
            inputs.append(input)
            if overflow > 0 { overflow -= 1; throw HTTPFailure(status: 400, data: Data("context_length_exceeded".utf8)) }
            return malformed ? "{broken" : "{\"items\":[]}"
        }
    }
    func testOverflowShrinksPendingChunkAndResumesCheckpoint() async throws {
        let provider = CounterProvider(); provider.overflow = 1
        let s = try session(); var settings = AnalysisSettings(); settings.contextTokens = 2048; settings.outputTokens = 256
        let definition = AnalysisDefinition(kind: .decisions)
        let segments = [TranscriptSegment(id: "a", source: .computer, start: 0, end: 100, text: String(repeating: "Requirement confirmed. ", count: 800))]
        var checkpoints: [AnalysisCheckpoint] = []
        _ = try await AnalysisRunner.run(definition: definition, settings: settings, session: s, segments: segments, provider: provider, saveCheckpoint: { checkpoints.append($0) })
        XCTAssertGreaterThan(provider.inputs.count, 2); XCTAssertLessThan(provider.inputs[1].count, provider.inputs[0].count)
        XCTAssertEqual(checkpoints.last?.consumedUnits, AnalysisRunner.units(segments).count)
        let resumed = CounterProvider()
        _ = try await AnalysisRunner.run(definition: definition, settings: settings, session: s, segments: segments, provider: resumed, checkpoint: checkpoints.last)
        XCTAssertTrue(resumed.inputs.isEmpty)
        var changed = definition; changed.revisions.append(.init(text: "Changed prompt"))
        XCTAssertNotEqual(try AnalysisRunner.checkpointIdentity(definition: changed, settings: settings, segments: segments), checkpoints.last?.identity)
    }
    func testMalformedOutputNeverAdvancesCheckpoint() async throws {
        let provider = CounterProvider(); provider.malformed = true
        var checkpoints = 0
        do {
            _ = try await AnalysisRunner.run(definition: .init(kind: .summary), settings: .init(), session: session(), segments: [.init(id: "a", source: .microphone, start: 0, end: 1, text: "A fact")], provider: provider, saveCheckpoint: { _ in checkpoints += 1 })
            XCTFail("Malformed output must fail")
        } catch { XCTAssertEqual(checkpoints, 0) }
    }
}

extension ResilienceTests {
    private func workerScript(_ body: String) throws -> URL {
        let script = try directory().appendingPathComponent("worker")
        try ("#!/usr/bin/python3\nimport sys,json,time\n"+body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
    func testWorkerRejectsMismatchedResponseAndCleansUp() async throws {
        let script = try workerScript("print('{\"version\":1,\"ready\":true}',flush=True)\nfor line in sys.stdin:\n print('{\"version\":1,\"id\":\"wrong\",\"segments\":[]}',flush=True)\n")
        let worker = WhisperWorker(model: "fixture", executable: script, startupTimeout: 2, requestTimeout: 2)
        try await worker.start()
        do { _ = try await worker.transcribe(URL(fileURLWithPath: "/tmp/fixture.wav"), language: "fr"); XCTFail("Must reject wrong request ID") }
        catch { XCTAssertTrue(error.localizedDescription.contains("match")) }
        await worker.shutdown()
    }
    func testWorkerStartupAndRequestTimeoutsAreBounded() async throws {
        let silent = try workerScript("time.sleep(60)\n")
        let startup = WhisperWorker(model: "fixture", executable: silent, startupTimeout: 0.2)
        do { try await startup.start(); XCTFail("Must time out") } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        let script = try workerScript("print('{\"version\":1,\"ready\":true}',flush=True)\nfor line in sys.stdin: time.sleep(60)\n")
        let worker = WhisperWorker(model: "fixture", executable: script, requestTimeout: 0.2)
        try await worker.start()
        do { _ = try await worker.transcribe(URL(fileURLWithPath: "/tmp/fixture.wav"), language: "auto"); XCTFail("Must time out") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        await worker.shutdown()
    }
    func testWorkerCancellationWaitsForCleanup() async throws {
        let script = try workerScript("print('{\"version\":1,\"ready\":true}',flush=True)\nfor line in sys.stdin: time.sleep(60)\n")
        let worker = WhisperWorker(model: "fixture", executable: script)
        try await worker.start()
        let task = Task { try await worker.transcribe(URL(fileURLWithPath: "/tmp/fixture.wav"), language: "en") }
        try await Task.sleep(for: .milliseconds(100)); let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch {}
        await worker.shutdown(); XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testTwoHourRingSimulationHasStableTimestampsAndBoundedStorage() {
        let ring = mnt_ring_create()!; defer { mnt_ring_destroy(ring) }
        let count = 1024, rate = 48000.0, total = Int(7200*rate)/count
        let samples = [Float](repeating: 0.2, count: count)
        var packet = MNTPacket()
        samples.withUnsafeBufferPointer { buffer in
            var base = buffer.baseAddress
            withUnsafePointer(to: &base) { channels in
                for index in 0..<total {
                    XCTAssertTrue(mnt_ring_push(ring, channels, 1, 1, UInt32(count), rate, Double(index*count)/rate, false))
                    XCTAssertTrue(mnt_ring_pop(ring, &packet))
                    if index % 10000 == 0 { XCTAssertEqual(packet.time, Double(index*count)/rate, accuracy: 0.000001) }
                }
            }
        }
        XCTAssertEqual(mnt_ring_dropped(ring), 0)
        XCTAssertEqual(mnt_ring_last_time(ring), 7200, accuracy: 0.03)
    }
    func testFinalizationCancellationLeavesRecoverableChunksAndNoAudioCommit() async throws {
        var s = try session(); s.duration = 7200
        for source in AudioSource.allCases { FileManager.default.createFile(atPath: s.stagingURL.appendingPathComponent(source.rawValue+".packets").path, contents: Data()) }
        let snapshot = s
        let task = Task.detached { try AudioFiles.finalize(snapshot) }; task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.stagingURL.appendingPathComponent("microphone.packets").path))
    }
}

private final class CounterURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [[String: Any]] = []
    static var supported = true
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "counter-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
        }
        let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        Self.lock.lock(); Self.requests.append(object); let supported = Self.supported; Self.lock.unlock()
        let counting = request.url!.path.hasSuffix("input_tokens")
        let status = counting && !supported ? 404 : 200
        let text = counting ? "{\"input_tokens\":123}" : "{\"choices\":[{\"message\":{\"content\":\"{\\\"items\\\":[]}\"},\"finish_reason\":\"stop\"}]}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension ResilienceTests {
    func testCompatibleCounterProbesOnceAndCountsExactGenerationBody() async throws {
        CounterURLProtocol.requests = []; CounterURLProtocol.supported = true
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CounterURLProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        var settings = AnalysisSettings(); settings.engine = .compatible; settings.endpoint = "https://counter-fixture.invalid/v1"; settings.model = "fixture"; settings.structuredOutput = true
        let provider = ChatAnalysisProvider(settings, session: http)
        provider.configureEvidence(["français"])
        let first = try await provider.countTokens(system: "System", input: "French transcript")
        let cached = try await provider.countTokens(system: "System", input: "French transcript")
        _ = try await provider.generate(system: "System", input: "French transcript")
        XCTAssertEqual(first.tokens, 123); XCTAssertEqual(cached.accuracy, .providerReported)
        XCTAssertEqual(CounterURLProtocol.requests.count, 3)
        let objects = CounterURLProtocol.requests
        XCTAssertFalse(String(describing: objects[0]).contains("French transcript"))
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: objects[1], options: .sortedKeys), try JSONSerialization.data(withJSONObject: objects[2], options: .sortedKeys))
    }
    func testCompatibleCounterFallsBackWithoutRepeatedProbes() async throws {
        CounterURLProtocol.requests = []; CounterURLProtocol.supported = false
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CounterURLProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        var settings = AnalysisSettings(); settings.engine = .compatible; settings.endpoint = "https://counter-fixture.invalid/v1"; settings.model = "fixture"
        let provider = ChatAnalysisProvider(settings, session: http)
        let one = try await provider.countTokens(system: "System", input: "one")
        let two = try await provider.countTokens(system: "System", input: "two")
        XCTAssertEqual(one.accuracy, .conservative); XCTAssertEqual(two.accuracy, .conservative)
        XCTAssertEqual(CounterURLProtocol.requests.count, 1)
    }
    func testRepeatedCancellationSendsOnlyOneTerminationSignal() async throws {
        let root = try directory(), process = NativeProcessSupervisor()
        let script = "import signal,time,sys\ndef finish(*args):\n print('term',flush=True); time.sleep(0.3); sys.exit(0)\nsignal.signal(signal.SIGTERM,finish)\nprint('ready',flush=True)\ntime.sleep(60)"
        let log = root.appendingPathComponent("process.log")
        let task = Task { try await process.run(URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], log: log) }
        for _ in 0..<100 {
            if (try? String(contentsOf: log, encoding: .utf8))?.contains("ready") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel(); process.terminate(); await process.shutdown(); _ = try? await task.value
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).components(separatedBy: "term").count-1, 1)
    }
}

extension ResilienceTests {
    func testWhisperRestartsOnceAndNeverCommitsFailedChunk() async throws {
        let model = try directory().appendingPathComponent("model.bin")
        var magic: UInt32 = 0x67676d6c; try withUnsafeBytes(of: &magic) { Data($0) }.write(to: model)
        let crash = try workerScript("print('{\"version\":1,\"ready\":true}',flush=True)\nsys.stdin.readline()\nsys.exit(7)\n")
        let valid = try workerScript("print('{\"version\":1,\"ready\":true}',flush=True)\nfor line in sys.stdin:\n r=json.loads(line); print(json.dumps({'version':1,'id':r['id'],'segments':[{'from':0,'to':100,'text':'Bonjour'}]}),flush=True)\n")
        var settings = SpeechSettings(); settings.modelPath = model.path
        var launches = 0
        let provider = WhisperProvider(settings, workerFactory: { path in
            launches += 1; return WhisperWorker(model: path, executable: launches == 1 ? crash : valid, startupTimeout: 2, requestTimeout: 2)
        })
        try await provider.prepare()
        let result = try await provider.transcribe(URL(fileURLWithPath: "/tmp/fixture.wav"), source: .computer, offset: 25, duration: 1)
        XCTAssertEqual(launches, 2); XCTAssertEqual(result.map(\.text), ["Bonjour"]); XCTAssertEqual(result.first?.start, 25)
        await provider.shutdown()
        launches = 0
        let failing = WhisperProvider(settings, workerFactory: { path in launches += 1; return WhisperWorker(model: path, executable: crash, startupTimeout: 2, requestTimeout: 2) })
        try await failing.prepare()
        do { _ = try await failing.transcribe(URL(fileURLWithPath: "/tmp/fixture.wav"), source: .microphone, offset: 0, duration: 1); XCTFail("A second crash must fail the job") } catch {}
        await failing.shutdown(); XCTAssertEqual(launches, 2)
    }
    func testRingOverrunReportsLossWithoutGrowingStorage() {
        let ring = mnt_ring_create()!; defer { mnt_ring_destroy(ring) }
        let samples: [Float] = [0.25]
        samples.withUnsafeBufferPointer { buffer in
            var base = buffer.baseAddress
            withUnsafePointer(to: &base) { channels in
                for i in 0..<200 { _ = mnt_ring_push(ring, channels, 1, 1, 1, 48000, Double(i)/48000, false) }
            }
        }
        XCTAssertEqual(mnt_ring_dropped(ring), 73)
        var packet = MNTPacket(), popped = 0
        while mnt_ring_pop(ring, &packet) { popped += 1 }
        XCTAssertEqual(popped, 127)
        mnt_ring_reset(ring); XCTAssertEqual(mnt_ring_dropped(ring), 0); XCTAssertEqual(mnt_ring_last_time(ring), -1)
    }
}
