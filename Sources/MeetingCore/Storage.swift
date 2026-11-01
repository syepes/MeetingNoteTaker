import Foundation
import Darwin

public final class SettingsStore {
    public let root: URL
    public init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingNoteTaker")) throws {
        self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func loadSettings() throws -> AppSettings {
        let url = root.appendingPathComponent("settings.json")
        return FileManager.default.fileExists(atPath: url.path) ? try meetingDecoder.decode(AppSettings.self, from: Data(contentsOf: url)) : AppSettings()
    }
    public func save(_ settings: AppSettings) throws {
        if case .afterDays(let days) = settings.retention, days < 1 { throw MeetingError.message("Retention must be a positive number of days.") }
        guard settings.analysis.contextTokens >= 2048, settings.analysis.outputTokens >= 128,
              settings.analysis.outputTokens < settings.analysis.contextTokens / 2 else { throw MeetingError.message("Use a context of at least 2048 tokens and an output budget below half the context.") }
        try meetingEncoder.encode(settings).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
    }
    public func loadPrompts() throws -> [AnalysisDefinition] {
        let url = root.appendingPathComponent("prompts.json")
        var definitions = FileManager.default.fileExists(atPath: url.path) ? try meetingDecoder.decode([AnalysisDefinition].self, from: Data(contentsOf: url)) : []
        for kind in AnalysisKind.allCases where !definitions.contains(where: { $0.kind == kind }) { definitions.append(.init(kind: kind)) }
        guard definitions.allSatisfy({ !$0.revisions.isEmpty }) else { throw MeetingError.message("Prompt revisions are damaged. Restore prompts.json from backup.") }
        return definitions
    }
    public func savePrompts(_ definitions: [AnalysisDefinition]) throws { try meetingEncoder.encode(definitions).write(to: root.appendingPathComponent("prompts.json"), options: .atomic) }
}

public actor SessionStore {
    public let root: URL
    private var deletedIDs: Set<UUID> = []
    public init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    public func save(_ session: MeetingSession) throws {
        let url = recordURL(session.id)
        guard !deletedIDs.contains(session.id) else { throw MeetingError.message("This meeting has been deleted.") }
        if let data = try? Data(contentsOf: url),
           let existing = try? meetingDecoder.decode(MeetingSession.self, from: data), existing.deletionRequestedAt != nil {
            throw MeetingError.message("This meeting is pending deletion. Retry deletion in Meetings.")
        }
        try write(session)
    }
    private func recordURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    private func write(_ session: MeetingSession) throws {
        try meetingEncoder.encode(session).write(to: recordURL(session.id), options: .atomic)
    }

    /// Serialized with saves and retention; the record stays available until every file is trashed.
    public func trashMeeting(_ id: UUID) throws {
        try trashMeeting(id, moveToTrash: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) })
    }
    func trashMeeting(_ id: UUID, moveToTrash: (URL) throws -> Void) throws {
        let record = recordURL(id)
        var session = try meetingDecoder.decode(MeetingSession.self, from: Data(contentsOf: record))
        guard session.id == id else { throw MeetingError.message("Meeting history identity does not match.") }
        session.deletionRequestedAt = session.deletionRequestedAt ?? Date()
        session.queuedForProcessing = false
        try write(session)
        do {
            let folder = URL(fileURLWithPath: session.folder).standardizedFileURL
            guard session.folder.hasPrefix("/"), !session.stem.isEmpty,
                  session.stem != ".", session.stem != "..", !session.stem.contains("/"),
                  folder.resolvingSymlinksInPath() == folder else {
                throw MeetingError.message("The meeting paths are unsafe or contain symbolic links.")
            }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else {
                throw MeetingError.message("The meeting folder is unavailable. Reconnect it and retry deletion.")
            }
            let items = [session.markdownURL, session.audioURL, session.stagingURL, record]
            // Validate all paths before moving any item. Never follow symbolic links.
            var existing: [URL] = []
            for item in items {
                let attributes: [FileAttributeKey: Any]
                do { attributes = try FileManager.default.attributesOfItem(atPath: item.path) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { continue }
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                      item.standardizedFileURL.resolvingSymlinksInPath() == item.standardizedFileURL else {
                    throw MeetingError.message("A meeting item contains a symbolic link. Resolve it before retrying deletion.")
                }
                let expectedType: FileAttributeType = item == session.stagingURL ? .typeDirectory : .typeRegular
                guard attributes[.type] as? FileAttributeType == expectedType else {
                    throw MeetingError.message("A meeting item was replaced with an unexpected file type.")
                }
                existing.append(item)
            }
            for item in existing { try moveToTrash(item) }
            deletedIDs.insert(id)
        } catch {
            session.error = "Deletion incomplete: \(error.localizedDescription) Retry deletion in Meetings."
            try? write(session)
            throw MeetingError.message(session.error!)
        }
    }
    public func load() throws -> [MeetingSession] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try meetingDecoder.decode(MeetingSession.self, from: Data(contentsOf: $0)) }.sorted { $0.startedAt > $1.startedAt }
    }
    public func cleanup(policy: AudioRetentionPolicy) throws -> [String] {
        var failures: [String] = []
        for session in try load() where session.deletionRequestedAt == nil {
            do { try save(RetentionService.apply(session, policy: policy)) }
            catch { failures.append("\(session.stem): \(error.localizedDescription)") }
        }
        return failures
    }
    public func reserve(settings: AppSettings, date: Date = Date(), profile: MeetingProfileSnapshot? = nil) throws -> MeetingSession {
        let folder = URL(fileURLWithPath: settings.outputFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd - HHmmss"
        let base = formatter.string(from: date)
        for index in 1...10000 {
            let stem = base + (index == 1 ? "" : String(format: " - %02d", index))
            let md = folder.appendingPathComponent(stem + ".md"); let audio = folder.appendingPathComponent(stem + ".m4a")
            if FileManager.default.fileExists(atPath: audio.path) { continue }
            let fd = open(md.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            if fd < 0 { if errno == EEXIST { continue }; throw MeetingError.message("Cannot create a meeting in the selected folder: \(String(cString: strerror(errno)))") }
            close(fd)
            let audioFD = open(audio.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            if audioFD < 0 { try? FileManager.default.removeItem(at: md); if errno == EEXIST { continue }; throw MeetingError.message("Cannot reserve audio file.") }
            close(audioFD)
            var session = MeetingSession(folder: folder.path, stem: stem, speech: settings.speech, echoReduction: settings.echoReduction)
            session.profileSnapshot = profile; session.metadataProfile = profile; session.tags = profile?.tags
            session.startedAt = date; session.captureTarget = settings.captureTarget
            try FileManager.default.createDirectory(at: session.stagingURL, withIntermediateDirectories: true)
            try save(session)
            try MarkdownExporter.initial(session).write(to: md, atomically: true, encoding: .utf8)
            return session
        }
        throw MeetingError.message("Unable to reserve a unique meeting filename.")
    }
}

public enum RetentionService {
    public static func apply(_ session: MeetingSession, policy: AudioRetentionPolicy, busy: Bool = false, now: Date = Date()) throws -> MeetingSession {
        guard session.deletionRequestedAt == nil, !busy, session.status == .complete, !session.audioDeleted, let exported = session.firstSuccessfulExport,
              policy.isDue(exported: exported, now: now) else { return session }
        let markdown = try String(contentsOf: session.markdownURL, encoding: .utf8)
        guard markdown.contains("meeting_id: \"\(session.id.uuidString)\""), markdown.contains(MarkdownExporter.begin("transcript")) else {
            throw MeetingError.message("Audio retained: the exported transcript cannot be verified.")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: session.audioURL.path) {
            guard let expected = session.audioFingerprint, try audioFingerprint(session.audioURL) == expected else {
                throw MeetingError.message("Audio retained: the file was changed outside the app.")
            }
            try fm.removeItem(at: session.audioURL)
        }
        if fm.fileExists(atPath: session.stagingURL.path) { try fm.removeItem(at: session.stagingURL) }
        var result = session; result.audioDeleted = true
        // Metadata update is optional if the user edited its managed block. Never rewrite transcript.
        try MarkdownExporter.updateMetadata(result)
        return result
    }
}
