import Foundation

/// A cursor indexes immutable fragments. Every request reconstructs the original text,
/// including whitespace, and retains the evidence ID when a turn spans two requests.
struct AnalysisSnapshot {
    struct Unit {
        let id: String
        let prefix: String
        let text: String
        var boundary: Int // 0 inside a word, 1 word, 2 sentence, 3 turn, 4 Q&A pair
        var line: String { prefix + text + "\n" }
    }
    let units: [Unit]
    let lookup: [String: TranscriptSegment]
    let fingerprint: String

    init(_ segments: [TranscriptSegment]) {
        fingerprint = MarkdownExporter.transcriptFingerprint(segments)
        lookup = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Unit] = []
        for (index, segment) in segments.enumerated() where !segment.text.isEmpty {
            let prefix = "[segment \(segment.id)] [\(MarkdownExporter.time(segment.start))–\(MarkdownExporter.time(segment.end))] \(segment.source.label): "
            var word = "", bytes = 0
            var sentenceEnd = false
            func flush(_ rank: Int) {
                guard !word.isEmpty else { return }
                result.append(Unit(id: segment.id, prefix: prefix, text: word, boundary: rank))
                word = ""; bytes = 0; sentenceEnd = false
            }
            for character in segment.text {
                if word.last?.isWhitespace == true && !character.isWhitespace { flush(sentenceEnd ? 2 : 1) }
                let size = character.utf8.count
                if bytes + size > 256 { flush(0) }
                word.append(character); bytes += size
                if ".!?。！？".contains(character) { sentenceEnd = true }
                else if !character.isWhitespace && !"”’»\")".contains(character) { sentenceEnd = false }
            }
            flush(1)
            let question = segment.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            let previousQuestion = index > 0 && segments[index - 1].text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            // Prefer ending after the reply, or before the question when both won't fit.
            result[result.count - 1].boundary = question && index + 1 < segments.count ? 2 : (previousQuestion ? 4 : 3)
        }
        units = result
    }

    func text(_ range: Range<Int>) -> String {
        var output = "", previous: String?
        for unit in units[range] {
            if unit.id != previous {
                if previous != nil { output += "\n" }
                output += unit.prefix
            }
            output += unit.text
            previous = unit.id
        }
        return output + "\n"
    }

    func upperBound(from cursor: Int, bytes limit: Int) -> Int {
        var bytes = 0, end = cursor, previous: String?
        while end < units.count {
            let unit = units[end]
            let cost = unit.text.utf8.count + (unit.id == previous ? 0 : unit.prefix.utf8.count + 1)
            if end > cursor && bytes + cost > limit { break }
            bytes += cost; end += 1; previous = unit.id
        }
        return end - cursor
    }

    func boundary(from cursor: Int, fitting count: Int) -> Int {
        if cursor + count == units.count { return count }
        // Pick the furthest complete turn, including a question with its immediate reply.
        for rank in [3, 2, 1] {
            if let index = units[cursor..<cursor + count].lastIndex(where: { $0.boundary >= rank }) {
                return index - cursor + 1
            }
        }
        return count
    }
}
