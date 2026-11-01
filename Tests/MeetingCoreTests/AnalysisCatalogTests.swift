import XCTest
@testable import MeetingCore

final class AnalysisCatalogTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mnt-catalog-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private let fixture = Data("GGUF-test-model-payload".utf8)
    private func fixtureEntry(_ url: URL) throws -> AnalysisCatalogEntry {
        .init(id: "fixture", title: "Fixture", detail: "Test only", repository: "test/model", filename: "fixture.gguf", revision: String(repeating: "a", count: 40), sha256: try audioFingerprint(url), bytes: Int64(fixture.count), quantization: "Q4_K_M", preset: .init(disableThinking: true, temperature: 0.1), runtimeVerified: false)
    }
    func testCatalogPinsOnlyIntendedTextWeights() {
        XCTAssertEqual(AnalysisModelCatalog.entries.count, 5)
        XCTAssertEqual(Set(AnalysisModelCatalog.entries.map(\.id)).count, 5)
        XCTAssertEqual(AnalysisModelCatalog.entries.filter(\.balanced).map(\.id), ["qwen35-9b-q4km"])
        for entry in AnalysisModelCatalog.entries {
            XCTAssertEqual(entry.revision.count, 40); XCTAssertEqual(entry.sha256.count, 64)
            XCTAssertTrue(entry.downloadURL.path.contains("/resolve/\(entry.revision)/"))
            XCTAssertFalse(entry.filename.contains("mmproj")); XCTAssertFalse(entry.filename.contains("mtp"))
            XCTAssertEqual(entry.license, "Apache-2.0")
            XCTAssertGreaterThan(entry.bytes, 2_000_000_000)
        }
    }
    func testPublisherRevisionSizeAndChecksumMustMatch() throws {
        let entry = AnalysisModelCatalog.entries[0]
        func manifest(revision: String, size: Int64, hash: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["sha": revision, "siblings": [["rfilename": entry.filename, "size": size, "lfs": ["sha256": hash, "size": size]]]])
        }
        XCTAssertNoThrow(try ModelManager.validatePublisherManifest(manifest(revision: entry.revision, size: entry.bytes, hash: entry.sha256), entry: entry))
        XCTAssertThrowsError(try ModelManager.validatePublisherManifest(manifest(revision: "main", size: entry.bytes, hash: entry.sha256), entry: entry))
        XCTAssertThrowsError(try ModelManager.validatePublisherManifest(manifest(revision: entry.revision, size: entry.bytes - 1, hash: entry.sha256), entry: entry))
        XCTAssertThrowsError(try ModelManager.validatePublisherManifest(manifest(revision: entry.revision, size: entry.bytes, hash: String(repeating: "0", count: 64)), entry: entry))
    }
    func testCorruptionTruncationCancellationAndDiskSpace() async throws {
        let root = try directory(); let file = root.appendingPathComponent(".download.partial")
        try fixture.write(to: file); let entry = try fixtureEntry(file)
        XCTAssertNoThrow(try ModelManager.verifyGGUF(file, entry: entry))
        var corrupt = fixture; corrupt[corrupt.count - 1] ^= 1; try corrupt.write(to: file)
        XCTAssertThrowsError(try ModelManager.verifyGGUF(file, entry: entry))
        try Data("GGUF".utf8).write(to: file)
        XCTAssertThrowsError(try ModelManager.verifyGGUF(file, entry: entry))
        try fixture.write(to: file)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try ModelManager.verifyGGUF(file, entry: entry)
        }
        do { try await task.value; XCTFail("Cancelled verification must fail") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertThrowsError(try ModelManager.checkDownloadSpace(folder: root, bytes: 1000, availableBytes: 999))
        XCTAssertNoThrow(try ModelManager.checkDownloadSpace(folder: root, bytes: 1000, availableBytes: 1024 * 1024 * 1024))
    }
    func testPartialFilesStayHiddenAndImportsArePreserved() async throws {
        let root = try directory(); let manager = try ModelManager(root: root.appendingPathComponent("managed"))
        let folder = root.appendingPathComponent("managed/gguf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try fixture.write(to: folder.appendingPathComponent(".download.partial"))
        let before = try await manager.installed(); XCTAssertTrue(before.isEmpty)
        let original = root.appendingPathComponent("original.gguf"); try fixture.write(to: original)
        let imported = try await manager.importModel(original, kind: .gguf)
        let installed = try await manager.installed(); XCTAssertEqual(installed.count, 1); XCTAssertNil(installed[0].catalogID)
        XCTAssertEqual(try Data(contentsOf: original), fixture)
        try await manager.remove(imported)
        XCTAssertEqual(try Data(contentsOf: original), fixture)
    }
    func testCommitDoesNotOverwriteAndRollsBackReceiptFailure() throws {
        let root = try directory(); let source = root.appendingPathComponent(".download.partial")
        let destination = root.appendingPathComponent("fixture.gguf")
        try fixture.write(to: source); let entry = try fixtureEntry(source)
        try Data("existing import".utf8).write(to: destination)
        XCTAssertThrowsError(try ModelManager.commitVerifiedGGUF(source, destination: destination, entry: entry))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing import")
        try FileManager.default.removeItem(at: destination)
        let receipt = ModelManager.receiptURL(for: destination)
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ModelManager.commitVerifiedGGUF(source, destination: destination, entry: entry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.removeItem(at: receipt)
        try fixture.write(to: source)
        try ModelManager.commitVerifiedGGUF(source, destination: destination, entry: entry)
        let saved = try JSONDecoder().decode(CatalogInstallReceipt.self, from: Data(contentsOf: receipt))
        XCTAssertEqual(saved.model, entry.identity); XCTAssertEqual(saved.bytes, entry.bytes)
        XCTAssertEqual(try Data(contentsOf: destination), fixture)
    }
    func testCatalogPresetAndIdentitySurviveSnapshotWithoutChangingBehavior() throws {
        var settings = AnalysisSettings(); settings.language = "French"; settings.automatic = true; settings.contextTokens = 16384
        let entry = AnalysisModelCatalog.entries[1]
        let selected = entry.configuring(settings, path: "/models/model.gguf", resetBudgets: true)
        XCTAssertEqual(settings.engine, .unconfigured)
        XCTAssertEqual(selected.language, "French"); XCTAssertTrue(selected.automatic)
        XCTAssertEqual(selected.contextTokens, 8192); XCTAssertEqual(selected.outputTokens, 1536)
        let snapshot = try JSONDecoder().decode(AnalysisSettings.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(snapshot.catalogModel, entry.identity); XCTAssertEqual(snapshot.inferencePreset, entry.preset)
        XCTAssertEqual(entry.configuring(settings, path: "/models/model.gguf", resetBudgets: false).contextTokens, 16384)
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as? [String: Any])
        oldJSON.removeValue(forKey: "catalogModel"); oldJSON.removeValue(forKey: "inferencePreset")
        let old = try JSONDecoder().decode(AnalysisSettings.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertNil(old.catalogModel); XCTAssertNil(old.inferencePreset); XCTAssertEqual(old.language, "French")
    }
}

extension AnalysisCatalogTests {
    func testPinnedDownloadInstallsAtomicallyAndRetryRecoversFromHTTPFailure() async throws {
        let root = try directory(); let source = root.appendingPathComponent("source.gguf"); try fixture.write(to: source)
        let entry = try fixtureEntry(source)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogDownloadProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        CatalogDownloadProtocol.configure(entry: entry, data: fixture, fail: true)
        let manager = try ModelManager(root: root.appendingPathComponent("managed"))
        do {
            _ = try await manager.downloadGGUF(entry: entry, progress: { _ in }, status: { _ in }, metadataSession: session, downloadConfiguration: config)
            XCTFail("HTTP failure should not install")
        } catch {}
        let failed = try await manager.installed(); XCTAssertTrue(failed.isEmpty)
        let folder = root.appendingPathComponent("managed/gguf")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains(where: { $0.hasSuffix(".partial") }))
        CatalogDownloadProtocol.configure(entry: entry, data: fixture, fail: false)
        let downloaded = try await manager.downloadGGUF(entry: entry, progress: { _ in }, status: { _ in }, metadataSession: session, downloadConfiguration: config)
        XCTAssertEqual(try Data(contentsOf: downloaded), fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ModelManager.receiptURL(for: downloaded).path))
    }
    func testMidDownloadCancellationCleansUpAndAllowsRetry() async throws {
        let root = try directory(); let original = root.appendingPathComponent("original.gguf"); try fixture.write(to: original)
        let entry = try fixtureEntry(original); let manager = try ModelManager(root: root.appendingPathComponent("managed"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogDownloadProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        CatalogDownloadProtocol.configure(entry: entry, data: fixture, fail: false, hold: true)
        let download = Task { try await manager.downloadGGUF(entry: entry, progress: { _ in }, status: { _ in }, metadataSession: session, downloadConfiguration: config) }
        for _ in 0..<100 {
            if CatalogDownloadProtocol.downloadStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(CatalogDownloadProtocol.downloadStarted); download.cancel()
        do { _ = try await download.value; XCTFail("A cancelled download must fail") } catch {}
        let installed = try await manager.installed(); XCTAssertTrue(installed.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("managed/gguf").path).contains(where: { $0.hasSuffix(".partial") }))
        CatalogDownloadProtocol.configure(entry: entry, data: fixture, fail: false)
        let retried = try await manager.downloadGGUF(entry: entry, progress: { _ in }, status: { _ in }, metadataSession: session, downloadConfiguration: config)
        XCTAssertEqual(try Data(contentsOf: retried), fixture)
    }
    func testCatalogReceiptIdentityAndModificationDetection() async throws {
        let root = try directory(); let manager = try ModelManager(root: root)
        let folder = root.appendingPathComponent("gguf"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = AnalysisModelCatalog.entries[0]; let url = folder.appendingPathComponent(entry.filename)
        try fixture.write(to: url)
        // Sparse metadata fixture: consumes only its header block, not gigabytes of disk.
        let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: UInt64(entry.bytes)); try handle.close()
        let before = await manager.catalogEntry(at: url); XCTAssertNil(before, "A matching filename is not proof of catalog origin")
        let modified = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let receipt = CatalogInstallReceipt(model: entry.identity, bytes: entry.bytes, modified: modified)
        try JSONEncoder().encode(receipt).write(to: ModelManager.receiptURL(for: url))
        let identified = await manager.catalogEntry(at: url); XCTAssertEqual(identified?.id, entry.id)
        try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(10)], ofItemAtPath: url.path)
        let modifiedEntry = await manager.catalogEntry(at: url); XCTAssertNil(modifiedEntry)
        try await manager.remove(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelManager.receiptURL(for: url).path))
    }
}

private final class CatalogDownloadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var entry: AnalysisCatalogEntry?
    private static var payload = Data()
    private static var fail = false
    private static var hold = false
    private static var started = false
    static var downloadStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    static func configure(entry: AnalysisCatalogEntry, data: Data, fail: Bool, hold: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.entry = entry; payload = data; self.fail = fail; self.hold = hold; started = false
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "huggingface.co" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let entry = Self.entry!; let payload = Self.payload; let fail = Self.fail; let hold = Self.hold; Self.lock.unlock()
        let metadata = request.url!.path.contains("/api/models/")
        let body: Data
        if metadata {
            XCTAssertTrue(request.url!.path.contains(entry.revision))
            body = try! JSONSerialization.data(withJSONObject: ["sha": entry.revision, "siblings": [["rfilename": entry.filename, "size": entry.bytes, "lfs": ["sha256": entry.sha256, "size": entry.bytes]]]])
        } else { XCTAssertEqual(request.url, entry.downloadURL); body = payload }
        let status = !metadata && fail ? 403 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(body.count)])!, cacheStoragePolicy: .notAllowed)
        if !metadata && hold {
            Self.lock.lock(); Self.started = true; Self.lock.unlock()
            return
        }
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
