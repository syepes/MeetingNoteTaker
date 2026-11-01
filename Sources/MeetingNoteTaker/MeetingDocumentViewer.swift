import SwiftUI
import AppKit
import MeetingCore

enum MeetingViewerMode: String, CaseIterable { case preview = "Preview", raw = "Raw" }

struct MeetingDocumentViewer: View {
    let url: URL
    let updateToken: String
    @ObservedObject var reader: MeetingDocumentReader
    @Binding var mode: MeetingViewerMode
    @State private var reloadID = 0
    @State private var detailsExpanded = false

    private struct LoadRequest: Equatable { let url: URL; let update: String; let reload: Int }
    private var document: MeetingDocument? { reader.document?.url == url ? reader.document : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Document view", selection: $mode) {
                    ForEach(MeetingViewerMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Spacer()
                if reader.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Loading Markdown") }
                Button { reloadID += 1 } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Reload the Markdown file, including external edits.")
                    .disabled(reader.isLoading)
            }
            if let error = reader.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let document {
                // Keep both native text views alive: each owns its scroll/selection
                // state. Switching modes never reloads or modifies the document.
                ZStack {
                    VStack(alignment: .leading, spacing: 8) {
                        if let frontmatter = document.frontmatter {
                            DisclosureGroup("Meeting details", isExpanded: $detailsExpanded) {
                                ScrollView {
                                    Text(frontmatter).font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                }.frame(maxHeight: 150)
                            }.padding(.horizontal, 10).padding(.top, 8)
                        }
                        if let preview = document.preview {
                            NativeMeetingText(text: preview.text, anchors: preview.anchors, documentID: url.path,
                                              revision: document.fingerprint, label: "Rendered meeting Markdown", isActive: mode == .preview)
                        } else {
                            ContentUnavailableView("Preview unavailable", systemImage: "doc.text",
                                description: Text(document.renderingError ?? "Use Raw to view this document."))
                        }
                    }.opacity(mode == .preview ? 1 : 0).allowsHitTesting(mode == .preview).accessibilityHidden(mode != .preview)
                    NativeMeetingText(text: document.rawText, anchors: [:], documentID: url.path, revision: document.fingerprint, label: "Raw meeting Markdown", isActive: mode == .raw)
                        .opacity(mode == .raw ? 1 : 0).allowsHitTesting(mode == .raw).accessibilityHidden(mode != .raw)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            } else {
                ContentUnavailableView(reader.isLoading ? "Loading meeting…" : "Markdown unavailable", systemImage: "doc.text",
                    description: Text(reader.isLoading ? "" : "Check the file location, then choose Reload."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: LoadRequest(url: url, update: updateToken, reload: reloadID)) { await reader.load(url) }
        .onChange(of: url) { _, _ in detailsExpanded = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window.identifier?.rawValue == "meetings" else { return }
            reloadID += 1
        }
    }
}

/// Both modes reuse the same native read-only component and keep their own
/// NSScrollView instances alive while the segmented control changes visibility.
struct NativeMeetingText: NSViewRepresentable {
    let text: NSAttributedString
    let anchors: [String: NSRange]
    let documentID: String
    let revision: String
    let label: String
    let isActive: Bool

    func makeNSView(context: Context) -> MeetingDocumentTextView { MeetingDocumentTextView(label: label) }
    func updateNSView(_ view: MeetingDocumentTextView, context: Context) {
        view.isHidden = !isActive
        if !isActive, view.window?.firstResponder === view.textView { view.window?.makeFirstResponder(nil) }
        view.display(text, anchors: anchors, documentID: documentID, revision: revision)
    }
}
