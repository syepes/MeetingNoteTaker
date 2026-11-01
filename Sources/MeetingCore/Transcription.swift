import Foundation
import AVFoundation
import Speech
import FluidAudio

public protocol TranscriptionProvider: AnyObject {
    func prepare() async throws
    func transcribe(_ url: URL, source: AudioSource, offset: Double, duration: Double) async throws -> [TranscriptSegment]
    func cancel()
    func shutdown() async
}
/// Optional fast path for prepared mono, 16 kHz floating-point audio.
public protocol InMemoryTranscriptionProvider: TranscriptionProvider {
    func transcribe(samples: [Float], sampleRate: Double, source: AudioSource, offset: Double, duration: Double) async throws -> [TranscriptSegment]
}
public extension TranscriptionProvider { func shutdown() async { cancel() } }
public enum SpeechProviders {
    public static func make(_ settings: SpeechSettings) throws -> any TranscriptionProvider {
        switch settings.engine {
        case .whisper: return WhisperProvider(settings)
        case .parakeet: return ParakeetProvider(settings)
        case .apple: return AppleSpeechProvider(settings)
        case .remote: return RemoteSpeechProvider(settings)
        }
    }
}
final class WhisperProvider: TranscriptionProvider {
    let settings: SpeechSettings
    private var worker: WhisperWorker?
    private var restarted = false
    private let workerFactory: (String) -> WhisperWorker
    init(_ settings: SpeechSettings, workerFactory: @escaping (String) -> WhisperWorker = { WhisperWorker(model: $0) }) { self.settings = settings; self.workerFactory = workerFactory }
    func prepare() async throws {
        try ModelManager.validateFile(URL(fileURLWithPath: settings.modelPath), kind: .whisper)
        try await startWorker()
    }
    private func startWorker() async throws {
        let next = workerFactory(settings.modelPath); worker = next
        try await next.start()
    }
    func transcribe(_ url: URL, source: AudioSource, offset: Double, duration: Double) async throws -> [TranscriptSegment] {
        let language = ModelManager.whisperIsMultilingual(settings.modelPath) ? settings.language : "en"
        let data: Data
        do { data = try await worker!.transcribe(url, language: language) }
        catch {
            await worker?.shutdown()
            try Task.checkCancellation()
            // A single retry for a crashed process; protocol, timeout and model errors
            // stay visible and do not cause an unbounded restart loop.
            guard !restarted, error.localizedDescription.contains("exited unexpectedly") else { throw error }
            restarted = true; try await startWorker()
            data = try await worker!.transcribe(url, language: language)
        }
        struct Response: Decodable { struct Part: Decodable { var from: Double; var to: Double; var text: String }; var segments: [Part] }
        return try JSONDecoder().decode(Response.self, from: data).segments.compactMap { part in
            let text = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !["[BLANK_AUDIO]", "[MUSIC]"].contains(text) else { return nil }
            return .init(source: source, start: offset + part.from/1000, end: offset + min(duration,part.to/1000), text: text)
        }
    }
    func cancel() { worker?.cancel() }
    func shutdown() async { await worker?.shutdown(); worker = nil }
}
final class ParakeetProvider: InMemoryTranscriptionProvider {
    let settings: SpeechSettings; var manager: AsrManager?
    init(_ settings: SpeechSettings) { self.settings = settings }
    func prepare() async throws {
        guard !settings.modelPath.isEmpty else { throw MeetingError.message("This job has no Parakeet model selected. Choose a model in Settings, then use Retry with current model for this meeting.") }
        let actualVersion = try ModelManager.parakeetVersion(at: URL(fileURLWithPath: settings.modelPath))
        guard actualVersion == settings.parakeetVersion else { throw MeetingError.message("This job expects Parakeet \(settings.parakeetVersion), but the selected folder contains \(actualVersion). Select the model again in Settings and use Retry with current model.") }
        let version = try ModelManager.parakeetRuntimeVersion(actualVersion)
        // loadLocal deliberately never repairs by downloading: local mode stays offline.
        let models = try AsrModels.loadLocal(from: URL(fileURLWithPath: settings.modelPath), version: version)
        let manager = AsrManager(config: .default); try await manager.loadModels(models); self.manager = manager
    }
    func transcribe(_ url: URL, source: AudioSource, offset: Double, duration: Double) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let samples = try AudioFiles.samples(url, channel: 0, start: 0, duration: duration)
        return try await transcribe(samples: samples, sampleRate: 16000, source: source, offset: offset, duration: duration)
    }
    func transcribe(samples: [Float], sampleRate: Double, source: AudioSource, offset: Double, duration: Double) async throws -> [TranscriptSegment] {
        guard sampleRate == 16000 else { throw MeetingError.message("Parakeet requires mono audio at 16 kHz.") }
        guard let manager else { throw MeetingError.message("Parakeet is not loaded.") }
        try Task.checkCancellation()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        try Task.checkCancellation()
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if let timings = result.tokenTimings, let first = timings.first, let last = timings.last {
            return [.init(source: source, start: offset+max(0,first.startTime), end: offset+min(duration,last.endTime), text: result.text)]
        }
        return [.init(source: source, start: offset, end: offset+duration, text: result.text, approximate: true)]
    }
    func cancel() {}
    func shutdown() async { manager = nil }
}
final class AppleSpeechProvider: TranscriptionProvider {
    let settings: SpeechSettings; var locale: Locale?; var analyzer: SpeechAnalyzer?
    init(_ settings: SpeechSettings) { self.settings = settings }
    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else { throw MeetingError.message("Apple Speech is unavailable on this Mac.") }
        let language = settings.appleLocale ?? settings.language
        guard language != "auto" else { throw MeetingError.message("Choose an explicit English or French locale for Apple Speech.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { throw MeetingError.message("Apple Speech does not support the selected locale.") }
        guard await SpeechTranscriber.installedLocales.contains(locale) else { throw MeetingError.message("Install the Apple Speech language assets in Settings before transcribing offline.") }
        self.locale = locale
    }
    func transcribe(_ url: URL, source: AudioSource, offset: Double, duration: Double) async throws -> [TranscriptSegment] {
        guard let locale else { throw MeetingError.message("Apple Speech is not prepared.") }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber]); self.analyzer = analyzer
        defer { self.analyzer = nil }
        return try await withTaskCancellationHandler {
            async let results: [TranscriptSegment] = collect(transcriber, source: source, offset: offset)
            let file = try AVAudioFile(forReading: url)
            if let end = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: end) }
            else { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            return try await results
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
    }
    private func collect(_ transcriber: SpeechTranscriber, source: AudioSource, offset: Double) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(.init(source: source, start: offset+result.range.start.seconds, end: offset+CMTimeRangeGetEnd(result.range).seconds, text: text)) }
        }
        return segments
    }
    func cancel() { if let analyzer { Task { await analyzer.cancelAndFinishNow() } } }
    func shutdown() async { if let analyzer { await analyzer.cancelAndFinishNow() }; analyzer = nil }
}
final class RemoteSpeechProvider: TranscriptionProvider {
    let settings: SpeechSettings
    let authorization: ServerAuthorization
    let httpSession: URLSession
    init(_ settings: SpeechSettings, session: URLSession = .shared, authorization: ServerAuthorization? = nil) {
        self.settings = settings; httpSession = session
        self.authorization = authorization ?? ServerAuthorization(endpoint: settings.endpoint, configuration: settings.authentication,
            apiKey: KeychainStore.get(RemoteSpeechConfiguration.credentialAccount(endpoint: settings.endpoint)),
            clientSecret: KeychainStore.get((settings.authentication ?? .init()).secretAccount(purpose: "speech", endpoint: settings.endpoint)))
    }
    func prepare() async throws { try await authorization.validate(); _ = try HTTPClient.endpoint(settings.endpoint, path: "audio/transcriptions"); guard !settings.remoteModel.isEmpty else { throw MeetingError.message("Set a remote transcription model.") } }
    func transcribe(_ url: URL, source: AudioSource, offset: Double, duration: Double) async throws -> [TranscriptSegment] {
        let boundary = UUID().uuidString; var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        var fields = ["model": settings.remoteModel, "response_format": settings.detailedTimestamps ? "verbose_json" : "json"]
        let language = settings.remoteLanguage ?? settings.language
        if language != "auto" { fields["language"] = language }
        if settings.detailedTimestamps { fields["timestamp_granularities[]"] = "segment" }
        for (key,value) in fields { append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n") }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: url)); append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: try HTTPClient.endpoint(settings.endpoint, path: "audio/transcriptions")); request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        struct Response: Decodable { struct Part: Decodable { var start: Double; var end: Double; var text: String }; var text: String; var segments: [Part]? }
        let result = try JSONDecoder().decode(Response.self, from: await authorization.send(request, session: httpSession))
        if let parts = result.segments, !parts.isEmpty {
            return parts.map { .init(source: source, start: offset+max(0,$0.start), end: offset+min(duration,$0.end), text: $0.text) }
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.init(source: source, start: offset, end: offset+duration, text: result.text, approximate: true)]
    }
    func cancel() {}
}
