import XCTest
@testable import MeetingCore

final class MeetingProfileTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("profile-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testMigrationPreservesLegacyPromptsSettingsAndDefault() throws {
        let root = try folder(), legacy = try SettingsStore(root: root)
        var settings = AppSettings(); settings.analysis.language = "Spanish"; settings.analysis.automatic = true
        var prompts = AnalysisKind.allCases.map { AnalysisDefinition(kind: $0) }
        prompts[0].revisions.append(.init(text: "My custom summary")); prompts[1].enabled = false
        try legacy.save(settings); try legacy.savePrompts(prompts)
        let oldSettings = try Data(contentsOf: root.appendingPathComponent("settings.json")), oldPrompts = try Data(contentsOf: root.appendingPathComponent("prompts.json"))
        let store = MeetingProfileStore(root: root), catalog = try store.loadOrMigrate(settings: settings, definitions: prompts)
        let general = try catalog.resolve()
        XCTAssertEqual(catalog.profiles.count, 4); XCTAssertEqual(general.name, "General"); XCTAssertEqual(general.language, "Spanish")
        XCTAssertEqual(general.definitions[0].current, prompts[0].current); XCTAssertFalse(general.definitions[1].enabled)
        XCTAssertEqual(catalog.profiles[0].definitions, prompts)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("settings.json")), oldSettings)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("prompts.json")), oldPrompts)
        let again = try store.loadOrMigrate(settings: AppSettings(), definitions: [])
        XCTAssertEqual(again.defaultID, catalog.defaultID); XCTAssertEqual(try meetingEncoder.encode(again), try meetingEncoder.encode(catalog))
    }
    func testCorruptOrInvalidProfilesAreNeverOverwritten() throws {
        let store = MeetingProfileStore(root: try folder())
        let bad = Data("not JSON".utf8); try bad.write(to: store.url)
        XCTAssertThrowsError(try store.loadOrMigrate(settings: AppSettings(), definitions: []))
        XCTAssertEqual(try Data(contentsOf: store.url), bad)
        var p = MeetingProfile(); var other = p; other.id = UUID(); other.name = " general "
        XCTAssertThrowsError(try store.save(.init(profiles: [p, other], defaultID: p.id)))
        p.definitions[0].revisions = []
        XCTAssertThrowsError(try store.save(.init(profiles: [p], defaultID: p.id)))
        XCTAssertEqual(try Data(contentsOf: store.url), bad)
    }
    func testLatestResolutionSavedSnapshotOverridesAndDeletedProfile() throws {
        let general = MeetingProfile(), original = MeetingProfile(template: .technicalReview, language: "French")
        let saved = original.snapshot
        var changed = original; changed.name = "Review v2"; changed.revision += 1; changed.language = "Spanish"
        changed.definitions[0].revisions.append(.init(text: "Updated prompt"))
        var catalog = MeetingProfileCatalog(profiles: [general, changed], defaultID: general.id)
        XCTAssertEqual(try catalog.resolve().id, general.id)
        XCTAssertEqual(try catalog.resolve(assigned: original.id), changed.snapshot)
        XCTAssertEqual(try catalog.resolve(saved: saved), changed.snapshot)
        XCTAssertEqual(try catalog.resolve(saved: saved, useSaved: true), saved)
        XCTAssertEqual(saved.name, "Technical review"); XCTAssertEqual(saved.language, "French")
        catalog.profiles.removeLast()
        XCTAssertThrowsError(try catalog.resolve(saved: saved))
        XCTAssertEqual(try catalog.resolve(saved: saved, useSaved: true), saved)
        XCTAssertEqual(try catalog.resolve(assigned: general.id, saved: saved).id, general.id)
    }
    func testIndependentCopiesAndModelConfigurationStayUnchanged() throws {
        let source = MeetingProfile(template: .clientCall, language: "Spanish")
        var duplicate = source; duplicate.id = UUID(); duplicate.definitions[0].revisions.append(.init(text: "Independent"))
        XCTAssertNotEqual(duplicate.definitions[0].current.id, source.definitions[0].current.id)
        var config = AnalysisSettings(); config.engine = .compatible; config.endpoint = "https://example.test/v1"; config.model = "model"; config.automatic = true
        var auth = ServerAuthentication(); auth.method = .oauthClientCredentials; config.authentication = auth
        var expected = config; expected.language = "Spanish"
        XCTAssertEqual(source.snapshot.configuring(config), expected)
        XCTAssertEqual(MeetingProfile.cleanTags([" #Project ", "project", "", "#", "réunion", "a/b"]), ["Project", "réunion", "a/b"])
        XCTAssertEqual(MeetingProfile(template: .personalJournal).definitions.filter(\.enabled).map(\.kind), [.summary, .keyPoints, .actionItems])
    }
    func testRecordingMetadataSnapshotsAndExternalTagsSurviveRefreshes() async throws {
        let root = try folder(); var settings = AppSettings(); settings.outputFolder = root.path
        var p = MeetingProfile(template: .technicalReview, language: "French"); p.name = "Réunion \"équipe\""; p.tags = ["développement"]
        let store = try SessionStore(root: root.appendingPathComponent("sessions"))
        var session = try await store.reserve(settings: settings, profile: p.snapshot)
        XCTAssertEqual(session.profileSnapshot, p.snapshot)
        var md = try String(contentsOf: session.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("profile_name: \"Réunion \\\"équipe\\\"\"")); XCTAssertTrue(md.contains("profile_revision: 1"))
        md = md.replacingOccurrences(of: "tags: [\"développement\"]", with: "tags:\n  - edited\n  - external\ncustom_field: |\n  User notes\n  Keep this exact text\n# preserved comment")
        try md.write(to: session.markdownURL, atomically: true, encoding: .utf8)
        session.duration = 42; try MarkdownExporter.updateMetadata(session)
        session.status = .complete; session.segments = [.init(id: "one", source: .microphone, start: 0, end: 1, text: "Bonjour")]
        try MarkdownExporter.exportTranscript(session, previous: nil)
        session.audioDeleted = true; try MarkdownExporter.updateMetadata(session)
        let updated = try String(contentsOf: session.markdownURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("tags:\n  - edited\n  - external"))
        XCTAssertTrue(updated.contains("custom_field: |\n  User notes\n  Keep this exact text\n# preserved comment"))
        XCTAssertTrue(updated.contains("duration_seconds: 42")); XCTAssertTrue(updated.contains("audio_status: deleted"))
        XCTAssertEqual(updated.components(separatedBy: "profile_name:").count, 2)
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.profileSnapshot, p.snapshot)
    }
    func testSuccessfulSelectiveAnalysisUpdatesMetadataAndKeepsOtherProvenance() async throws {
        let root = try folder(); var settings = AppSettings(); settings.outputFolder = root.path
        let store = try SessionStore(root: root.appendingPathComponent("sessions"))
        let initial = MeetingProfile(template: .clientCall)
        var s = try await store.reserve(settings: settings, profile: initial.snapshot)
        s.status = .complete; s.segments = [.init(id: "a", source: .microphone, start: 1, end: 2, text: "I will send it.")]
        try MarkdownExporter.exportTranscript(s, previous: nil)
        var result = AnalysisResult(kind: .summary, items: [.init(text: "A commitment", evidenceSegmentIDs: ["a"])], promptRevision: initial.definitions[0].current, provider: "test", model: "test", language: "English", generatedAt: Date(), transcriptFingerprint: MarkdownExporter.transcriptFingerprint(s.segments))
        result.profile = initial.snapshot
        try MarkdownExporter.exportAnalysis(result, session: s, segments: s.segments)
        s.analyses[.summary] = result
        let summary = try MarkdownExporter.content("summary", in: String(contentsOf: s.markdownURL, encoding: .utf8))
        var latest = initial; latest.name = "Renamed"; latest.revision = 2
        result.kind = .actionItems; result.profile = latest.snapshot
        try MarkdownExporter.exportAnalysis(result, session: s, segments: s.segments)
        let current = try String(contentsOf: s.markdownURL, encoding: .utf8)
        XCTAssertTrue(current.contains("profile_name: \"Renamed\"")); XCTAssertTrue(current.contains("profile_revision: 2"))
        XCTAssertEqual(try MarkdownExporter.content("summary", in: current), summary)
        XCTAssertTrue(summary.contains("revision 1 | Client call"))
        result.kind = .decisions; result.transcriptFingerprint = "invalid"; result.profile?.name = "Must not appear"
        XCTAssertThrowsError(try MarkdownExporter.exportAnalysis(result, session: s, segments: s.segments))
        XCTAssertEqual(try String(contentsOf: s.markdownURL, encoding: .utf8), current)
    }
    func testPreviewAndFailurePreserveFilesWhileQueuedJobKeepsSnapshot() async throws {
        let root = try folder(); var settings = AppSettings(); settings.outputFolder = root.path
        let store = try SessionStore(root: root.appendingPathComponent("sessions"))
        let original = MeetingProfile(template: .clientCall)
        var s = try await store.reserve(settings: settings, profile: original.snapshot)
        s.status = .complete; s.audioDeleted = true
        s.segments = [.init(id: "a", source: .microphone, start: 0, end: 2, text: "Je vais envoyer le rapport.")]
        try MarkdownExporter.exportTranscript(s, previous: nil); try await store.save(s)
        let before = try String(contentsOf: s.markdownURL, encoding: .utf8)
        let history = root.appendingPathComponent("sessions").appendingPathComponent(s.id.uuidString + ".json")
        let oldHistory = try Data(contentsOf: history)
        let selected = MeetingProfile(template: .technicalReview, language: "Spanish")
        s.profileSnapshot = selected.snapshot
        let pipeline = MeetingPipeline(analysisFactory: { _ in ProfileAnalysisStub(fail: false) })
        let (_, results) = try await pipeline.analyze(s, settings: selected.snapshot.configuring(settings.analysis), definitions: [selected.definitions[0]], store: store, preview: true, progress: { _ in })
        XCTAssertEqual(results.first?.language, "Spanish"); XCTAssertEqual(results.first?.profile, selected.snapshot)
        XCTAssertEqual(try String(contentsOf: s.markdownURL, encoding: .utf8), before)
        XCTAssertEqual(try Data(contentsOf: history), oldHistory)
        let failing = MeetingPipeline(analysisFactory: { _ in ProfileAnalysisStub(fail: true) })
        do { _ = try await failing.analyze(s, settings: selected.snapshot.configuring(settings.analysis), definitions: [selected.definitions[0]], store: store, progress: { _ in }); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(try String(contentsOf: s.markdownURL, encoding: .utf8), before)
        let queued = try await store.load().first!
        XCTAssertEqual(queued.profileSnapshot?.id, selected.id)
        XCTAssertEqual(queued.analysisSnapshot?.language, "Spanish")
        XCTAssertEqual(queued.promptSnapshot?.first?.current.id, selected.definitions[0].current.id)
        XCTAssertEqual(queued.metadataProfile?.id, original.id)
        let (finished, _) = try await pipeline.analyze(queued, settings: queued.analysisSnapshot!, definitions: queued.promptSnapshot!, store: store, progress: { _ in })
        XCTAssertEqual(finished.metadataProfile?.id, selected.id)
        XCTAssertTrue(try String(contentsOf: s.markdownURL, encoding: .utf8).contains("profile_name: \"Technical review\""))
    }
    func testLegacySessionsDecodeWithoutProfiles() throws {
        let s = MeetingSession(folder: "/tmp", stem: "old", speech: .init(), echoReduction: false)
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(MeetingSession.self, from: data)
        XCTAssertNil(decoded.profileSnapshot); XCTAssertNil(decoded.metadataProfile); XCTAssertNil(decoded.tags)
    }
}

private final class ProfileAnalysisStub: AnalysisProvider, @unchecked Sendable {
    let fail: Bool
    init(fail: Bool) { self.fail = fail }
    func prepare() async throws {}
    func generate(system: String, input: String) async throws -> String {
        if fail { throw MeetingError.message("Fixture failure") }
        return "{\"items\":[]}"
    }
    func cancel() {}
}
