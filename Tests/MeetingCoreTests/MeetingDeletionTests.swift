import XCTest
@testable import MeetingCore

final class MeetingDeletionTests: XCTestCase {
    private func fixture() async throws -> (SessionStore, MeetingSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root.appendingPathComponent("history"))
        var settings = AppSettings(); settings.outputFolder = root.appendingPathComponent("meetings").path
        let session = try await store.reserve(settings: settings)
        try Data("recoverable chunks".utf8).write(to: session.stagingURL.appendingPathComponent("microphone.packets"))
        return (store, session, root)
    }

    func testTrashAllOwnedItemsHistoryLastAndRejectLateSave() async throws {
        for status in [SessionStatus.complete, .failed, .interrupted] {
            let (store, original, root) = try await fixture()
            var session = original; session.status = status; try await store.save(session)
            let unrelated = session.markdownURL.deletingLastPathComponent().appendingPathComponent("notes.md")
            try Data("keep".utf8).write(to: unrelated)
            let trash = root.appendingPathComponent("trash"); try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            var moved: [String] = []
            try await store.trashMeeting(session.id) { url in
                moved.append(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
            }
            XCTAssertEqual(moved, [session.stem + ".md", session.stem + ".m4a", session.stagingURL.lastPathComponent, session.id.uuidString + ".json"])
            let records = try await store.load(); XCTAssertTrue(records.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent(session.stagingURL.lastPathComponent).appendingPathComponent("microphone.packets").path))
            do { try await store.save(original); XCTFail("Late save must not recreate deleted history") } catch { }
        }
    }

    func testPartialFailurePersistsAcrossRestartAndRetrySkipsMissingFiles() async throws {
        let (store, session, root) = try await fixture()
        let trash = root.appendingPathComponent("trash"); try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        do {
            try await store.trashMeeting(session.id) { url in
                if url == session.audioURL { throw MeetingError.message("Trash unavailable") }
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
            }
            XCTFail("Expected failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Retry deletion")) }
        let restarted = try SessionStore(root: root.appendingPathComponent("history"))
        let pending = try await restarted.load()[0]
        XCTAssertNotNil(pending.deletionRequestedAt); XCTAssertEqual(pending.queuedForProcessing, false)
        do { try await restarted.save(session); XCTFail("Stale writer must not clear pending deletion") } catch { }
        let cleanupErrors = try await restarted.cleanup(policy: .afterSuccessfulTranscription)
        XCTAssertTrue(cleanupErrors.isEmpty)
        var moved: [URL] = []
        try await restarted.trashMeeting(session.id) { url in
            moved.append(url); try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        XCTAssertFalse(moved.contains(session.markdownURL)); XCTAssertEqual(moved.count, 3)
    }

    func testUnavailableFolderPreservesRecordAndDoesNotTrashAnything() async throws {
        let (store, session, root) = try await fixture()
        try FileManager.default.moveItem(at: URL(fileURLWithPath: session.folder), to: root.appendingPathComponent("offline"))
        do { try await store.trashMeeting(session.id) { _ in XCTFail("Unavailable folder must abort") }; XCTFail("Expected failure") } catch { }
        let pending = try await store.load()[0]; XCTAssertNotNil(pending.deletionRequestedAt)
    }

    func testAlreadyDeletedAudioAndMissingStagingAreAllowed() async throws {
        let (store, original, _) = try await fixture()
        var session = original; session.audioDeleted = true; try await store.save(session)
        try FileManager.default.removeItem(at: session.audioURL)
        try FileManager.default.removeItem(at: session.stagingURL)
        var moved: [URL] = []
        try await store.trashMeeting(session.id) { url in moved.append(url); try FileManager.default.removeItem(at: url) }
        XCTAssertEqual(moved.count, 2)
    }

    func testSymlinksAndTraversalAreRejectedBeforeMovingFiles() async throws {
        let (store, original, root) = try await fixture()
        let outside = root.appendingPathComponent("outside.md"); try Data("keep".utf8).write(to: outside)
        try FileManager.default.removeItem(at: original.markdownURL)
        try FileManager.default.createSymbolicLink(at: original.markdownURL, withDestinationURL: outside)
        do { try await store.trashMeeting(original.id) { _ in XCTFail("Unsafe paths must abort") }; XCTFail("Expected failure") } catch { }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        let (secondStore, original2, _) = try await fixture()
        var invalid = original2; invalid.stem = "../outside"; try await secondStore.save(invalid)
        do { try await secondStore.trashMeeting(invalid.id) { _ in XCTFail("Traversal must abort") }; XCTFail("Expected failure") } catch { }
    }

    func testLegacyRecordHasNoDeletionMarker() throws {
        let session = MeetingSession(folder: "/tmp", stem: "legacy", speech: .init(), echoReduction: false)
        var json = try JSONSerialization.jsonObject(with: meetingEncoder.encode(session)) as! [String: Any]
        json.removeValue(forKey: "deletionRequestedAt")
        let loaded = try meetingDecoder.decode(MeetingSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(loaded.deletionRequestedAt)
    }
}
