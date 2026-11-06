import Foundation

public enum MarkdownExporter {
    public static func begin(_ name: String) -> String { "<!-- mnt:\(name):start -->" }
    public static func end(_ name: String) -> String { "<!-- mnt:\(name):end -->" }
    public static func block(_ name: String, _ body: String) -> String { "\(begin(name))\n\(body)\n\(end(name))" }
    public static func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds)); return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }
    private static func quote(_ value: String) -> String { String(data: try! JSONEncoder().encode(value), encoding: .utf8)! }
    public static func metadata(_ s: MeetingSession) -> String {
        var text = """
        ---
        schema_version: 1
        meeting_id: \(quote(s.id.uuidString))
        started_at: \(quote(ISO8601DateFormatter().string(from: s.startedAt)))
        timezone: \(quote(s.timezone))
        duration_seconds: \(Int(s.duration))
        status: \(s.status.rawValue)
        transcription_provider: \(s.speech.engine.rawValue)
        transcription_model: \(quote(s.speech.engine == .remote ? s.speech.remoteModel : s.speech.engine == .parakeet ? s.speech.parakeetVersion : URL(fileURLWithPath: s.speech.modelPath).lastPathComponent))
        audio_file: \(s.audioDeleted ? "null" : quote(s.stem + ".m4a"))
        audio_status: \(s.audioDeleted ? "deleted" : "retained")
        audio_channels: {left: microphone, right: computer}
        computer_audio_target: \(quote((s.captureTarget ?? .init()).label))
        capture_started_at: \(s.captureStartedAt.map { quote(ISO8601DateFormatter().string(from: $0)) } ?? "null")
        ---
        """
        var extra = ""
        if let diagnostics = s.captureDiagnostics {
            extra += "capture_microphone_uid: \(diagnostics.microphoneUID.map(quote) ?? "null")\n"
        }
        extra += "capture_warnings: [" + s.captureWarnings.map(quote).joined(separator: ", ") + "]\n"
        if let p = s.metadataProfile { extra += "profile_id: \(quote(p.id.uuidString))\nprofile_name: \(quote(p.name))\nprofile_revision: \(p.revision)\n" }
        if let tags = s.tags { extra += "tags: [" + tags.map(quote).joined(separator: ", ") + "]\n" }
        if !extra.isEmpty { text = String(text.dropLast(3)) + extra + "---" }
        return text
    }
    public static func initial(_ s: MeetingSession) -> String {
        var content = metadata(s) + "\n\n# Meeting — \(s.stem)\n\n"
        for kind in AnalysisKind.allCases { content += block(kind.rawValue, "## \(kind.title)\n\nNot generated.") + "\n\n" }
        content += "## Personal Notes\n\n\n" + block("transcript", "## Transcript\n\nRecording…") + "\n"
        return content
    }
    public static func content(_ name: String, in markdown: String) throws -> String {
        guard let a = markdown.range(of: begin(name)), let b = markdown.range(of: end(name), range: a.upperBound..<markdown.endIndex) else {
            throw MeetingError.message("The \(name) section markers are missing. Restore them before updating this document.")
        }
        return String(markdown[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .newlines)
    }
    public static func replacing(_ name: String, in markdown: String, with value: String) throws -> String {
        if name == "metadata" {
            guard markdown.hasPrefix("---\n"), let closing = markdown.range(of: "\n---", range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex) else { throw MeetingError.message("The YAML frontmatter is missing; your document was preserved.") }
            let oldHeader = String(markdown[markdown.index(markdown.startIndex, offsetBy: 4)..<closing.lowerBound])
            let newHeader = MeetingDocument.splitFrontmatter(value).metadata ?? ""
            // Replace only app-owned top-level entries. Preserve unknown fields,
            // comments, block-style tags and their continuation lines verbatim.
            let additions = newHeader.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
            let key: (String) -> String? = { line in
                guard let first = line.first, first != " " && first != "\t" && first != "#", let colon = line.firstIndex(of: ":") else { return nil }
                let candidate = String(line[..<colon])
                return candidate.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil ? candidate : nil
            }
            let replacements = Dictionary(uniqueKeysWithValues: additions.compactMap { line in key(line).map { ($0, line) } })
            var lines: [String] = [], seen = Set<String>(), skipping = false
            for line in oldHeader.components(separatedBy: "\n") {
                if let k = key(line) {
                    skipping = false
                    if let replacement = replacements[k], k != "tags" {
                        guard seen.insert(k).inserted else { throw MeetingError.message("Duplicate metadata field \(k); your file was preserved.") }
                        lines.append(replacement); skipping = true
                    } else { seen.insert(k); lines.append(line) }
                } else if !skipping || line.hasPrefix("#") { lines.append(line) }
            }
            for line in additions { if let k = key(line), !seen.contains(k) { lines.append(line) } }
            return markdown.replacingCharacters(in: markdown.startIndex..<closing.upperBound, with: "---\n" + lines.joined(separator: "\n") + "\n---")
        }
        guard let a = markdown.range(of: begin(name)), let b = markdown.range(of: end(name), range: a.upperBound..<markdown.endIndex) else {
            throw MeetingError.message("Missing document markers for \(name).")
        }
        return markdown.replacingCharacters(in: a.lowerBound..<b.upperBound, with: block(name, value))
    }
    public static func commit(_ new: String, replacing old: String, at url: URL) throws {
        guard try String(contentsOf: url, encoding: .utf8) == old else { throw MeetingError.message("The Markdown changed while processing. Your edits were preserved; retry the update.") }
        try new.write(to: url, atomically: true, encoding: .utf8)
        guard try String(contentsOf: url, encoding: .utf8) == new else { throw MeetingError.message("Markdown verification failed.") }
    }
    public static func updateMetadata(_ s: MeetingSession) throws {
        let old = try String(contentsOf: s.markdownURL, encoding: .utf8)
        try commit(replacing("metadata", in: old, with: metadata(s)), replacing: old, at: s.markdownURL)
    }
    public static func renderTranscript(_ s: MeetingSession) -> String {
        var result = "## Transcript\n\n"
        for event in s.events where event.kind != .heartbeat && event.kind != .recoveryAttempt && event.kind != .captureDiagnostic { result += "> [\(time(event.time))] \(event.message.replacingOccurrences(of: "\n", with: " "))\n\n" }
        for segment in s.segments.sorted(by: { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }) {
            result += "<!-- segment:\(segment.id)|\(segment.source.rawValue)|\(segment.start)|\(segment.end)|\(segment.approximate) -->\n"
            result += "<a id=\"segment-\(segment.id)\"></a>\n### [\(time(segment.start))–\(time(segment.end))] \(segment.source.label)\(segment.approximate ? " (approximate)" : "")\n\n\(safeText(segment.text))\n\n"
        }
        if s.segments.isEmpty { result += s.status == .complete ? "No speech detected.\n" : "Transcription pending.\n" }
        return result.trimmingCharacters(in: .newlines)
    }
    public static func exportTranscript(_ s: MeetingSession, previous: MeetingSession?) throws {
        let old = try String(contentsOf: s.markdownURL, encoding: .utf8)
        let existing = try content("transcript", in: old)
        if let previous, !previous.segments.isEmpty, existing != renderTranscript(previous) {
            throw MeetingError.message("The transcript was edited externally. Save those edits before replacing it with a retranscription.")
        }
        let next = try replacing("transcript", in: replacing("metadata", in: old, with: metadata(s)), with: renderTranscript(s))
        try commit(next, replacing: old, at: s.markdownURL)
    }
    public static func readTranscript(_ url: URL) throws -> [TranscriptSegment] {
        try readTranscript(markdown: String(contentsOf: url, encoding: .utf8))
    }
    public static func readTranscript(markdown: String) throws -> [TranscriptSegment] {
        let body = try content("transcript", in: markdown)
        let regex = try NSRegularExpression(pattern: "<!-- segment:([^|]+)\\|(microphone|computer)\\|([0-9.]+)\\|([0-9.]+)\\|(true|false) -->")
        let ns = body as NSString; let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty {
            if body.contains("No speech detected.") { return [] }
            throw MeetingError.message("No transcript segments found. Finish transcription before analysis, and preserve the segment comments when editing.")
        }
        guard body.components(separatedBy: "<!-- segment:").count - 1 == matches.count else { throw MeetingError.message("A transcript segment comment is malformed. Restore its ID, source, and timestamps before analysis.") }
        var ids = Set<String>()
        return try matches.enumerated().map { index, match in
            let id = ns.substring(with: match.range(at: 1))
            guard id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil, ids.insert(id).inserted else { throw MeetingError.message("Invalid or duplicate transcript segment ID.") }
            guard let startTime = Double(ns.substring(with: match.range(at: 3))), let endTime = Double(ns.substring(with: match.range(at: 4))), startTime.isFinite, endTime.isFinite, startTime >= 0, endTime >= startTime else { throw MeetingError.message("Invalid transcript timestamps. Your file was preserved.") }
            let start = NSMaxRange(match.range), finish = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let lines = ns.substring(with: NSRange(location: start, length: finish - start)).components(separatedBy: "\n")
            let text = lines.filter { !$0.hasPrefix("<a id=") && !$0.hasPrefix("### [") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptSegment(id: id, source: AudioSource(rawValue: ns.substring(with: match.range(at: 2)))!, start: startTime, end: endTime, text: text, approximate: ns.substring(with: match.range(at: 5)) == "true")
        }
    }
    public static func transcriptFingerprint(_ segments: [TranscriptSegment]) -> String {
        fingerprint(segments.map { "\($0.id)|\($0.source.rawValue)|\($0.start)|\($0.end)|\($0.text)" }.joined(separator: "\n"))
    }
    public static func renderAnalysis(_ result: AnalysisResult, segments: [TranscriptSegment]) -> String {
        let lookup = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var text = "## \(result.kind.title)\n\n"
        text += "<!-- analysis: \(result.provider) | \(result.model) | prompt \(result.promptRevision.id) | source \(result.transcriptFingerprint) | \(ISO8601DateFormatter().string(from: result.generatedAt)) -->\n\n"
        if let p = result.profile { text += "<!-- profile: \(p.id.uuidString) | revision \(p.revision) | \(safeText(p.name).replacingOccurrences(of: "-->", with: "--&gt;")) -->\n\n" }
        if result.items.isEmpty { return text + result.kind.emptyMessage(language: result.language) }
        for item in result.items {
            text += result.kind == .summary ? "" : result.kind == .actionItems ? "- [ ] " : "- "
            text += safeText(item.text)
            if result.kind == .actionItems {
                let labels: (owner: String, due: String, unspecifiedOwner: String, unspecifiedDue: String)
                switch result.language {
                case "Spanish": labels = ("Responsable", "Fecha límite", "Sin especificar", "Sin especificar")
                case "French": labels = ("Responsable", "Échéance", "Non précisé", "Non précisée")
                default: labels = ("Owner", "Due", "Unspecified", "Unspecified")
                }
                text += " — \(labels.owner): \(safeText(item.owner ?? labels.unspecifiedOwner))"
                text += "; \(labels.due): \(safeText(item.dueDateText ?? labels.unspecifiedDue))"
            }
            let refs = item.evidenceSegmentIDs.compactMap { id -> String? in guard let s = lookup[id] else { return nil }; return "[\(time(s.start))](#segment-\(id))" }
            text += " (\(refs.joined(separator: ", ")))\n\n"
        }
        return text.trimmingCharacters(in: .newlines)
    }
    public static func exportAnalysis(_ result: AnalysisResult, session: MeetingSession, segments: [TranscriptSegment]) throws {
        let old = try String(contentsOf: session.markdownURL, encoding: .utf8)
        let current = try readTranscript(session.markdownURL)
        guard transcriptFingerprint(current) == result.transcriptFingerprint else { throw MeetingError.message("Transcript changed during analysis. Result was not saved; regenerate it.") }
        let existing = try content(result.kind.rawValue, in: old)
        let expected = session.analyses[result.kind].map { $0.renderedMarkdown ?? renderAnalysis($0, segments: session.segments) } ?? "## \(result.kind.title)\n\nNot generated."
        guard existing == expected else { throw MeetingError.message("The \(result.kind.title) section was edited externally. Your edits were preserved.") }
        var next = try replacing(result.kind.rawValue, in: old, with: renderAnalysis(result, segments: segments))
        if let profile = result.profile { var updated = session; updated.metadataProfile = profile; next = try replacing("metadata", in: next, with: metadata(updated)) }
        try commit(next, replacing: old, at: session.markdownURL)
    }
    public static func safeText(_ text: String) -> String {
        text.replacingOccurrences(of: "<!--", with: "&lt;!--").replacingOccurrences(of: "<script", with: "&lt;script")
    }
}
