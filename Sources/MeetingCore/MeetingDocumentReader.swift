import Foundation
import Combine

/// UI-facing load ownership is separate from the background cache. A slow read
/// for an earlier meeting cannot publish over the currently selected document.
@MainActor public final class MeetingDocumentReader: ObservableObject {
    @Published public private(set) var document: MeetingDocument?
    @Published public private(set) var error: String?
    @Published public private(set) var isLoading = false
    private var selectedURL: URL?
    private var requestID = UUID()
    private let read: @Sendable (URL) async throws -> MeetingDocument

    public init(loader: MeetingDocumentLoader = MeetingDocumentLoader()) {
        read = { try await loader.load($0) }
    }
    init(read: @escaping @Sendable (URL) async throws -> MeetingDocument) { self.read = read }

    public func clear() {
        requestID = UUID(); selectedURL = nil; document = nil; error = nil; isLoading = false
    }

    public func load(_ url: URL) async {
        let id = UUID(); requestID = id
        if selectedURL != url { document = nil; selectedURL = url; error = nil }
        isLoading = true
        defer { if requestID == id { isLoading = false } }
        do {
            let next = try await read(url)
            try Task.checkCancellation()
            guard requestID == id else { return }
            if document?.fingerprint != next.fingerprint || document?.url != next.url { document = next }
            error = nil
        } catch is CancellationError { }
        catch {
            guard requestID == id, !Task.isCancelled else { return }
            self.error = "Cannot read the Markdown file: \(error.localizedDescription)" + (document == nil ? "" : " Showing the last loaded version.")
        }
    }
}
