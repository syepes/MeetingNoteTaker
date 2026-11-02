import XCTest
import AVFoundation
@testable import MeetingCore

final class MeetingCoreTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mnt-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func session() async throws -> (MeetingSession, SessionStore) {
        let folder = try directory(); var settings = AppSettings(); settings.outputFolder = folder.path
        let store = try SessionStore(root: folder.appendingPathComponent("metadata"))
        return (try await store.reserve(settings: settings), store)
    }
    func completedSession() async throws -> MeetingSession {
        var (s, _) = try await session()
        s.status = .complete; s.duration = 10
        s.segments = [.init(id: "mic-1", source: .microphone, start: 1, end: 4, text: "I will send the report."), .init(id: "computer-1", source: .computer, start: 2, end: 5, text: "Oui, vendredi.")]
        try MarkdownExporter.exportTranscript(s, previous: nil)
        s.firstSuccessfulExport = Date(timeIntervalSince1970: 1000)
        try Data("owned-audio".utf8).write(to: s.audioURL); s.audioFingerprint = try audioFingerprint(s.audioURL)
        return s
    }
    func testReservesMatchingPairsWhenEitherPathExists() async throws {
        let root = try directory(); var settings = AppSettings(); settings.outputFolder = root.path
        let store = try SessionStore(root: root.appendingPathComponent("metadata")); let date = Date(timeIntervalSince1970: 1700000000)
        let a = try await store.reserve(settings: settings, date: date)
        try FileManager.default.removeItem(at: a.markdownURL)
        let b = try await store.reserve(settings: settings, date: date)
        XCTAssertNotEqual(a.stem,b.stem)
        XCTAssertEqual(b.markdownURL.deletingPathExtension().lastPathComponent,b.audioURL.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath:a.audioURL.path))
    }
    func testTranscriptPreservesOverlapAndExternalCorrections() async throws {
        let s = try await completedSession()
        var markdown = try String(contentsOf:s.markdownURL,encoding:.utf8)
        markdown = markdown.replacingOccurrences(of:"send the report",with:"send the corrected report")
        try markdown.write(to:s.markdownURL,atomically:true,encoding:.utf8)
        let segments = try MarkdownExporter.readTranscript(s.markdownURL)
        XCTAssertEqual(segments.count,2); XCTAssertLessThan(segments[1].start,segments[0].end)
        XCTAssertTrue(segments[0].text.contains("corrected"))
        XCTAssertNotEqual(MarkdownExporter.transcriptFingerprint(segments),MarkdownExporter.transcriptFingerprint(s.segments))
        XCTAssertThrowsError(try MarkdownExporter.exportTranscript(s,previous:s))
    }
    func testImmediateRetentionKeepsMarkdownAndHistory() async throws {
        let s = try await completedSession(); let before = try MarkdownExporter.content("transcript",in:String(contentsOf:s.markdownURL,encoding:.utf8))
        let deleted = try RetentionService.apply(s,policy:.afterSuccessfulTranscription)
        XCTAssertTrue(deleted.audioDeleted); XCTAssertFalse(FileManager.default.fileExists(atPath:s.audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:s.stagingURL.path))
        XCTAssertEqual(before,try MarkdownExporter.content("transcript",in:String(contentsOf:s.markdownURL,encoding:.utf8)))
        XCTAssertEqual(try MarkdownExporter.readTranscript(s.markdownURL).count,2)
    }
    func testRetentionProtectsFailureBusyChangedAudioAndUnverifiedExport() async throws {
        var s = try await completedSession()
        XCTAssertFalse(try RetentionService.apply(s,policy:.afterSuccessfulTranscription,busy:true).audioDeleted)
        s.status = .failed; XCTAssertFalse(try RetentionService.apply(s,policy:.afterSuccessfulTranscription).audioDeleted); s.status = .complete
        XCTAssertFalse(try RetentionService.apply(s,policy:.afterDays(30),now:Date(timeIntervalSince1970:1000+29*86400)).audioDeleted)
        try Data("user-replacement".utf8).write(to:s.audioURL)
        XCTAssertThrowsError(try RetentionService.apply(s,policy:.afterSuccessfulTranscription))
        XCTAssertTrue(FileManager.default.fileExists(atPath:s.audioURL.path))
    }
    func testAnalysisValidatesEvidenceAndRequiredFields() throws {
        let valid = "{\"items\":[{\"text\":\"Send report\",\"evidenceSegmentIDs\":[\"a\"],\"owner\":null,\"dueDateText\":null}]}"
        XCTAssertEqual(try AnalysisRunner.validate(valid,allowed:["a"]).count,1)
        XCTAssertThrowsError(try AnalysisRunner.validate(valid,allowed:["b"]))
        XCTAssertThrowsError(try AnalysisRunner.validate("{\"items\":[{\"text\":\"no evidence\"}]}",allowed:[]))
        XCTAssertThrowsError(try AnalysisRunner.validate("```json\n{\"items\":[]}\n```",allowed:[]))
        XCTAssertTrue(try AnalysisRunner.validate("{\"items\":[]}",allowed:[]).isEmpty)
    }
    func testLongEditedSegmentsAreNotTruncated() throws {
        let text = String(repeating:"Bonjour été. ",count:1000)
        let chunks = try AnalysisRunner.chunks([.init(id:"a",source:.microphone,start:0,end:100,text:text)],byteBudget:1000)
        XCTAssertGreaterThan(chunks.count,5); XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 1000 })
        let rejoined = chunks.flatMap { $0.components(separatedBy:"\n").filter { !$0.isEmpty }.map { $0.components(separatedBy:": ").dropFirst().joined(separator:": ") } }.joined()
        XCTAssertEqual(rejoined,text)
    }
    func testPromptRevisionsSurviveReloadAndDefaultReset() throws {
        let store = try SettingsStore(root:directory()); var definitions = try store.loadPrompts()
        let original = definitions[0].current.id
        definitions[0].revisions.append(.init(text:"Custom summary prompt")); try store.savePrompts(definitions)
        var restored = try store.loadPrompts(); XCTAssertEqual(restored[0].current.text,"Custom summary prompt"); XCTAssertNotEqual(restored[0].current.id,original)
        restored[0].revisions.append(.init(text:DefaultPrompts.text(for:.summary))); try store.savePrompts(restored)
        XCTAssertEqual(try store.loadPrompts()[0].revisions.count,3)
        var settings = AppSettings(); settings.retention = .afterDays(0); XCTAssertThrowsError(try store.save(settings))
    }
    func testRegenerateAfterAudioDeletionPreservesNotesAndOtherAnalysis() async throws {
        var s = try await completedSession(); s = try RetentionService.apply(s,policy:.afterSuccessfulTranscription)
        var markdown = try String(contentsOf:s.markdownURL,encoding:.utf8)
        markdown = markdown.replacingOccurrences(of:"## Personal Notes",with:"## Personal Notes\n\nMy private note.")
        try markdown.write(to:s.markdownURL,atomically:true,encoding:.utf8)
        let result = AnalysisResult(kind:.actionItems,items:[.init(text:"Send report",evidenceSegmentIDs:["mic-1"],owner:"Me")],promptRevision:.init(text:"test"),provider:"test",model:"test",language:"English",generatedAt:Date(),transcriptFingerprint:MarkdownExporter.transcriptFingerprint(s.segments))
        try MarkdownExporter.exportAnalysis(result,session:s,segments:s.segments)
        let after = try String(contentsOf:s.markdownURL,encoding:.utf8)
        XCTAssertTrue(after.contains("My private note.")); XCTAssertTrue(after.contains("Send report")); XCTAssertTrue(after.contains("[00:00:01](#segment-mic-1)"))
        XCTAssertEqual(try MarkdownExporter.content("summary",in:after),"## Summary\n\nNot generated.")
    }
    func testOptimisticMarkdownConflictDoesNotOverwrite() async throws {
        let s = try await completedSession(); let old = try String(contentsOf:s.markdownURL,encoding:.utf8)
        try (old+"\nExternal change").write(to:s.markdownURL,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try MarkdownExporter.commit("replacement",replacing:old,at:s.markdownURL))
        XCTAssertTrue(try String(contentsOf:s.markdownURL,encoding:.utf8).contains("External change"))
    }
    func testSpanishAnalysisExportLocalizesLabelsAndPreservesEvidenceAndTranscript() async throws {
        let session = try await completedSession()
        let originalTranscript = try MarkdownExporter.content("transcript", in: String(contentsOf: session.markdownURL, encoding: .utf8))
        let result = AnalysisResult(kind: .actionItems, items: [
            .init(text: "Enviar el informe", evidenceSegmentIDs: ["mic-1"], owner: "Me", dueDateText: "mañana"),
            .init(text: "Revisar el informe", evidenceSegmentIDs: ["computer-1"])
        ], promptRevision: .init(text: "custom prompt"), provider: "test", model: "test", language: "Spanish", generatedAt: Date(), transcriptFingerprint: MarkdownExporter.transcriptFingerprint(session.segments))
        try MarkdownExporter.exportAnalysis(result, session: session, segments: session.segments)
        let markdown = try String(contentsOf: session.markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Enviar el informe — Responsable: Me; Fecha límite: mañana"))
        XCTAssertTrue(markdown.contains("Revisar el informe — Responsable: Sin especificar; Fecha límite: Sin especificar"))
        XCTAssertTrue(markdown.contains("[00:00:01](#segment-mic-1)"))
        XCTAssertEqual(try MarkdownExporter.content("transcript", in: markdown), originalTranscript)
        for kind in AnalysisKind.allCases {
            var empty = result; empty.kind = kind; empty.items = []
            let rendered = MarkdownExporter.renderAnalysis(empty, segments: session.segments)
            XCTAssertTrue(rendered.contains(kind.emptyMessage(language: "Spanish")))
            XCTAssertNotEqual(kind.emptyMessage(language: "Spanish"), kind.emptyMessage(language: "English"))
            XCTAssertNotEqual(kind.emptyMessage(language: "Spanish"), kind.emptyMessage(language: "French"))
        }
    }
    func testSpanishAnalysisLanguagePersistsWithoutChangingCustomPrompts() throws {
        let store = try SettingsStore(root: directory())
        var settings = AppSettings(); settings.analysis.language = "Spanish"
        var prompts = try store.loadPrompts()
        prompts[0].revisions.append(.init(text: "Keep my customized summary instructions."))
        try store.savePrompts(prompts); try store.save(settings)
        let restored = try store.loadSettings()
        XCTAssertEqual(restored.analysis.language, "Spanish")
        XCTAssertEqual(try store.loadPrompts()[0].current.id, prompts[0].current.id)
        XCTAssertTrue(DefaultPrompts.shared(language: restored.analysis.language).hasPrefix("Analyze the supplied meeting transcript in Spanish."))
        var snapshot = MeetingSession(folder: restored.outputFolder, stem: "spanish-fixture", speech: restored.speech, echoReduction: restored.echoReduction)
        snapshot.analysisSnapshot = restored.analysis
        let decoded = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.analysisSnapshot?.language, "Spanish")
    }
    func testMalformedEditedTimestampsAndFirstAnalysisConflictsArePreserved() async throws {
        let s = try await completedSession()
        let original = try String(contentsOf:s.markdownURL,encoding:.utf8)
        try original.replacingOccurrences(of:"microphone|1.0|4.0",with:"microphone|..|4.0").write(to:s.markdownURL,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try MarkdownExporter.readTranscript(s.markdownURL))
        let edited = original.replacingOccurrences(of:"## Summary\n\nNot generated.",with:"## Summary\n\nMy manually written summary.")
        try edited.write(to:s.markdownURL,atomically:true,encoding:.utf8)
        let result = AnalysisResult(kind:.summary,items:[],promptRevision:.init(text:"test"),provider:"test",model:"test",language:"English",generatedAt:Date(),transcriptFingerprint:MarkdownExporter.transcriptFingerprint(s.segments))
        XCTAssertThrowsError(try MarkdownExporter.exportAnalysis(result,session:s,segments:s.segments))
        XCTAssertEqual(try String(contentsOf:s.markdownURL,encoding:.utf8),edited)
    }
    func writePacket(_ url: URL, time: Double, rate: Double, samples: [Float], append: Bool = false) throws {
        var t=time; var r=rate; var n=UInt32(samples.count); var data=Data()
        withUnsafeBytes(of:&t){data.append(contentsOf:$0)}; withUnsafeBytes(of:&r){data.append(contentsOf:$0)}; withUnsafeBytes(of:&n){data.append(contentsOf:$0)}
        samples.withUnsafeBytes{data.append(contentsOf:$0)}
        if append { let h=try FileHandle(forWritingTo:url); try h.seekToEnd(); try h.write(contentsOf:data); try h.close() } else { try data.write(to:url) }
    }
    func testAudioFinalizationSeparatesSourcesAndPreservesGaps() async throws {
        let (s,_) = try await session()
        try writePacket(s.stagingURL.appendingPathComponent("microphone.packets"),time:0,rate:16000,samples:[Float](repeating:0.25,count:1600))
        try writePacket(s.stagingURL.appendingPathComponent("computer.packets"),time:0.05,rate:48000,samples:[Float](repeating:-0.5,count:4800))
        let result=try AudioFiles.finalize(s)
        let recovered=try AudioFiles.finalize(s)
        XCTAssertEqual(recovered.fingerprint,result.fingerprint)
        XCTAssertEqual(result.duration,0.15,accuracy:0.0001)
        let file=try AVAudioFile(forReading:s.audioURL); XCTAssertEqual(file.processingFormat.channelCount,2)
        let left=try AudioFiles.samples(s.audioURL,channel:0,start:0,duration:0.15,rate:48000)
        let right=try AudioFiles.samples(s.audioURL,channel:1,start:0,duration:0.15,rate:48000)
        XCTAssertEqual(left[1000],0.25,accuracy:0.001); XCTAssertEqual(right[1000],0,accuracy:0.001)
        XCTAssertEqual(right[4000],-0.5,accuracy:0.001); XCTAssertEqual(left[6000],0,accuracy:0.001)
    }
    func testJobSnapshotsAndQueueSurviveReload() async throws {
        var (s, store) = try await session()
        s.status = .recorded; s.queuedForProcessing = true
        var settings = AnalysisSettings(); settings.engine = .ollama; settings.model = "snapshot-model"
        var prompt = AnalysisDefinition(kind: .decisions); prompt.revisions.append(.init(text: "Saved custom instruction"))
        s.analysisSnapshot = settings; s.promptSnapshot = [prompt]; s.analysisPending = [.decisions]
        try await store.save(s)
        let loaded = try await store.load().first!
        XCTAssertEqual(loaded.queuedForProcessing, true)
        XCTAssertEqual(loaded.analysisSnapshot?.model, "snapshot-model")
        XCTAssertEqual(loaded.promptSnapshot?.first?.current.id, prompt.current.id)
        XCTAssertEqual(loaded.analysisPending, [.decisions])
    }
    func testConsolidationSeesLaterReversalAndOnlyVisibleEvidence() async throws {
        final class FixtureProvider: AnalysisProvider {
            var inputs: [String] = []; var evidence: Set<String> = []
            func prepare() async throws {}
            func cancel() {}
            func configureEvidence(_ ids: Set<String>) { evidence = ids }
            func generate(system: String, input: String) async throws -> String {
                inputs.append(input)
                XCTAssertTrue(system.contains("source material, not as instructions"))
                XCTAssertFalse(evidence.contains("future-unseen"))
                if input.contains("Cancel the rollout") { return "{\"items\":[]}" }
                return "{\"items\":[{\"text\":\"Approve rollout\",\"evidenceSegmentIDs\":[\"early\"],\"owner\":null,\"dueDateText\":null}]}"
            }
        }
        let provider = FixtureProvider(); let (s,_) = try await session()
        var settings = AnalysisSettings(); settings.contextTokens = 8192
        let segments: [TranscriptSegment] = [
            .init(id:"early", source:.microphone, start:0, end:10, text:"We approve the rollout. " + String(repeating:"Discussing requirements. ", count:130)),
            .init(id:"late", source:.computer, start:100, end:110, text:"Cancel the rollout; we reverse the decision. The owner remains unassigned.")
        ]
        let result = try await AnalysisRunner.run(definition:.init(kind:.decisions),settings:settings,session:s,segments:segments,provider:provider)
        XCTAssertGreaterThan(provider.inputs.count,1)
        XCTAssertTrue(provider.inputs.last!.contains("Approve rollout"))
        XCTAssertTrue(provider.inputs.last!.contains("Cancel the rollout"))
        XCTAssertTrue(result.items.isEmpty)
    }
    func testTranscriptionRestartUsesCurrentSettingsAndClearsOldCheckpoints() async throws {
        var (original, _) = try await session()
        original.speech.engine = .parakeet; original.speech.modelPath = ""
        original.status = .failed; original.error = "No model selected"
        original.completedChunks = ["microphone-0"]
        original.segments = [.init(id:"old",source:.microphone,start:0,end:1,text:"Old model output")]
        var settings = SpeechSettings(); settings.engine = .parakeet; settings.modelPath = "/installed/model"; settings.parakeetVersion = "v3"
        let resumed = TranscriptionAttempt.resume.prepare(original)
        XCTAssertEqual(resumed.speech.modelPath, "")
        XCTAssertEqual(resumed.completedChunks, original.completedChunks)
        let restarted = TranscriptionAttempt.restart(settings:settings,echoReduction:false).prepare(original)
        XCTAssertEqual(restarted.speech, settings); XCTAssertFalse(restarted.echoReduction)
        XCTAssertTrue(restarted.completedChunks.isEmpty); XCTAssertTrue(restarted.segments.isEmpty); XCTAssertNil(restarted.error)
        XCTAssertEqual(original.completedChunks.count, 1); XCTAssertEqual(original.speech.modelPath, "")
        XCTAssertEqual(restarted.audioURL, original.audioURL); XCTAssertEqual(restarted.markdownURL, original.markdownURL)
    }
    func testParakeetImportsDetectComponentsInsteadOfFolderNames() async throws {
        let root = try directory(); let manager = try ModelManager(root:root.appendingPathComponent("installed"))
        for (folder, joint, expected) in [("renamed-v3-folder", "JointDecision.mlmodelc", "v2"), ("my-custom-model", "JointDecisionv3.mlmodelc", "v3")] {
            let url = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
            for name in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", joint] {
                try FileManager.default.createDirectory(at:url.appendingPathComponent(name),withIntermediateDirectories:true)
                try Data([1]).write(to:url.appendingPathComponent(name).appendingPathComponent("coremldata.bin"))
            }
            try Data("{}".utf8).write(to:url.appendingPathComponent("parakeet_vocab.json"))
            XCTAssertEqual(try ModelManager.parakeetVersion(at:url), expected)
            let imported = try await manager.importModel(url,kind:.parakeet)
            XCTAssertEqual(try ModelManager.parakeetVersion(at:imported), expected)
            XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
            try FileManager.default.removeItem(at:url.appendingPathComponent("Preprocessor.mlmodelc"))
            XCTAssertThrowsError(try ModelManager.validateFile(url,kind:.parakeet))
        }
    }
    func testRetryUsesInstalledParakeetAfterMissingModel() async throws {
        guard let model = ProcessInfo.processInfo.environment["MNT_PARAKEET_TEST_MODEL"], let audio = ProcessInfo.processInfo.environment["MNT_TEST_AUDIO"] else { throw XCTSkip("Set MNT_PARAKEET_TEST_MODEL and MNT_TEST_AUDIO for the installed-model retry regression.") }
        var (original, store) = try await session(); original.speech.engine = .parakeet; original.speech.modelPath = ""
        let samples = try AudioFiles.samples(URL(fileURLWithPath:audio),channel:0,start:0,duration:11)
        for source in AudioSource.allCases {
            for start in stride(from:0,to:samples.count,by:1024) {
                let part = Array(samples[start..<min(start+1024,samples.count)])
                try writePacket(original.stagingURL.appendingPathComponent(source.rawValue + ".packets"),time:Double(start)/16000 + (source == .computer ? 0.1 : 0),rate:16000,samples:part,append:start > 0)
            }
        }
        let pipeline = MeetingPipeline(); original = try await pipeline.finalize(original,store:store)
        do {
            _ = try await pipeline.transcribe(original,store:store,progress:{_ in})
            XCTFail("A job recorded before model installation should have no model snapshot")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Retry with current model")) }
        let failed = try await store.load().first!
        var settings = SpeechSettings(); settings.engine = .parakeet; settings.modelPath = model; settings.parakeetVersion = "v3"
        let result = try await pipeline.transcribe(failed,store:store,attempt:.restart(settings:settings,echoReduction:false),progress:{_ in})
        XCTAssertEqual(result.status,.complete); XCTAssertNil(result.error); XCTAssertNotNil(result.firstSuccessfulExport)
        XCTAssertEqual(result.speech.modelPath, model)
        XCTAssertEqual(Set(result.segments.map(\.source)), Set(AudioSource.allCases))
        XCTAssertTrue(result.segments.allSatisfy { $0.text.lowercased().contains("country") })
        XCTAssertEqual(try MarkdownExporter.readTranscript(result.markdownURL).count,2)
        XCTAssertTrue(FileManager.default.fileExists(atPath:result.audioURL.path))
    }
    func testActiveModelMatchesDirectoryURLRepresentations() throws {
        let folder = try directory()
        let enumerated = URL(fileURLWithPath:folder.path,isDirectory:true)
        let stored = URL(fileURLWithPath:folder.path,isDirectory:false)
        XCTAssertTrue(ModelManager.sameLocation(stored.path,enumerated))
        XCTAssertTrue(ModelManager.sameLocation(folder.path+"/",enumerated))
        XCTAssertFalse(ModelManager.sameLocation("",enumerated))
        XCTAssertFalse(ModelManager.sameLocation(folder.appendingPathComponent("other").path,enumerated))
    }
    func testParakeetUltraMetadataSurvivesRenamedImport() async throws {
        let root = try directory(); let source = root.appendingPathComponent("my-renamed-speech-model")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        for name in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"] {
            try FileManager.default.createDirectory(at:source.appendingPathComponent(name),withIntermediateDirectories:true)
            try Data([1]).write(to:source.appendingPathComponent(name).appendingPathComponent("coremldata.bin"))
        }
        try Data("{}".utf8).write(to:source.appendingPathComponent("parakeet_vocab.json"))
        try Data(#"{"base_model":"moondream/parakeet-ultra","contract":"parakeet-tdt-0.6b-v3-coreml"}"#.utf8).write(to:source.appendingPathComponent("config.json"))
        XCTAssertEqual(try ModelManager.parakeetVersion(at:source),"ultra")
        let manager = try ModelManager(root:root.appendingPathComponent("managed"))
        let imported = try await manager.importModel(source,kind:.parakeet)
        XCTAssertEqual(try ModelManager.parakeetVersion(at:imported),"ultra")
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.appendingPathComponent("config.json").path))
        try FileManager.default.moveItem(at:source.appendingPathComponent("JointDecisionv3.mlmodelc"),to:source.appendingPathComponent("JointDecision.mlmodelc"))
        XCTAssertThrowsError(try ModelManager.parakeetVersion(at:source))
    }
    func testParakeetUltraNativeEnglishAndFrench() async throws {
        guard let root = ProcessInfo.processInfo.environment["MNT_ULTRA_TEST_ROOT"], let english = ProcessInfo.processInfo.environment["MNT_TEST_AUDIO"], let french = ProcessInfo.processInfo.environment["MNT_FRENCH_TEST_AUDIO"] else { throw XCTSkip("Set MNT_ULTRA_TEST_ROOT, MNT_TEST_AUDIO, and MNT_FRENCH_TEST_AUDIO to explicitly download/test Ultra in a development cache.") }
        let manager = try ModelManager(root:URL(fileURLWithPath:root))
        let url = try await manager.downloadParakeet(version:"ultra",progress:{_ in})
        XCTAssertEqual(try ModelManager.parakeetVersion(at:url),"ultra")
        let installed = try await manager.installed()
        XCTAssertTrue(installed.contains { ModelManager.sameLocation(url.path, $0.url) })
        var settings = SpeechSettings(); settings.engine = .parakeet; settings.modelPath = url.path; settings.parakeetVersion = "ultra"
        let provider = try SpeechProviders.make(settings); defer { provider.cancel() }
        try await provider.prepare()
        for (audio, expected) in [(english,"country"),(french,"réunion")] {
            let file = try AVAudioFile(forReading:URL(fileURLWithPath:audio))
            let duration = Double(file.length)/file.processingFormat.sampleRate
            let segments = try await provider.transcribe(URL(fileURLWithPath:audio),source:.microphone,offset:0,duration:duration)
            XCTAssertTrue(segments.map(\.text).joined().lowercased().contains(expected))
            XCTAssertTrue(segments.allSatisfy { $0.start >= 0 && $0.end <= duration })
        }
    }
    func testParakeetNativeSmoke() async throws {
        guard let root = ProcessInfo.processInfo.environment["MNT_PARAKEET_TEST_ROOT"], let audio = ProcessInfo.processInfo.environment["MNT_TEST_AUDIO"] else { throw XCTSkip("Set MNT_PARAKEET_TEST_ROOT and MNT_TEST_AUDIO to explicitly download/test Parakeet in a development cache.") }
        let manager = try ModelManager(root:URL(fileURLWithPath:root))
        let url = try await manager.downloadParakeet(version:"v3",progress:{_ in})
        var settings = SpeechSettings(); settings.engine = .parakeet; settings.modelPath = url.path
        let provider = try SpeechProviders.make(settings); defer { provider.cancel() }
        try await provider.prepare()
        let segments = try await provider.transcribe(URL(fileURLWithPath:audio),source:.computer,offset:10,duration:11)
        XCTAssertTrue(segments.map(\.text).joined().lowercased().contains("country"))
        XCTAssertTrue(segments.allSatisfy { $0.start >= 10 && $0.end <= 21 })
    }
    func testFrenchLocalTranscriptionWithoutTranslation() async throws {
        guard let root = ProcessInfo.processInfo.environment["MNT_FRENCH_TEST_ROOT"], let audio = ProcessInfo.processInfo.environment["MNT_FRENCH_TEST_AUDIO"] else { throw XCTSkip("Set MNT_FRENCH_TEST_ROOT and MNT_FRENCH_TEST_AUDIO for explicit French model integration tests.") }
        let manager = try ModelManager(root:URL(fileURLWithPath:root))
        let whisperURL = try await manager.downloadWhisper(name:"small",progress:{_ in})
        let parakeetURL = try await manager.downloadParakeet(version:"v3",progress:{_ in})
        let file = try AVAudioFile(forReading:URL(fileURLWithPath:audio))
        let duration = Double(file.length)/file.processingFormat.sampleRate
        for (engine, path) in [(SpeechEngine.whisper, whisperURL.path), (.parakeet, parakeetURL.path)] {
            var settings = SpeechSettings(); settings.engine = engine; settings.modelPath = path; settings.language = "fr"
            let provider = try SpeechProviders.make(settings); defer { provider.cancel() }
            try await provider.prepare()
            let segments = try await provider.transcribe(URL(fileURLWithPath:audio),source:.microphone,offset:0,duration:duration)
            let text = segments.map(\.text).joined(separator:" ").lowercased()
            XCTAssertTrue(text.contains("rapport"), "\(engine): \(text)")
            XCTAssertTrue(text.contains("réunion"), "\(engine): \(text)")
            XCTAssertFalse(text.contains("the meeting"), "French must not be translated to English")
        }
    }
    func testNativeWhisperSmoke() async throws {
        guard let model = ProcessInfo.processInfo.environment["MNT_WHISPER_TEST_MODEL"], let audio = ProcessInfo.processInfo.environment["MNT_TEST_AUDIO"] else { throw XCTSkip("Set MNT_WHISPER_TEST_MODEL and MNT_TEST_AUDIO for native model integration.") }
        let folder = try directory(); let wav = folder.appendingPathComponent("sample.wav")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: audio), to: wav)
        var settings = SpeechSettings(); settings.modelPath = model; settings.language = "en"
        let provider = try SpeechProviders.make(settings); defer { provider.cancel() }
        try await provider.prepare()
        let parts = try await provider.transcribe(wav,source:.microphone,offset:0,duration:11)
        XCTAssertTrue(parts.map(\.text).joined().lowercased().contains("country")); XCTAssertFalse(parts.isEmpty)
    }
    func testNativeGGUFSmoke() async throws {
        guard let model = ProcessInfo.processInfo.environment["MNT_GGUF_TEST_MODEL"] else { throw XCTSkip("Set MNT_GGUF_TEST_MODEL for native LLM integration.") }
        var settings = AnalysisSettings(); settings.engine = .builtin; settings.modelPath = model; settings.contextTokens = 8192; settings.outputTokens = 512
        let provider = ChatAnalysisProvider(settings); defer { provider.cancel() }
        provider.configureEvidence(["a"])
        try await provider.prepare()
        let output = try await provider.generate(system: "Extract one action item. " + DefaultPrompts.contract, input: "[segment a] Me: I will send the report tomorrow.")
        let items = try AnalysisRunner.validate(output,allowed:["a"])
        XCTAssertFalse(items.isEmpty)
        let french = try await provider.generate(system: DefaultPrompts.shared(language:"French") + "\n" + DefaultPrompts.text(for:.actionItems) + "\n" + DefaultPrompts.contract, input:"[segment a] Me: Je vais envoyer le rapport demain.")
        let frenchItems = try AnalysisRunner.validate(french,allowed:["a"])
        XCTAssertTrue(frenchItems.map(\.text).joined().lowercased().contains("rapport"))
    }
    func testTwoHourTimelineAndTruncatedLastPacketRecovery() throws {
        let url=try directory().appendingPathComponent("track.packets")
        try writePacket(url,time:0,rate:44100,samples:[Float](repeating:0.1,count:4410))
        try writePacket(url,time:7199.9,rate:48000,samples:[Float](repeating:0.2,count:4800),append:true)
        let handle=try FileHandle(forWritingTo:url); try handle.seekToEnd(); try handle.write(contentsOf:Data([1,2,3])); try handle.close()
        XCTAssertEqual(try PacketReader.duration(url),7200,accuracy:0.001)
        let reader=try PacketReader(url); XCTAssertEqual(try reader.sample(at:3600),0)
        XCTAssertEqual(try reader.sample(at:7199.95),0.2,accuracy:0.001)
    }
    func testEchoReductionLeavesUncorrelatedSpeechAlone() {
        let ref=(0..<16000).map{Float(sin(Double($0)*0.1))*0.1}
        var mic=(0..<16000).map{Float(sin(Double($0)*0.17))*0.2}; let original=mic
        AudioFiles.reduceEcho(microphone:&mic,computer:ref)
        XCTAssertEqual(mic,original)
        var echo=ref.map{$0*0.7}
        let before=echo.reduce(0.0){$0+Double($1*$1)}; AudioFiles.reduceEcho(microphone:&echo,computer:ref)
        let after=echo.reduce(0.0){$0+Double($1*$1)}; XCTAssertLessThan(after,before*0.2)
    }
}
