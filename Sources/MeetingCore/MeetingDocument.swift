import Foundation
import AppKit
import Markdown

/// Immutable after construction. AppKit text attributes are created on the loader
/// worker and are never mutated once handed to the main-thread text view.
public struct RenderedMeetingMarkdown: @unchecked Sendable {
    public let text: NSAttributedString
    public let anchors: [String: NSRange]
}
public struct MeetingDocument: @unchecked Sendable {
    public let url: URL
    public let raw: String
    public let rawText: NSAttributedString
    public let fingerprint: String
    public let transcriptFingerprint: String?
    public let frontmatter: String?
    public let preview: RenderedMeetingMarkdown?
    public let renderingError: String?

    public static func splitFrontmatter(_ raw: String) -> (metadata: String?, body: String) {
        let source = raw.hasPrefix("\u{feff}") ? String(raw.dropFirst()) : raw
        let ns = source as NSString
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return (nil, source) }
        let firstEnd = ns.range(of: "\n")
        let start = NSMaxRange(firstEnd)
        var cursor = start
        while cursor < ns.length {
            let newline = ns.range(of: "\n", range: NSRange(location: cursor, length: ns.length-cursor))
            let end = newline.location == NSNotFound ? ns.length : newline.location
            if ns.substring(with: NSRange(location: cursor, length: end-cursor)).trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                let bodyStart = newline.location == NSNotFound ? end : NSMaxRange(newline)
                return (ns.substring(with: NSRange(location: start, length: cursor-start)), ns.substring(from: bodyStart))
            }
            cursor = newline.location == NSNotFound ? end : NSMaxRange(newline)
        }
        return (nil, source)
    }

    public static func parse(raw: String, url: URL) throws -> MeetingDocument {
        try Task.checkCancellation()
        let parts = splitFrontmatter(raw)
        let hash = documentFingerprint(raw)
        let transcriptHash = (try? MarkdownExporter.readTranscript(markdown: raw)).map(MarkdownExporter.transcriptFingerprint)
        let rawText = NSAttributedString(string: raw, attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular), .foregroundColor: NSColor.textColor])
        do {
            let preview = try MeetingMarkdownRenderer.render(parts.body)
            return .init(url: url, raw: raw, rawText: rawText, fingerprint: hash, transcriptFingerprint: transcriptHash, frontmatter: parts.metadata, preview: preview, renderingError: nil)
        } catch is CancellationError { throw CancellationError() }
        catch { return .init(url: url, raw: raw, rawText: rawText, fingerprint: hash, transcriptFingerprint: transcriptHash, frontmatter: parts.metadata, preview: nil, renderingError: "The preview could not be rendered. Use Raw to read the complete Markdown.") }
    }
}
// Avoid shadowing the global helper with MeetingDocument.fingerprint.
private func documentFingerprint(_ text: String) -> String { fingerprint(text) }

/// Retain only the selected document. Reads and Markdown parsing never run on the
/// UI actor; a cancelled/stale request cannot replace a more recent cache entry.
public actor MeetingDocumentLoader {
    private var cached: MeetingDocument?
    private var generation = UUID()
    public init() {}
    public func load(_ url: URL) async throws -> MeetingDocument {
        let id = UUID(); generation = id
        let previous = cached?.url == url ? cached : nil
        let worker = Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            try Task.checkCancellation()
            guard let raw = String(data: data, encoding: .utf8) else { throw MeetingError.message("The Markdown file is not valid UTF-8.") }
            if let previous, previous.fingerprint == fingerprint(raw) { return previous }
            return try MeetingDocument.parse(raw: raw, url: url)
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        if generation == id { cached = result }
        return result
    }
}

public enum MeetingMarkdownLink {
    case anchor(String), web(URL), blocked
    public static func destination(_ text: String) -> MeetingMarkdownLink {
        if text.hasPrefix("#"), let id = String(text.dropFirst()).removingPercentEncoding, !id.isEmpty { return .anchor(id) }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil, url.user == nil, url.password == nil { return .web(url) }
        return .blocked
    }
}

public enum MeetingMarkdownRenderer {
    public static func render(_ markdown: String) throws -> RenderedMeetingMarkdown {
        try Task.checkCancellation()
        let document = Document(parsing: markdown)
        let renderer = Renderer()
        try renderer.block(document, indent: 0, depth: 0)
        return renderer.result()
    }

    private final class Renderer {
        let output = NSMutableAttributedString(string: "")
        var anchors: [String: NSRange] = [:]
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let codeFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let commentPattern = try! NSRegularExpression(pattern: "<!--(?:[\\s\\S]*?-->|[\\s\\S]*$)")
        let anchorPattern = try! NSRegularExpression(pattern: #"^<a\s+id=["'](segment-[A-Za-z0-9_-]{1,128})["']\s*>(?:\s*</a>)?$"#)
        var openAnchorTags = 0

        func result() -> RenderedMeetingMarkdown {
            let plain = output.string as NSString
            for (id, range) in anchors where range.location < plain.length {
                anchors[id] = plain.lineRange(for: range)
            }
            return .init(text: NSAttributedString(attributedString: output), anchors: anchors)
        }
        func style(indent: CGFloat = 0) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3; paragraph.paragraphSpacing = 8
            paragraph.headIndent = indent; paragraph.firstLineHeadIndent = indent
            return [.font: bodyFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        }
        func append(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        func trait(_ trait: NSFontDescriptor.SymbolicTraits, in attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var result = attributes; let font = attributes[.font] as? NSFont ?? bodyFont
            result[.font] = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)), size: font.pointSize) ?? font
            return result
        }
        func block(_ node: Markup, indent: CGFloat, depth: Int) throws {
            try Task.checkCancellation()
            guard depth < 128 else { throw MeetingError.message("Markdown nesting is too deep.") }
            var attributes = style(indent: indent)
            switch node {
            case let heading as Heading:
                let sizes: [CGFloat] = [26, 21, 17, 15, 14, 13]
                attributes[.font] = NSFont.systemFont(ofSize: sizes[min(5, max(0, heading.level-1))], weight: .semibold)
                let p = attributes[.paragraphStyle] as! NSMutableParagraphStyle
                p.paragraphSpacingBefore = heading.level == 1 ? 4 : 12; p.paragraphSpacing = 8
                try inlineChildren(heading, attributes, depth: depth); append("\n", attributes)
            case let paragraph as Paragraph:
                let start = output.length
                try inlineChildren(paragraph, attributes, depth: depth)
                if output.length > start { append("\n", attributes) }
            case let list as OrderedList:
                try renderList(list, start: list.startIndex, indent: indent, depth: depth)
            case let list as UnorderedList:
                try renderList(list, start: nil, indent: indent, depth: depth)
            case let quote as BlockQuote:
                let start = output.length
                for child in quote.children { try block(child, indent: indent+18, depth: depth+1) }
                if output.length > start { output.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: NSRange(location: start, length: output.length-start)) }
            case let code as CodeBlock:
                attributes[.font] = codeFont; attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
                append(code.code, attributes); if !code.code.hasSuffix("\n") { append("\n", attributes) }
            case is ThematicBreak:
                attributes[.foregroundColor] = NSColor.separatorColor; append("────────────────────────\n", attributes)
            case let html as HTMLBlock:
                try renderHTML(html.rawHTML, attributes, depth: depth)
            case let table as Table:
                try renderTable(table, indent: indent, depth: depth)
            default:
                for child in node.children { try block(child, indent: indent, depth: depth+1) }
            }
        }
        func renderList(_ node: Markup, start: UInt?, indent: CGFloat, depth: Int) throws {
            for (index, item) in node.children.enumerated() {
                guard let item = item as? ListItem else { continue }
                let attributes = style(indent: indent+22)
                let paragraph = attributes[.paragraphStyle] as! NSMutableParagraphStyle
                paragraph.firstLineHeadIndent = indent
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent+22)]
                paragraph.paragraphSpacing = 5
                let marker = item.checkbox.map { $0 == .checked ? "☑" : "☐" } ?? start.map { "\($0+UInt(index))." } ?? "•"
                append(marker+"\t", attributes)
                var first = true
                for child in item.children {
                    if first, let p = child as? Paragraph {
                        try inlineChildren(p, attributes, depth: depth+1); append("\n", attributes)
                    } else {
                        if first { append("\n", attributes) }
                        try block(child, indent: indent+22, depth: depth+1)
                    }
                    first = false
                }
                if first { append("\n", attributes) }
            }
        }
        func renderTable(_ node: Table, indent: CGFloat, depth: Int) throws {
            let table = NSTextTable(); table.numberOfColumns = max(1, node.maxColumnCount)
            table.layoutAlgorithm = .automaticLayoutAlgorithm; table.collapsesBorders = true
            table.setContentWidth(100, type: .percentageValueType)
            let rows: [[Table.Cell]] = [Array(node.head.cells)] + node.body.rows.map { Array($0.cells) }
            for (rowIndex, row) in rows.enumerated() {
                for (columnIndex, cell) in row.enumerated() {
                    let cellBlock = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: columnIndex, columnSpan: 1)
                    cellBlock.setWidth(1, type: .absoluteValueType, for: .border)
                    cellBlock.setBorderColor(.separatorColor)
                    cellBlock.setWidth(6, type: .absoluteValueType, for: .padding)
                    if rowIndex == 0 { cellBlock.backgroundColor = .controlBackgroundColor }
                    var attributes = style(indent: indent)
                    let paragraph = attributes[.paragraphStyle] as! NSMutableParagraphStyle
                    paragraph.textBlocks = [cellBlock]; paragraph.paragraphSpacing = 0
                    if columnIndex < node.columnAlignments.count {
                        switch node.columnAlignments[columnIndex] { case .center: paragraph.alignment = .center; case .right: paragraph.alignment = .right; default: break }
                    }
                    if rowIndex == 0 { attributes = trait(.bold, in: attributes) }
                    try inlineChildren(cell, attributes, depth: depth+1); append("\n", attributes)
                }
            }
            append("\n", style(indent: indent))
        }
        func inlineChildren(_ node: Markup, _ attributes: [NSAttributedString.Key: Any], depth: Int) throws {
            guard depth < 128 else { throw MeetingError.message("Markdown nesting is too deep.") }
            for child in node.children { try inline(child, attributes, depth: depth+1) }
        }
        func inline(_ node: Markup, _ attributes: [NSAttributedString.Key: Any], depth: Int) throws {
            try Task.checkCancellation()
            var adjusted = attributes
            switch node {
            case let text as Markdown.Text: append(text.string, attributes)
            case is SoftBreak: append(" ", attributes)
            case is LineBreak: append("\u{2028}", attributes)
            case is Strong: try inlineChildren(node, trait(.bold, in: attributes), depth: depth)
            case is Emphasis: try inlineChildren(node, trait(.italic, in: attributes), depth: depth)
            case is Strikethrough:
                adjusted[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                try inlineChildren(node, adjusted, depth: depth)
            case let code as InlineCode:
                adjusted[.font] = codeFont; adjusted[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
                append(code.code, adjusted)
            case let link as Markdown.Link:
                if let destination = link.destination {
                    switch MeetingMarkdownLink.destination(destination) {
                    case .anchor, .web: adjusted[.link] = destination
                    case .blocked: break
                    }
                }
                try inlineChildren(link, adjusted, depth: depth)
            case let image as Markdown.Image:
                adjusted[.foregroundColor] = NSColor.secondaryLabelColor
                append("[Image: \(image.plainText.isEmpty ? "no description" : image.plainText)]", adjusted)
            case let html as InlineHTML: try renderHTML(html.rawHTML, attributes, depth: depth)
            default: try inlineChildren(node, attributes, depth: depth)
            }
        }
        func renderHTML(_ raw: String, _ attributes: [NSAttributedString.Key: Any], depth: Int) throws {
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            let visible = commentPattern.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
            let lines = visible.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let ns = trimmed as NSString
                if let match = anchorPattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
                    let id = ns.substring(with: match.range(at: 1))
                    if anchors[id] == nil { anchors[id] = NSRange(location: output.length, length: 0) }
                    if !trimmed.hasSuffix("</a>") { openAnchorTags += 1 }
                    // Some CommonMark HTML blocks include the following heading
                    // when the app's anchor is not separated by a blank line.
                    if index+1 < lines.count {
                        let trailing = lines[(index+1)...].joined(separator: "\n")
                        if !trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            try block(Document(parsing: trailing), indent: (attributes[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0, depth: depth+1)
                        }
                    }
                    return
                } else if trimmed == "</a>", openAnchorTags > 0 {
                    openAnchorTags -= 1
                } else {
                    // Literal text only. No HTML importer, scripts, image loads or WebKit.
                    var literal = attributes; literal[.font] = codeFont
                    append(line, literal); if raw.contains("\n") { append("\n", literal) }
                }
            }
        }
    }
}
