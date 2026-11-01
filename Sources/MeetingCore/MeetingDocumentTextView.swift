import AppKit

/// TextKit 1 supplies native tables, paragraph-spanning selection and scrolling.
/// Instances retain position across same-document refreshes; a different document
/// resets position. The caller retains one instance per preview/raw mode.
@MainActor public final class MeetingDocumentTextView: NSScrollView, NSTextViewDelegate {
    public let textView: NSTextView
    private var anchors: [String: NSRange] = [:]
    private var documentID: String?
    private var revision: String?
    public var openWebLink: (URL) -> Void = { NSWorkspace.shared.open($0) }

    public init(label: String) {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        container.widthTracksTextView = true
        textView = AppearanceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        hasVerticalScroller = true; hasHorizontalScroller = false
        borderType = .noBorder; drawsBackground = true; backgroundColor = .textBackgroundColor
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false; textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = true; textView.importsGraphics = false
        textView.allowsUndo = false; textView.usesFindPanel = true
        textView.isAutomaticLinkDetectionEnabled = false; textView.isAutomaticDataDetectionEnabled = false
        textView.backgroundColor = .textBackgroundColor; textView.textColor = .textColor
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.setAccessibilityLabel(label); textView.delegate = self
        documentView = textView
    }
    required init?(coder: NSCoder) { nil }

    public func display(_ text: NSAttributedString, anchors: [String: NSRange], documentID: String, revision: String) {
        self.anchors = anchors
        guard self.documentID != documentID || self.revision != revision else { return }
        let changedMeeting = self.documentID != documentID
        let position = changedMeeting ? NSPoint.zero : contentView.bounds.origin
        let selection = changedMeeting ? NSRange(location: 0, length: 0) : textView.selectedRange()
        self.documentID = documentID; self.revision = revision
        textView.textStorage?.setAttributedString(text)
        textView.setSelectedRange(NSRange(location: min(selection.location, text.length), length: min(selection.length, max(0, text.length-selection.location))))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()
        contentView.scroll(to: position); reflectScrolledClipView(contentView)
    }
    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let destination = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        switch MeetingMarkdownLink.destination(destination) {
        case .anchor(let id):
            if let range = anchors[id], NSMaxRange(range) <= textView.string.utf16.count {
                textView.setSelectedRange(range); textView.scrollRangeToVisible(range)
                textView.showFindIndicator(for: range)
            }
        case .web(let url): openWebLink(url)
        case .blocked: break
        }
        return true // Never let AppKit launch an unhandled URL scheme.
    }
    private final class AppearanceTextView: NSTextView {
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            backgroundColor = .textBackgroundColor; needsDisplay = true
        }
    }
}
