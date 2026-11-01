import XCTest
@testable import MeetingCore

final class MeetingSearchTests: XCTestCase {
    func testSearchFilenameContentAccentsAndExternalChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = MeetingSession(folder: folder.path, stem: "20261101 - 120000", speech: .init(), echoReduction: false)
        let second = MeetingSession(folder: folder.path, stem: "20261102 - 130000", speech: .init(), echoReduction: false)
        try "# Résumé\nDécision: reunión española\nPersonal notes: release approved".write(to: first.markdownURL, atomically: true, encoding: .utf8)
        try "# Another meeting".write(to: second.markdownURL, atomically: true, encoding: .utf8)
        for query in ["20261101", "RESUME", "reunion espanola", "20261101 approved"] {
            let result = try await MeetingSearch.search(query, sessions: [first, second])
            XCTAssertEqual(result.ids, [first.id]); XCTAssertEqual(result.unreadableFiles, 0)
        }
        let empty = try await MeetingSearch.search("  ", sessions: [first, second]); XCTAssertEqual(empty.ids.count, 2)
        let absent = try await MeetingSearch.search("unmentioned", sessions: [first, second]); XCTAssertTrue(absent.ids.isEmpty)
        try "Edited externally".write(to: second.markdownURL, atomically: true, encoding: .utf8)
        let changed = try await MeetingSearch.search("externally", sessions: [first, second]); XCTAssertEqual(changed.ids, [second.id])
        try FileManager.default.removeItem(at: second.markdownURL)
        let missing = try await MeetingSearch.search("approved", sessions: [first, second]); XCTAssertEqual(missing.ids, [first.id]); XCTAssertEqual(missing.unreadableFiles, 1)
        let filename = try await MeetingSearch.search("20261102", sessions: [first, second]); XCTAssertEqual(filename.ids, [second.id])
        XCTAssertEqual(try String(contentsOf: first.markdownURL, encoding: .utf8), "# Résumé\nDécision: reunión española\nPersonal notes: release approved")
    }

    @MainActor func testClearReaderDiscardsLoadedDocument() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("meeting.md")
        try "# Meeting".write(to: url, atomically: true, encoding: .utf8)
        let reader = MeetingDocumentReader(); await reader.load(url)
        XCTAssertNotNil(reader.document)
        reader.clear()
        XCTAssertNil(reader.document); XCTAssertNil(reader.error); XCTAssertFalse(reader.isLoading)
    }
}
