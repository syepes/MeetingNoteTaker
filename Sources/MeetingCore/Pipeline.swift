import Foundation

/// An automatic resume must keep its original settings and checkpoints. An explicit
/// restart takes a new settings snapshot and cannot mix chunks from different models.
public enum TranscriptionAttempt: Sendable {
    case resume
    case restart(settings: SpeechSettings, echoReduction: Bool)

    public func prepare(_ original: MeetingSession) -> MeetingSession {
        var session = original
        if case .restart(let settings, let echoReduction) = self {
            session.speech = settings; session.echoReduction = echoReduction
            session.segments = []; session.completedChunks = []; session.error = nil
        }
        return session
    }
}

public actor MeetingPipeline {
    private var speechProvider: (any TranscriptionProvider)?
    private var analysisProvider: (any AnalysisProvider)?
    private let analysisFactory: @Sendable (AnalysisSettings) -> any AnalysisProvider
    private let speechFactory: @Sendable (SpeechSettings) throws -> any TranscriptionProvider
    public init(speechFactory: @escaping @Sendable (SpeechSettings) throws -> any TranscriptionProvider = { try SpeechProviders.make($0) }, analysisFactory: @escaping @Sendable (AnalysisSettings) -> any AnalysisProvider = { ChatAnalysisProvider($0) }) { self.analysisFactory = analysisFactory; self.speechFactory = speechFactory }
    public func cancel() { speechProvider?.cancel(); analysisProvider?.cancel() }
    public func finalize(_ original: MeetingSession, store: SessionStore) async throws -> MeetingSession {
        guard original.deletionRequestedAt == nil else { throw MeetingError.message("This meeting is pending deletion.") }
        var session = original
        let journal = try CaptureEventJournal.replay(session.stagingURL)
        if !journal.isEmpty {
            func key(_ event: CaptureEvent) -> String { "\(event.time)|\(event.kind?.rawValue ?? "")|\(event.source?.rawValue ?? "")|\(event.message)" }
            let recorded = Set(journal.map(key))
            session.events = (journal + session.events.filter { !recorded.contains(key($0)) }).sorted { $0.time < $1.time }
            session.duration = max(session.duration, journal.map(\.time).max() ?? 0)
        }
        let snapshot = session
        let task = Task.detached(priority: .utility) { try AudioFiles.finalize(snapshot) }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        session.duration = result.duration; session.audioFingerprint = result.fingerprint; session.status = .recorded
        try await store.save(session); try MarkdownExporter.updateMetadata(session); return session
    }
    public func transcribe(_ original: MeetingSession, store: SessionStore, attempt: TranscriptionAttempt = .resume, progress: @escaping @Sendable (String) async -> Void) async throws -> MeetingSession {
        guard original.deletionRequestedAt == nil else { throw MeetingError.message("This meeting is pending deletion.") }
        var session = attempt.prepare(original)
        guard !session.audioDeleted else { throw MeetingError.message("The audio has been deleted. You can still regenerate analysis from Markdown.") }
        session.status = .transcribing; session.error = nil; try await store.save(session)
        let provider = try speechFactory(session.speech); speechProvider = provider
        let started = Date(), jobID = UUID()
        let previousCompleted = session.completedChunks.count
        do {
            await progress("Loading \(session.speech.engine.title)…"); try await provider.prepare()
            let loadSeconds = Date().timeIntervalSince(started)
            let chunks = Int(ceil(session.duration/25))
            for index in 0..<chunks {
                try Task.checkCancellation()
                let offset = Double(index)*25; let duration = min(25,session.duration-offset)
                let computer = try AudioFiles.samples(session.audioURL, channel: 1, start: offset, duration: duration)
                for source in AudioSource.allCases {
                    let key = "\(source.rawValue)-\(index)"
                    if session.completedChunks.contains(key) { continue }
                    try Task.checkCancellation(); await progress("\(source.label) · \(index+1)/\(chunks)")
                    var samples = source == .computer ? computer : try AudioFiles.samples(session.audioURL, channel: 0, start: offset, duration: duration)
                    if source == .microphone && session.echoReduction { AudioFiles.reduceEcho(microphone: &samples, computer: computer) }
                    if AudioFiles.containsSpeechEnergy(samples) {
                        let segments: [TranscriptSegment]
                        if let memoryProvider = provider as? any InMemoryTranscriptionProvider {
                            segments = try await memoryProvider.transcribe(samples: samples, sampleRate: 16000, source: source, offset: offset, duration: duration)
                        } else {
                            let url = session.stagingURL.appendingPathComponent(key + ".wav")
                            try FileManager.default.createDirectory(at: session.stagingURL, withIntermediateDirectories: true)
                            defer { try? FileManager.default.removeItem(at: url) }
                            try AudioFiles.writeWAV(samples, to: url)
                            segments = try await provider.transcribe(url, source: source, offset: offset, duration: duration)
                        }
                        try Task.checkCancellation()
                        guard segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= offset && $0.end >= $0.start && $0.end <= offset+duration+0.1 }) else { throw MeetingError.message("The transcription engine returned invalid timestamps.") }
                        session.segments += segments
                    }
                    session.completedChunks.append(key)
                    let completed = session.completedChunks.count
                    let metric = ProcessingProgress(jobID: jobID, stage: "transcription", completed: completed-previousCompleted, total: chunks*2-previousCompleted, elapsed: Date().timeIntervalSince(started)-loadSeconds, modelLoadSeconds: loadSeconds)
                    if let eta = metric.estimatedRemaining { await progress("Transcription · \(completed)/\(chunks*2) · about \(Int(eta))s left") }
                    session.processingMetrics = [metric]
                    try await store.save(session)
                }
            }
            try Task.checkCancellation()
            session.segments.sort { $0.start < $1.start }; session.status = .complete
            try MarkdownExporter.exportTranscript(session, previous: original.firstSuccessfulExport == nil ? nil : original)
            session.firstSuccessfulExport = original.firstSuccessfulExport ?? Date(); try await store.save(session)
            await provider.shutdown(); speechProvider = nil
            return session
        } catch {
            await provider.shutdown(); speechProvider = nil
            session.status = Task.isCancelled ? .recorded : .failed; session.error = Task.isCancelled ? "Processing paused." : error.localizedDescription
            try? await store.save(session); throw error
        }
    }
    public func analyze(_ original: MeetingSession, settings: AnalysisSettings, definitions: [AnalysisDefinition], store: SessionStore, preview: Bool = false, progress: @escaping @Sendable (String) async -> Void) async throws -> (MeetingSession, [AnalysisResult]) {
        guard original.deletionRequestedAt == nil else { throw MeetingError.message("This meeting is pending deletion.") }
        var session = original
        let segments = try MarkdownExporter.readTranscript(session.markdownURL)
        let provider = analysisFactory(settings); analysisProvider = provider
        do {
            var results: [AnalysisResult] = []
            if !preview {
                session.queuedForProcessing = true
                session.analysisPending = definitions.map(\.kind); session.analysisSnapshot = settings; session.promptSnapshot = definitions; try await store.save(session)
            }
            guard !definitions.isEmpty else { await provider.shutdown(); analysisProvider = nil; return (session, []) }
            let loadStarted = Date()
            await progress("Loading analysis model…"); try await provider.prepare()
            let loadSeconds = Date().timeIntervalSince(loadStarted)
            for definition in definitions {
                try Task.checkCancellation()
                var result = try await AnalysisRunner.run(definition: definition, settings: settings, session: session, segments: segments, provider: provider,
                    checkpoint: preview ? nil : session.analysisCheckpoints?[definition.kind],
                    saveCheckpoint: { checkpoint in
                        guard !preview else { return }
                        if session.analysisCheckpoints == nil { session.analysisCheckpoints = [:] }
                        session.analysisCheckpoints?[definition.kind] = checkpoint
                        try await store.save(session)
                    }, progress: progress)
                result.profile = session.profileSnapshot
                result.processing?.peakResidentBytes = (provider as? ChatAnalysisProvider)?.peakResidentBytes
                result.processing?.modelLoadSeconds = loadSeconds
                if !preview {
                    result.renderedMarkdown = MarkdownExporter.renderAnalysis(result, segments: segments)
                    try MarkdownExporter.exportAnalysis(result, session: session, segments: segments)
                    session.metadataProfile = result.profile ?? session.metadataProfile
                    session.analysisCheckpoints?[result.kind] = nil
                    session.analyses[result.kind] = result; session.analysisPending.removeAll { $0 == result.kind }; session.error = nil
                    try await store.save(session)
                }
                results.append(result)
            }
            await provider.shutdown(); analysisProvider = nil
            return (session,results)
        } catch { await provider.shutdown(); analysisProvider = nil; throw error }
    }
}
