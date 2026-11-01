import Foundation
import FluidAudio
import Speech

public enum ModelKind: String, CaseIterable, Identifiable { case whisper, parakeet, gguf; public var id: String { rawValue } }
public struct InstalledModel: Identifiable { public var id: String { url.path }; public var url: URL; public var bytes: Int64; public var kind: ModelKind; public var catalogID: String? = nil }
public actor ModelManager {
    public let root: URL
    public init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    public static func validateFile(_ url: URL, kind: ModelKind) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MeetingError.message("Choose an installed model file first.") }
        if kind == .parakeet {
            _ = try parakeetVersion(at: url)
        } else {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let magic = try file.read(upToCount: 4) ?? Data()
            guard magic.count == 4 else { throw MeetingError.message("Model file is too short.") }
            let value = magic.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard kind == .gguf ? magic == Data("GGUF".utf8) : value == 0x67676d6c else { throw MeetingError.message("This file is not a compatible \(kind.rawValue) model.") }
        }
    }
    /// Inspect the model components, not the directory name: imported folders can be renamed.
    public static func parakeetVersion(at directory: URL) throws -> String {
        let variants: [(String, Set<String>)] = [("v2", ModelNames.ASR.requiredModels), ("v3", ModelNames.ASR.requiredModelsV3())]
        let matches = variants.filter { _, files in
            files.union([ModelNames.ASR.vocabularyFile]).allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
        guard matches.count == 1, let version = matches.first?.0 else {
            throw MeetingError.message("Select one complete Parakeet Ultra, v3, or v2 Core ML directory, including its vocabulary and all compiled model components. Incomplete or mixed model folders cannot be loaded.")
        }
        let configURL = directory.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: configURL.path) {
            struct Metadata: Decodable { var base_model: String? }
            let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: configURL))
            if metadata.base_model == "moondream/parakeet-ultra" {
                guard version == "v3" else { throw MeetingError.message("Parakeet Ultra metadata does not match its model components.") }
                return "ultra"
            }
        }
        return version
    }
    public static func parakeetRuntimeVersion(_ version: String) throws -> AsrModelVersion {
        switch version {
        case "v2": return .v2
        case "v3": return .v3
        case "ultra": return .ultra
        default: throw MeetingError.message("Unsupported Parakeet model version.")
        }
    }
    public static func parakeetFolderName(_ version: String) -> String {
        guard let value = try? parakeetRuntimeVersion(version) else { return "" }
        return AsrModels.defaultCacheDirectory(for: value).lastPathComponent
    }
    public static func sameLocation(_ path: String, _ url: URL) -> Bool {
        !path.isEmpty && URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    public func installed() throws -> [InstalledModel] {
        var result: [InstalledModel] = []
        for kind in ModelKind.allCases {
            let folder = root.appendingPathComponent(kind.rawValue)
            guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else { continue }
            for url in contents where url.pathExtension != "partial" {
                guard (try? Self.validateFile(url, kind: kind)) != nil else { continue }
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
                var bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if let enumerator { bytes = 0; for case let child as URL in enumerator { bytes += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
                result.append(.init(url: url, bytes: bytes, kind: kind, catalogID: kind == .gguf ? catalogEntry(at: url)?.id : nil))
            }
        }
        return result
    }
    public func importModel(_ url: URL, kind: ModelKind) throws -> URL {
        try Self.validateFile(url, kind: kind)
        let folder = root.appendingPathComponent(kind.rawValue); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MeetingError.message("A model with this name is already installed.") }
        let temp = folder.appendingPathComponent(".import-\(UUID())")
        do { try FileManager.default.copyItem(at: url, to: temp); try Self.validateFile(temp, kind: kind); try Task.checkCancellation(); try FileManager.default.moveItem(at: temp, to: destination) }
        catch { try? FileManager.default.removeItem(at: temp); throw error }
        return destination
    }
    public func downloadWhisper(name: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let allowed = ["large-v3-turbo", "large-v3-turbo-q5_0", "large-v3", "medium", "small"]
        guard allowed.contains(name) else { throw MeetingError.message("Unknown Whisper model.") }
        let folder = root.appendingPathComponent("whisper"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("ggml-\(name).bin")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return dest }
        // Resolve one immutable model revision and verify its published LFS SHA-256.
        let manifestURL = URL(string: "https://huggingface.co/api/models/ggerganov/whisper.cpp?blobs=true")!
        let data = try await HTTPClient.send(URLRequest(url: manifestURL))
        struct Manifest: Decodable {
            struct File: Decodable { struct LFS: Decodable { var sha256: String }; var rfilename: String; var lfs: LFS? }
            var sha: String; var siblings: [File]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard let expected = manifest.siblings.first(where: { $0.rfilename == dest.lastPathComponent })?.lfs?.sha256, expected.count == 64 else { throw MeetingError.message("Model publisher did not provide a verification checksum.") }
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(manifest.sha)/\(dest.lastPathComponent)")!
        let temp = folder.appendingPathComponent(".\(UUID()).partial")
        let downloader = ModelDownload(progress: progress)
        try await downloader.download(url, to: temp)
        do {
            try Task.checkCancellation()
            try Self.validateFile(temp, kind: .whisper)
            guard try audioFingerprint(temp) == expected else { throw MeetingError.message("Model checksum verification failed. Retry the download.") }
            try FileManager.default.moveItem(at: temp, to: dest)
        } catch { try? FileManager.default.removeItem(at: temp); throw error }
        return dest
    }
    public func downloadParakeet(version: String, progress: @escaping @Sendable (Double) -> Void, status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        let v = try Self.parakeetRuntimeVersion(version)
        let folder = root.appendingPathComponent("parakeet").appendingPathComponent(AsrModels.defaultCacheDirectory(for: v).lastPathComponent)
        status("Downloading Parakeet \(version)…")
        let url = try await AsrModels.download(to: folder, version: v, progressHandler: { p in progress(p.fractionCompleted) })
        try Task.checkCancellation()
        status("Validating Parakeet \(version)…")
        guard try Self.parakeetVersion(at: url) == version else { throw MeetingError.message("The downloaded Parakeet variant could not be verified. Ultra requires its publisher's config.json file.") }
        _ = try AsrModels.loadLocal(from: url, version: v)
        try Task.checkCancellation()
        return url
    }
    public func remove(_ url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"), url.pathComponents.count == root.pathComponents.count + 2 else { throw MeetingError.message("Only app-managed models can be removed.") }
        try FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: Self.receiptURL(for: url))
    }
    public static func appleLocales() async -> [String] {
        if SpeechTranscriber.isAvailable {
            return await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
        }
        return []
    }
    public static func installedAppleLocales() async -> [String] {
        if SpeechTranscriber.isAvailable { return await SpeechTranscriber.installedLocales.map(\.identifier).sorted() }
        return []
    }
    public static func whisperIsMultilingual(_ path: String) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return true }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 8), data.count == 8 else { return true }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) } >= 51865
    }
    public static func installApple(locale: String) async throws {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else { throw MeetingError.message("Apple Speech is unavailable for this locale or Mac.") }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
    }
}
final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let progress: @Sendable (Double) -> Void
    let configuration: URLSessionConfiguration
    var continuation: CheckedContinuation<Void, Error>?
    var destination: URL?
    var task: URLSessionDownloadTask?
    var session: URLSession?
    init(progress: @escaping @Sendable (Double) -> Void, configuration: URLSessionConfiguration = .default) { self.progress = progress; self.configuration = configuration }
    func download(_ url: URL, to destination: URL) async throws {
        self.destination = destination
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil); self.session = session
                let download = session.downloadTask(with: url); task = download
                lock.unlock(); download.resume()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock(); task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten)/Double(totalBytesExpectedToWrite)) } }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else { throw MeetingError.message("Model download failed.") }
            if downloadTask.countOfBytesExpectedToReceive > 0, downloadTask.countOfBytesReceived != downloadTask.countOfBytesExpectedToReceive { throw MeetingError.message("Incomplete model download.") }
            try FileManager.default.moveItem(at: location, to: destination!)
            continuation?.resume(); continuation = nil
        } catch { continuation?.resume(throwing: error); continuation = nil }
        session.finishTasksAndInvalidate(); self.session = nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { continuation?.resume(throwing: error); continuation = nil; session.invalidateAndCancel(); self.session = nil } }
}
