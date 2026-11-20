import XCTest
@testable import MeetingCore

final class AnalysisWorkflowTests: XCTestCase {
    private let session = MeetingSession(folder: "/tmp", stem: "fixture", speech: .init(), echoReduction: false)
    private func turn(_ id: String, _ text: String) -> TranscriptSegment {
        .init(id: id, source: .microphone, start: 0, end: 1, text: text)
    }

    private final class Provider: AnalysisProvider {
        var counts = 0
        var generations: [String] = []
        var outputs: [String]
        let singleTurn: Bool
        init(_ outputs: [String], singleTurn: Bool = false) { self.outputs = outputs; self.singleTurn = singleTurn }
        func prepare() async throws {}
        func cancel() {}
        func countTokens(system: String, input: String) async throws -> InputTokenCount {
            counts += 1
            let turns = input.components(separatedBy: "[segment ").count - 1
            return .init(tokens: singleTurn && turns > 1 ? 100_000 : 500, accuracy: .exactLocal)
        }
        func generate(system: String, input: String) async throws -> String {
            generations.append(system)
            guard !outputs.isEmpty else { throw MeetingError.message("Unexpected generation") }
            return outputs.removeFirst()
        }
    }

    func testFittingMultilingualMeetingUsesTwoCountsAcrossManyTurns() async throws {
        let texts = ["We approve the proposal.", "Qui envoie le rapport ?", "Yo lo envío mañana.", "Merci, approved."]
        let segments = (0..<16).map { turn("s\($0)", texts[$0 % texts.count]) }
        let provider = Provider([#"{"items":[]}"#])
        _ = try await AnalysisRunner.run(definition: .init(kind: .summary), settings: .init(), session: session,
                                         segments: segments, provider: provider)
        XCTAssertEqual(provider.counts, 2)
        XCTAssertEqual(provider.generations.count, 1)
        // The former algorithm counted framing, binary-searched 16 fitting units,
        // then requested the chosen count again (a cache hit for ChatAnalysisProvider).
        var oldCalls = 2, low = 1
        while low <= segments.count { oldCalls += 1; low = (low + segments.count) / 2 + 1 }
        print("ANALYSIS_FIT old_count_calls=\(oldCalls) new_count_calls=\(provider.counts)")
    }

    func testBoundariesRetainQuestionWithReplyAndPreserveLongWord() {
        let snapshot = AnalysisSnapshot([turn("a", "Approved."), turn("q", "¿Cuándo?"), turn("r", "Le lundi matin."), turn("z", "OK.")])
        XCTAssertEqual(snapshot.boundary(from: 0, fitting: 3), 1)
        let endOfReply = snapshot.units.lastIndex { $0.id == "r" }! + 1
        XCTAssertEqual(snapshot.boundary(from: 0, fitting: endOfReply), endOfReply)
        let long = String(repeating: "🧑🏽‍🔧", count: 100)
        let broken = AnalysisSnapshot([turn("one", long)])
        XCTAssertGreaterThan(broken.units.count, 1)
        XCTAssertEqual(broken.units.map(\.text).joined(), long)
    }

    func testTaskSpecificContractsAndAtomicChanges() throws {
        let compact = #"{"items":[{"text":"Décision","evidenceSegmentIDs":["a"]}]}"#
        for kind in AnalysisKind.allCases {
            let contract = AnalysisContract(kind: kind)
            if kind == .actionItems {
                XCTAssertThrowsError(try contract.applying(compact, to: .init(), current: ["a"], allowed: ["a"]))
            } else {
                XCTAssertEqual(try contract.applying(compact, to: .init(), current: ["a"], allowed: ["a"]).items.count, 1)
                XCTAssertFalse(contract.instructions.contains("dueDateText"))
            }
        }
        let base = FindingLedger(ids: [1, 2], items: [.init(text: "Report", evidenceSegmentIDs: ["a"]), .init(text: "Review", evidenceSegmentIDs: ["a"])], nextID: 3)
        let delta = AnalysisContract(kind: .actionItems, changes: true)
        let valid = #"{"add":[],"revise":[{"id":2,"text":"Review Friday","owner":null,"dueDateText":"Friday","evidenceSegmentIDs":["b"]}],"resolve":[],"withdraw":[{"id":1,"evidenceSegmentIDs":["b"]}]}"#
        let updated = try delta.applying(valid, to: base, current: ["b"], allowed: ["a","b"])
        XCTAssertEqual(updated.ids, [2])
        XCTAssertEqual(updated.items.first?.dueDateText, "Friday")
        XCTAssertEqual(updated.nextID, 3)
        for invalid in [valid.replacingOccurrences(of: #""id":1"#, with: #""id":99"#),
                        valid.replacingOccurrences(of: #""id":1"#, with: #""id":2"#),
                        valid.replacingOccurrences(of: #"["b"]"#, with: #"["a"]"#)] {
            XCTAssertThrowsError(try delta.applying(invalid, to: base, current: ["b"], allowed: ["a","b"]))
            XCTAssertEqual(base.ids, [1, 2])
        }
    }

    func testInterruptedDeltaResumesAndRetainsUntouchedFindings() async throws {
        let segments = [turn("a","Deux choix."), turn("b","Se cancela uno.")]
        let initial = #"{"items":[{"text":"A","evidenceSegmentIDs":["a"]},{"text":"B","evidenceSegmentIDs":["a"]}]}"#
        let withdrawal = #"{"add":[],"revise":[],"resolve":[],"withdraw":[{"id":1,"evidenceSegmentIDs":["b"]}]}"#
        let first = Provider([initial, "{", "{}"], singleTurn: true)
        let definition = AnalysisDefinition(kind: .decisions)
        var checkpoints: [AnalysisCheckpoint] = []
        do {
            _ = try await AnalysisRunner.run(definition: definition, settings: .init(), session: session, segments: segments,
                                             provider: first, saveCheckpoint: { checkpoints.append($0) })
            XCTFail("A second malformed response must fail")
        } catch {
            XCTAssertEqual(checkpoints.count, 1)
            XCTAssertEqual(first.generations.count, 3)
            XCTAssertTrue(first.generations.last?.contains("Correct the response") == true)
        }
        let saved = try meetingDecoder.decode(AnalysisCheckpoint.self, from: meetingEncoder.encode(XCTUnwrap(checkpoints.first)))
        let retry = Provider([withdrawal])
        let result = try await AnalysisRunner.run(definition: definition, settings: .init(), session: session, segments: segments, provider: retry, checkpoint: saved)
        XCTAssertEqual(result.items.map(\.text), ["B"])
        XCTAssertEqual(retry.generations.count, 1)
        let repaired = Provider(["{}", initial])
        let full = try await AnalysisRunner.run(definition: definition, settings: .init(), session: session, segments: [segments[0]], provider: repaired)
        XCTAssertEqual(full.items.count, 2)
        XCTAssertEqual(repaired.counts, 3, "Include repair instructions in the token count")
        var old = saved
        old.formatVersion = nil
        let restart = Provider([initial])
        _ = try await AnalysisRunner.run(definition: definition, settings: .init(), session: session, segments: segments, provider: restart, checkpoint: old)
        XCTAssertFalse(restart.generations[0].contains("changes only"))
    }

    func testOutputSizeForOneChangeAmongTwentyFindings() throws {
        let prior = (1...20).map { AnalysisItem(text: "Follow up on outstanding supplier question \($0)", evidenceSegmentIDs: ["s\($0)"]) }
        let full = try JSONEncoder().encode(AnalysisPayload(items: Array(prior.dropLast())))
        let delta = #"{"add":[],"revise":[],"resolve":[{"id":20,"evidenceSegmentIDs":["answer"]}],"withdraw":[]}"#
        let updated = try AnalysisContract(kind: .openQuestions, changes: true).applying(delta,
            to: .init(ids: Array(1...20), items: prior, nextID: 21), current: ["answer"], allowed: ["answer"])
        XCTAssertEqual(updated.items, Array(prior.dropLast()))
        XCTAssertLessThan(delta.utf8.count, full.count)
        print("ANALYSIS_OUTPUT full_bytes=\(full.count) delta_bytes=\(delta.utf8.count)")
    }
}

extension AnalysisWorkflowTests {
    func testProviderSchemasFollowSelectedKindAndStage() throws {
        for engine in [LLMEngine.builtin, .ollama, .compatible] {
            var settings = AnalysisSettings(); settings.engine = engine; settings.structuredOutput = true
            let provider = ChatAnalysisProvider(settings)
            provider.configureEvidence(["one"])
            for kind in AnalysisKind.allCases {
                for changes in [false, true] {
                    provider.configureContract(.init(kind: kind, changes: changes))
                    let body = provider.requestBody(system: "prompt", input: "source")
                    let format = body["response_format"] as? [String: Any]
                    let descriptor = format?["json_schema"] as? [String: Any]
                    let schema = try XCTUnwrap((body["format"] ?? descriptor?["schema"]) as? [String: Any])
                    let props = try XCTUnwrap(schema["properties"] as? [String: Any])
                    XCTAssertEqual(Set(props.keys), changes ? ["add","revise","resolve","withdraw"] : ["items"])
                    let array = try XCTUnwrap(props[changes ? "add" : "items"] as? [String: Any])
                    let item = try XCTUnwrap(array["items"] as? [String: Any])
                    let fields = Set(try XCTUnwrap(item["required"] as? [String]))
                    XCTAssertEqual(fields, kind == .actionItems ? ["text","evidenceSegmentIDs","owner","dueDateText"] : ["text","evidenceSegmentIDs"])
                }
            }
        }
    }
}

extension MeetingCoreTests {
    func testTranscriptCorrectionDuringGenerationPreservesMarkdown() async throws {
        let (session, store) = try await session()
        var meeting = session
        meeting.segments = [.init(id: "abc", source: .computer, start: 0, end: 1, text: "Tentative launch.")]
        try MarkdownExporter.exportTranscript(meeting, previous: nil)
        let url = meeting.markdownURL
        let edited = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "Tentative launch.", with: "Launch cancelled.")
        final class Editor: AnalysisProvider {
            let edit: () throws -> Void
            init(edit: @escaping () throws -> Void) { self.edit = edit }
            func prepare() async throws {}
            func cancel() {}
            func generate(system: String, input: String) async throws -> String {
                try edit()
                return #"{"items":[{"text":"Tentative launch.","evidenceSegmentIDs":["abc"]}]}"#
            }
        }
        let pipeline = MeetingPipeline(analysisFactory: { _ in Editor { try edited.write(to: url, atomically: true, encoding: .utf8) } })
        do {
            _ = try await pipeline.analyze(meeting, settings: .init(), definitions: [.init(kind: .summary)], store: store, progress: { _ in })
            XCTFail("Cannot publish analysis of a superseded transcript")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Transcript changed")) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), edited)
        let stored = try await store.load()
        XCTAssertNil(stored.first?.analyses[.summary])
    }
}
