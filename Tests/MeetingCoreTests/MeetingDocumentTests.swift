import XCTest
import AppKit
@testable import MeetingCore

final class MeetingDocumentTests: XCTestCase {
    let url = URL(fileURLWithPath: "/tmp/fixture.md")
    let fixture = """
    ---
    started_at: "2026-10-31T09:00:00Z"
    transcription_model: "Parakeet v3"
    ---
    # Réunion — Meeting
    <!-- mnt:summary:start -->
    ## Summary
    <!-- analysis: internal bookkeeping -->
    Résumé **important** avec *précision* et `code`.

    - Point principal
    - [ ] Envoyer le rapport demain
    - [x] Rapport reçu

    3. Troisième point
    4. Fourth point

    > Capture interrompue ; silence préservé.

    | Sujet | État |
    | :--- | ---: |
    | Budget | 3000 € |

    ## Personal Notes
    [Evidence](#segment-mic-1) and [Website](https://example.com).
    ![Schéma](https://example.com/image.png)

    ```swift
    let greeting = "Bonjour"
    <!-- keep this code comment -->
    ```

    <!-- mnt:transcript:start -->
    ## Transcript
    <!-- segment:mic-1|microphone|1.0|3.0|false -->
    <a id="segment-mic-1"></a>
    ### [00:00:01–00:00:03] Me — Microphone

    Je vais envoyer le rapport demain. 👋🏽
    <!-- mnt:transcript:end -->
    """

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mnt-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testRawAndFrontmatterAreUnchangedWhilePreviewHidesInternalMarkers() throws {
        let doc = try MeetingDocument.parse(raw: fixture, url: url)
        XCTAssertEqual(doc.raw, fixture); XCTAssertEqual(doc.rawText.string, fixture)
        XCTAssertEqual(doc.transcriptFingerprint, try MarkdownExporter.transcriptFingerprint(MarkdownExporter.readTranscript(markdown: fixture)))
        XCTAssertNotNil(doc.transcriptFingerprint)
        XCTAssertEqual(doc.frontmatter, "started_at: \"2026-10-31T09:00:00Z\"\ntranscription_model: \"Parakeet v3\"\n")
        let preview = try XCTUnwrap(doc.preview).text.string
        XCTAssertTrue(preview.contains("Résumé important avec précision et code."))
        XCTAssertTrue(preview.contains("Me — Microphone")); XCTAssertTrue(preview.contains("👋🏽"))
        XCTAssertTrue(preview.contains("Personal Notes"))
        XCTAssertFalse(preview.contains("mnt:")); XCTAssertFalse(preview.contains("analysis:")); XCTAssertFalse(preview.contains("<!-- segment:"))
        XCTAssertFalse(preview.contains("transcription_model"))
        XCTAssertTrue(preview.contains("<!-- keep this code comment -->"))
    }
    func testCRLFAndBOMFrontmatterPreserveExactContents() throws {
        let raw = "\u{feff}---\r\nmodel: \"é\"\r\n---\r\n# Titre\r\n"
        let doc = try MeetingDocument.parse(raw: raw, url: url)
        XCTAssertEqual(doc.raw, raw); XCTAssertEqual(doc.frontmatter, "model: \"é\"\r\n")
        XCTAssertTrue(doc.preview!.text.string.contains("Titre"))
        XCTAssertNil(MeetingDocument.splitFrontmatter("---\nmissing terminator").metadata)
        XCTAssertNil(MeetingDocument.splitFrontmatter("Text\n---\nmodel: x\n---").metadata)
    }
    func testFormattingTablesTasksAndAnchorsUseNativeAttributes() throws {
        let doc = try MeetingDocument.parse(raw: fixture, url: url)
        let preview = try XCTUnwrap(doc.preview), text = preview.text.string as NSString
        let strong = text.range(of: "important"), emphasis = text.range(of: "précision")
        XCTAssertTrue((preview.text.attribute(.font, at: strong.location, effectiveRange: nil) as! NSFont).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue((preview.text.attribute(.font, at: emphasis.location, effectiveRange: nil) as! NSFont).fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(text.contains("☐\tEnvoyer")); XCTAssertTrue(text.contains("☑\tRapport")); XCTAssertTrue(text.contains("3.\tTroisième"))
        let budget = text.range(of: "3000 €")
        let style = preview.text.attribute(.paragraphStyle, at: budget.location, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertTrue(style.textBlocks.first is NSTextTableBlock); XCTAssertEqual(style.alignment, .right)
        let range = try XCTUnwrap(preview.anchors["segment-mic-1"])
        XCTAssertTrue(text.substring(with: range).contains("Me — Microphone"))
        XCTAssertFalse(text.substring(with: range).hasPrefix("###"))
        XCTAssertGreaterThan((preview.text.attribute(.font, at: range.location, effectiveRange: nil) as! NSFont).pointSize, NSFont.systemFontSize)
        XCTAssertFalse(text.contains("<a id=")); XCTAssertFalse(text.contains("</a>"))
        XCTAssertEqual(preview.text.attribute(.link, at: text.range(of: "Evidence").location, effectiveRange: nil) as? String, "#segment-mic-1")
    }
    func testHTMLAndImagesNeverCreateExecutableOrRemoteAttachments() throws {
        let rendered = try MeetingMarkdownRenderer.render("![alt text](https://example.com/private.png)\n\n<script>alert('bad')</script>\n\n[unsafe](file:///etc/passwd) [script](javascript:alert(1)) [safe](https://example.com)")
        XCTAssertTrue(rendered.text.string.contains("[Image: alt text]"))
        let text = rendered.text.string as NSString
        XCTAssertNil(rendered.text.attribute(.link, at: text.range(of: "unsafe").location, effectiveRange: nil))
        XCTAssertNil(rendered.text.attribute(.link, at: text.range(of: "script", options: .backwards).location, effectiveRange: nil))
        rendered.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.text.length)) { value, _, _ in XCTAssertNil(value) }
        XCTAssertTrue(rendered.text.string.contains("alert('bad')")) // inert literal text
    }
    func testLoaderCachesUnchangedFileAndReadsExternalEditsWithoutWriting() async throws {
        let file = try directory().appendingPathComponent("meeting.md")
        try fixture.write(to: file, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: file), loader = MeetingDocumentLoader()
        let first = try await loader.load(file), cached = try await loader.load(file)
        XCTAssertTrue(first.preview!.text === cached.preview!.text)
        XCTAssertEqual(try Data(contentsOf: file), before)
        try "# Correction française\n".write(to: file, atomically: true, encoding: .utf8)
        let updated = try await loader.load(file)
        XCTAssertNotEqual(first.fingerprint, updated.fingerprint)
        XCTAssertEqual(updated.raw, "# Correction française\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), updated.raw)
    }
    func testUnreadableOrInvalidUTF8FilesReportFailure() async throws {
        let file = try directory().appendingPathComponent("meeting.md"), loader = MeetingDocumentLoader()
        do { _ = try await loader.load(file); XCTFail("Missing file must fail") } catch {}
        try Data([0xff, 0xfe, 0xff]).write(to: file)
        do { _ = try await loader.load(file); XCTFail("Invalid UTF-8 must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("UTF-8")) }
    }
    @MainActor func testRapidSelectionCannotPublishStaleDocumentOrError() async throws {
        actor Gate {
            var first: CheckedContinuation<MeetingDocument, Error>?
            var started = false
            func wait() async throws -> MeetingDocument { started = true; return try await withCheckedThrowingContinuation { first = $0 } }
            func finish(_ doc: MeetingDocument) { first?.resume(returning: doc); first = nil }
        }
        let firstURL = URL(fileURLWithPath: "/tmp/first.md"), secondURL = URL(fileURLWithPath: "/tmp/second.md")
        let first = try MeetingDocument.parse(raw: "# First", url: firstURL), second = try MeetingDocument.parse(raw: "# Second", url: secondURL)
        let gate = Gate()
        let reader = MeetingDocumentReader(read: { url in url == firstURL ? try await gate.wait() : second })
        let old = Task { await reader.load(firstURL) }
        while !(await gate.started) { await Task.yield() }
        await reader.load(secondURL); XCTAssertEqual(reader.document?.url, secondURL)
        await gate.finish(first); await old.value
        XCTAssertEqual(reader.document?.url, secondURL); XCTAssertNil(reader.error); XCTAssertFalse(reader.isLoading)
    }
    @MainActor func testReadFailureKeepsLastSnapshotOnlyForSameMeeting() async throws {
        let file = try directory().appendingPathComponent("meeting.md")
        try fixture.write(to: file, atomically: true, encoding: .utf8)
        let reader = MeetingDocumentReader()
        await reader.load(file)
        try FileManager.default.removeItem(at: file)
        await reader.load(file)
        XCTAssertEqual(reader.document?.raw, fixture); XCTAssertTrue(reader.error!.contains("last loaded"))
        await reader.load(file.deletingLastPathComponent().appendingPathComponent("other.md"))
        XCTAssertNil(reader.document); XCTAssertNotNil(reader.error)
    }
    func testMalformedMarkdownAndLongTranscriptRemainReadable() throws {
        let malformed = "# Titre\n**unfinished [link(\n\n```\n<unfinished>\n"
        let doc = try MeetingDocument.parse(raw: malformed, url: url)
        XCTAssertEqual(doc.raw, malformed); XCTAssertNotNil(doc.preview)
        let long = (0..<4000).map { "<a id=\"segment-s\($0)\"></a>\n\n### Me — Microphone\n\nÉchéance demain 👨‍👩‍👧‍👦. Turn \($0).\n\n" }.joined()
        let start = Date(), rendered = try MeetingMarkdownRenderer.render(long)
        XCTAssertEqual(rendered.anchors.count, 4000); XCTAssertTrue(rendered.text.string.contains("Turn 3999."))
        print("MARKDOWN_LONG chars=\(long.utf8.count) seconds=\(Date().timeIntervalSince(start))")
    }
    func testRenderingFailureStillReturnsExactRawDocument() throws {
        let raw = String(repeating: "> ", count: 200) + "Deeply nested quote"
        let doc = try MeetingDocument.parse(raw: raw, url: url)
        XCTAssertEqual(doc.rawText.string, raw)
        XCTAssertNil(doc.preview); XCTAssertNotNil(doc.renderingError)
    }
    func testCancelledLoadNeverReturnsAResult() async throws {
        let file = try directory().appendingPathComponent("meeting.md")
        try fixture.write(to: file, atomically: true, encoding: .utf8)
        let task = Task { try await MeetingDocumentLoader().load(file) }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled reads must not publish") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    }
    @MainActor func testNativeViewerIsReadOnlyNavigatesEvidenceAndPreservesPositions() throws {
        _ = NSApplication.shared
        let preview = MeetingDocumentTextView(label: "Preview"), raw = MeetingDocumentTextView(label: "Raw")
        let long = NSAttributedString(string: (0..<300).map { "Line \($0) — français\n" }.joined(), attributes: [.font: NSFont.systemFont(ofSize: 13)])
        preview.display(long, anchors: ["segment-end": NSRange(location: long.length-30, length: 20)], documentID: "one", revision: "1")
        raw.display(long, anchors: [:], documentID: "one", revision: "1")
        XCTAssertFalse(preview.textView.isEditable); XCTAssertTrue(preview.textView.isSelectable)
        preview.contentView.scroll(to: NSPoint(x: 0, y: 500)); raw.contentView.scroll(to: NSPoint(x: 0, y: 200))
        let previewPosition = preview.contentView.bounds.origin.y, rawPosition = raw.contentView.bounds.origin.y
        XCTAssertGreaterThan(previewPosition, 0); XCTAssertNotEqual(previewPosition, rawPosition)
        preview.display(long, anchors: ["segment-end": NSRange(location: long.length-30, length: 20)], documentID: "one", revision: "2")
        XCTAssertEqual(preview.contentView.bounds.origin.y, previewPosition, accuracy: 1)
        XCTAssertEqual(raw.contentView.bounds.origin.y, rawPosition, accuracy: 1)
        var opened: [URL] = []; preview.openWebLink = { opened.append($0) }
        XCTAssertTrue(preview.textView(preview.textView, clickedOnLink: "#segment-end", at: 0))
        XCTAssertEqual(preview.textView.selectedRange().location, long.length-30)
        XCTAssertTrue(opened.isEmpty)
        _ = preview.textView(preview.textView, clickedOnLink: "file:///tmp/secret", at: 0)
        XCTAssertTrue(opened.isEmpty)
        _ = preview.textView(preview.textView, clickedOnLink: "https://example.com", at: 0)
        XCTAssertEqual(opened.count, 1)
        preview.display(long, anchors: [:], documentID: "two", revision: "1")
        XCTAssertEqual(preview.contentView.bounds.origin.y, 0, accuracy: 1)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] { preview.appearance = NSAppearance(named: appearance); preview.layoutSubtreeIfNeeded(); XCTAssertEqual(preview.textView.string, long.string) }
    }
}
