import Foundation
import CryptoKit

extension ModelManager {
    static func receiptURL(for url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).catalog.json") }

    public func catalogEntry(at url: URL) -> AnalysisCatalogEntry? {
        guard url.deletingLastPathComponent().standardizedFileURL.path == root.appendingPathComponent("gguf").standardizedFileURL.path,
              let data = try? Data(contentsOf: Self.receiptURL(for: url)),
              let receipt = try? JSONDecoder().decode(CatalogInstallReceipt.self, from: data),
              let entry = AnalysisModelCatalog.entry(receipt.model.id), entry.identity == receipt.model,
              entry.filename == url.lastPathComponent,
              let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              (values[.size] as? NSNumber)?.int64Value == receipt.bytes, receipt.bytes == entry.bytes,
              values[.modificationDate] as? Date == receipt.modified else { return nil }
        return entry
    }

    /// Uses release-pinned publisher revisions. Nothing is activated by this operation.
    public func downloadGGUF(id: String, progress: @escaping @Sendable (Double) -> Void, status: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard let entry = AnalysisModelCatalog.entry(id) else { throw MeetingError.message("Unknown analysis model.") }
        return try await downloadGGUF(entry: entry, progress: progress, status: status)
    }

    func downloadGGUF(entry: AnalysisCatalogEntry, progress: @escaping @Sendable (Double) -> Void, status: @escaping @Sendable (String) -> Void, metadataSession: URLSession = .shared, downloadConfiguration: URLSessionConfiguration = .default) async throws -> URL {
        let folder = root.appendingPathComponent("gguf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(entry.filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard catalogEntry(at: destination)?.identity == entry.identity else { throw MeetingError.message("A model with this filename already exists. Import or use that file, or remove the app’s copy before downloading this catalog model.") }
            status("Verifying installed model…")
            try Self.verifyGGUF(destination, entry: entry)
            return destination
        }
        let temporary = folder.appendingPathComponent(".\(entry.id).partial")
        // Reclaim only this catalog job’s hidden partial before checking retry space.
        try? FileManager.default.removeItem(at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.checkDownloadSpace(folder: folder, bytes: entry.bytes)
        status("Checking publisher metadata…")
        let manifestURL = URL(string: "https://huggingface.co/api/models/\(entry.repository)/revision/\(entry.revision)?blobs=true")!
        let data = try await HTTPClient.send(URLRequest(url: manifestURL), session: metadataSession)
        try Self.validatePublisherManifest(data, entry: entry)
        status("Downloading \(entry.title)…")
        try await ModelDownload(progress: progress, configuration: downloadConfiguration).download(entry.downloadURL, to: temporary)
        try Task.checkCancellation()
        status("Verifying size and SHA-256…")
        try Self.verifyGGUF(temporary, entry: entry)
        try Task.checkCancellation()
        try Self.commitVerifiedGGUF(temporary, destination: destination, entry: entry)
        return destination
    }

    static func validatePublisherManifest(_ data: Data, entry: AnalysisCatalogEntry) throws {
        struct Manifest: Decodable {
            struct File: Decodable { struct LFS: Decodable { var sha256: String; var size: Int64 }; var rfilename: String; var size: Int64?; var lfs: LFS? }
            var sha: String; var siblings: [File]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.sha == entry.revision,
              let file = manifest.siblings.first(where: { $0.rfilename == entry.filename }),
              file.lfs?.sha256 == entry.sha256, file.lfs?.size == entry.bytes,
              file.size == nil || file.size == entry.bytes else {
            throw MeetingError.message("Publisher metadata does not match the pinned model. The download was not installed.")
        }
    }
    static func checkDownloadSpace(folder: URL, bytes: Int64, availableBytes: Int64? = nil) throws {
        let available = try availableBytes ?? (FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        // Keep headroom for the app, logs, and an atomic receipt; a GGUF is streamed to disk.
        let required = bytes + 512 * 1024 * 1024
        guard available >= required else { throw MeetingError.message("Not enough disk space. Free at least \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) for this download, including working space.") }
    }
    static func verifyGGUF(_ url: URL, entry: AnalysisCatalogEntry) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular, (values[.size] as? NSNumber)?.int64Value == entry.bytes else { throw MeetingError.message("The model download has the wrong size. Retry the download.") }
        try validateFile(url, kind: .gguf)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty { try Task.checkCancellation(); hash.update(data: block) }
        let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == entry.sha256 else { throw MeetingError.message("Model checksum verification failed. Retry the download.") }
    }
    /// Caller verifies the source first; never replaces an existing installed or imported model.
    static func commitVerifiedGGUF(_ source: URL, destination: URL, entry: AnalysisCatalogEntry) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MeetingError.message("A model with this filename is already installed.") }
        let modified = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date ?? Date()
        let receipt = CatalogInstallReceipt(model: entry.identity, bytes: entry.bytes, modified: modified)
        try FileManager.default.moveItem(at: source, to: destination)
        do { try JSONEncoder().encode(receipt).write(to: receiptURL(for: destination), options: .atomic) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}
