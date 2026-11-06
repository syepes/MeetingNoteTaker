import Foundation
import CryptoKit

public enum MeetingError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, computer
    public var label: String { self == .microphone ? "Me — Microphone" : "Others — Computer" }
    public var channel: Int { self == .microphone ? 0 : 1 }
}
public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var source: AudioSource
    public var start: Double
    public var end: Double
    public var text: String
    public var approximate: Bool
    public init(id: String = UUID().uuidString, source: AudioSource, start: Double, end: Double, text: String, approximate: Bool = false) {
        self.id = id; self.source = source; self.start = start; self.end = end; self.text = text; self.approximate = approximate
    }
}
public enum SpeechEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case whisper, parakeet, apple, remote
    public var id: String { rawValue }
    public var title: String { ["whisper": "Whisper", "parakeet": "Parakeet", "apple": "Apple Speech", "remote": "Remote API"][rawValue]! }
}
public enum LLMEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case unconfigured, builtin, ollama, compatible
    public var id: String { rawValue }
    public var title: String { ["unconfigured": "Choose a provider", "builtin": "Built-in GGUF", "ollama": "Ollama", "compatible": "OpenAI-compatible"][rawValue]! }
}
public struct SpeechSettings: Codable, Equatable, Sendable {
    public var engine: SpeechEngine = .whisper
    public var modelPaths: [String: String] = [:]
    public var modelPath: String {
        get { modelPaths[engine.rawValue] ?? "" }
        set { modelPaths[engine.rawValue] = newValue }
    }
    public var parakeetVersion = "v3"
    public var language = "auto"
    public var endpoint = "https://api.openai.com/v1"
    public var authentication: ServerAuthentication?
    public var remoteModel = ""
    public var remoteLanguage: String?
    public var appleLocale: String?
    public var detailedTimestamps = false
    public init() {}
}
public struct AnalysisSettings: Codable, Equatable, Sendable {
    public var engine: LLMEngine = .unconfigured
    public var modelPath = ""
    public var endpoint = "http://localhost:11434"
    public var model = ""
    public var language = "English"
    public var authentication: ServerAuthentication?
    public var automatic = false
    public var contextTokens = 8192
    public var outputTokens = 1536
    public var structuredOutput = false
    public var catalogModel: CatalogModelIdentity?
    public var inferencePreset: AnalysisInferencePreset?
    public init() {}
    public var hasModelSelection: Bool {
        switch engine {
        case .unconfigured: return false
        case .builtin: return !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .ollama, .compatible: return !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    /// Save a provider draft; activation preserves the separate analysis behavior preferences.
    public func applyingModelConfiguration(to current: AppSettings, activate: Bool) -> AppSettings {
        var updated = current
        var profiles = updated.analysisProfiles ?? [:]
        profiles[engine.rawValue] = self; updated.analysisProfiles = profiles
        if activate {
            updated.analysis = self
            updated.analysis.language = current.analysis.language
            updated.analysis.automatic = current.analysis.automatic
        }
        return updated
    }
}
public enum AudioRetentionPolicy: Codable, Equatable, Sendable {
    case afterDays(Int)
    case afterSuccessfulTranscription
    public func isDue(exported: Date, now: Date) -> Bool {
        switch self {
        case .afterSuccessfulTranscription: return now >= exported
        case .afterDays(let days): return days > 0 && now.timeIntervalSince(exported) >= Double(days) * 86400
        }
    }
}
public struct AppSettings: Codable, Sendable {
    public var outputFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/MeetingNoteTaker").path
    public var captureTarget: CaptureTarget?
    public var microphoneID = ""
    public var microphoneEnabled = true
    public var echoReduction = true
    public var retention: AudioRetentionPolicy = .afterDays(30)
    public var speech = SpeechSettings()
    public var analysis = AnalysisSettings()
    public var analysisProfiles: [String: AnalysisSettings]?
    public var shortcutKeyCode: UInt32 = 15 // R
    public var shortcutModifiers: UInt32 = 4352 // command + option, Carbon masks
    public init() {}
}
public enum AnalysisKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case summary, keyPoints, decisions, actionItems, openQuestions
    public var id: String { rawValue }
    public var title: String {
        switch self { case .summary: return "Summary"; case .keyPoints: return "Key Points"; case .decisions: return "Decisions"; case .actionItems: return "Action Items"; case .openQuestions: return "Open Questions" }
    }
    public func emptyMessage(language: String) -> String {
        if language == "Spanish" {
            switch self {
            case .summary: return "No hay contenido suficiente para un resumen."
            case .keyPoints: return "No se registraron puntos clave relevantes."
            case .decisions: return "No se registraron decisiones explícitas."
            case .actionItems: return "No se registraron acciones de seguimiento concretas."
            case .openQuestions: return "No quedan preguntas explícitas sin resolver."
            }
        }
        if language == "French" {
            switch self { case .summary: return "Aucun contenu suffisant pour un résumé."; case .keyPoints: return "Aucun point clé identifié."; case .decisions: return "Aucune décision explicite enregistrée."; case .actionItems: return "Aucune action concrète enregistrée."; case .openQuestions: return "Aucune question explicitement ouverte." }
        }
        switch self { case .summary: return "Insufficient content for a summary."; case .keyPoints: return "No substantive key points recorded."; case .decisions: return "No explicit decisions recorded."; case .actionItems: return "No concrete follow-up actions recorded."; case .openQuestions: return "No explicit open questions remain." }
    }
}
public struct AnalysisPromptRevision: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var text: String
    public init(text: String) { id = UUID(); date = Date(); self.text = text }
}
public struct AnalysisDefinition: Codable, Identifiable, Equatable, Sendable {
    public var kind: AnalysisKind
    public var enabled = true
    public var revisions: [AnalysisPromptRevision]
    public var id: AnalysisKind { kind }
    public var current: AnalysisPromptRevision { revisions.last! }
    public init(kind: AnalysisKind) { self.kind = kind; revisions = [.init(text: DefaultPrompts.text(for: kind))] }
}
public struct AnalysisItem: Codable, Equatable, Sendable {
    public var text: String
    public var evidenceSegmentIDs: [String]
    public var owner: String?
    public var dueDateText: String?
    public init(text: String, evidenceSegmentIDs: [String], owner: String? = nil, dueDateText: String? = nil) {
        self.text = text; self.evidenceSegmentIDs = evidenceSegmentIDs; self.owner = owner; self.dueDateText = dueDateText
    }
}
public struct AnalysisPayload: Codable, Sendable { public var items: [AnalysisItem] }
public struct AnalysisResult: Codable, Sendable {
    public var kind: AnalysisKind
    public var items: [AnalysisItem]
    public var promptRevision: AnalysisPromptRevision
    public var provider: String
    public var model: String
    public var language: String
    public var generatedAt: Date
    public var transcriptFingerprint: String
    public var processing: ProcessingProgress?
    public var profile: MeetingProfileSnapshot? = nil
    public var renderedMarkdown: String? = nil
}
public enum SessionStatus: String, Codable, Sendable { case recording, interrupted, recorded, transcribing, complete, failed }
public struct CaptureEvent: Codable, Sendable {
    public var time: Double
    public var message: String
    public var kind: CaptureEventKind?
    public var source: AudioSource?
    public var wallTime: Date?
    public init(time: Double, message: String, kind: CaptureEventKind? = nil, source: AudioSource? = nil, wallTime: Date? = nil) {
        self.time = time; self.message = message; self.kind = kind; self.source = source; self.wallTime = wallTime
    }
}
public struct MeetingSession: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var startedAt = Date()
    public var timezone = TimeZone.current.identifier
    public var duration: Double = 0
    public var folder: String
    public var stem: String
    public var status: SessionStatus = .recording
    public var speech: SpeechSettings
    public var echoReduction: Bool
    public var segments: [TranscriptSegment] = []
    public var events: [CaptureEvent] = []
    public var analyses: [AnalysisKind: AnalysisResult] = [:]
    public var firstSuccessfulExport: Date?
    public var deletionRequestedAt: Date?
    public var audioDeleted = false
    public var audioFingerprint: String?
    public var error: String?
    public var completedChunks: [String] = []
    public var queuedForProcessing: Bool? = false
    public var analysisPending: [AnalysisKind] = []
    public var analysisSnapshot: AnalysisSettings?
    public var promptSnapshot: [AnalysisDefinition]?
    public var analysisCheckpoints: [AnalysisKind: AnalysisCheckpoint]?
    public var processingMetrics: [ProcessingProgress]?
    public var captureTarget: CaptureTarget?
    public var captureDiagnostics: CaptureDiagnostics?
    public var captureWarnings: [String] {
        AudioSource.allCases.compactMap { source in
            let detail = source == .microphone ? captureDiagnostics?.microphone : captureDiagnostics?.computer
            if status != .recording && detail?.expected == true && detail?.acceptedFrames == 0 && (source == .microphone || detail?.lastFailure != nil || (detail?.rejectedBuffers ?? 0) > 0) { return "\(source.label): no audio was captured from this enabled source." }
            if events.contains(where: { $0.source == source && ($0.kind == .gapBegan || $0.kind == .buffersDropped) }) {
                return "\(source.label): recording contains capture gaps; missing audio cannot be transcribed."
            }
            return nil
        }
    }
    public var captureStartedAt: Date?
    public var profileSnapshot: MeetingProfileSnapshot?
    public var metadataProfile: MeetingProfileSnapshot?
    public var tags: [String]?
    public var markdownURL: URL { URL(fileURLWithPath: folder).appendingPathComponent(stem + ".md") }
    public var audioURL: URL { URL(fileURLWithPath: folder).appendingPathComponent(stem + ".m4a") }
    public var stagingURL: URL { URL(fileURLWithPath: folder).appendingPathComponent(".meeting-\(id.uuidString)", isDirectory: true) }
    public init(folder: String, stem: String, speech: SpeechSettings, echoReduction: Bool) {
        self.folder = folder; self.stem = stem; self.speech = speech; self.echoReduction = echoReduction
    }
}
public func fingerprint(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
public func audioFingerprint(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
public let meetingEncoder: JSONEncoder = { let x = JSONEncoder(); x.outputFormatting = [.prettyPrinted, .sortedKeys]; x.dateEncodingStrategy = .iso8601; return x }()
public let meetingDecoder: JSONDecoder = { let x = JSONDecoder(); x.dateDecodingStrategy = .iso8601; return x }()
