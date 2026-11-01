import Foundation

public struct MeetingSearchResult: Sendable {
    public let ids: Set<UUID>
    public let unreadableFiles: Int
}

public enum MeetingSearch {
    /// Scan saved Markdown off the UI thread. No persistent index or external service.
    public static func search(_ query: String, sessions: [MeetingSession]) async throws -> MeetingSearchResult {
        let task = Task.detached(priority: .utility) {
            let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var ids: Set<UUID> = []; var unreadable = 0
            func matches(_ text: String) -> Bool {
                terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            for session in sessions {
                try Task.checkCancellation()
                let metadata = session.stem + " " + (session.tags ?? []).joined(separator: " ") + " " + (session.metadataProfile?.name ?? "")
                if matches(metadata) { ids.insert(session.id); continue }
                do {
                    let text = try String(contentsOf: session.markdownURL, encoding: .utf8)
                    if matches(metadata + "\n" + text) { ids.insert(session.id) }
                } catch { unreadable += 1 }
            }
            try Task.checkCancellation()
            return MeetingSearchResult(ids: ids, unreadableFiles: unreadable)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
