import SwiftUI
import MeetingCore

@main
struct MeetingNoteTakerApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Image(systemName: model.recording != nil ? "record.circle.fill" : "waveform.badge.mic")
                .symbolRenderingMode(.palette).foregroundStyle(model.recording != nil ? .red : .primary)
        }.menuBarExtraStyle(.window)
        Window("Meetings", id: "meetings") {
            MeetingList().environmentObject(model).frame(minWidth: 850, minHeight: 550)
        }.defaultSize(width: 1080, height: 700)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
        Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
            ShortcutReferenceView(keyCode: model.settings.shortcutKeyCode, modifiers: model.settings.shortcutModifiers) {
                model.settingsPage = .general
            }
        }.windowResizability(.contentSize)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
        Settings {
            SettingsView().environmentObject(model).frame(width: 820, height: 680)
                .background(SettingsWindowRegistration())
        }.restorationBehavior(.disabled)
    }
}

struct MeetingList: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: UUID?
    @StateObject private var documentReader = MeetingDocumentReader()
    @State private var analysisProfileChoice = ""
    @State private var viewerMode: MeetingViewerMode = .preview
    var current: MeetingSession? { model.sessions.first { $0.id == selected } }
    var body: some View {
        NavigationSplitView {
            List(model.sessions, selection: $selected) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.stem).font(.headline)
                    HStack { Text(session.status.rawValue.capitalized); if session.audioDeleted { Image(systemName: "waveform.slash") }; if !session.analyses.isEmpty { Image(systemName: "sparkles") } }.font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4).tag(session.id)
            }.navigationTitle("Meetings")
            .toolbar { Button { model.toggleRecording() } label: { Label(model.recording == nil ? "Record" : "Stop", systemImage: model.recording == nil ? "record.circle" : "stop.circle") } }
        } detail: {
            if let session = current {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading) { Text(session.stem).font(.title2.bold()); Text("\(MarkdownExporter.time(session.duration)) · \(session.speech.engine.title)").foregroundStyle(.secondary) }
                        Spacer()
                        Button("Open Markdown") { NSWorkspace.shared.open(session.markdownURL) }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([session.markdownURL]) } label: { Image(systemName: "folder") }
                    }
                    HStack {
                        if !session.audioDeleted && session.audioFingerprint != nil {
                            Button("Play") { model.play(session) }; Button("Stop playback", action: model.stopPlayback)
                            Button(session.status == .complete ? "Retranscribe with current model" : "Retry with current model") { model.process(session, useCurrentSettings: true) }.disabled(model.working || model.recording != nil)
                            if session.status != .complete && !session.completedChunks.isEmpty {
                                Button("Resume saved job") { model.process(session, resume: true) }.disabled(model.working || model.recording != nil)
                            }
                        } else if session.status == .interrupted { Button("Recover recording") { model.recoverSession(session) }.disabled(model.working) }
                        Menu("Analyze") {
                            Button("All enabled types") { model.analyze(session, profileID: UUID(uuidString: analysisProfileChoice), useSavedProfile: analysisProfileChoice == "saved") }
                            Divider()
                            ForEach(AnalysisKind.allCases) { kind in Button(kind.title) { model.analyze(session, kind: kind, profileID: UUID(uuidString: analysisProfileChoice), useSavedProfile: analysisProfileChoice == "saved") } }
                        }.disabled(model.working || model.recording != nil || session.firstSuccessfulExport == nil)
                        if model.working { Button("Cancel", action: model.cancelWork) }
                    }
                    Picker("Analysis profile", selection: $analysisProfileChoice) {
                        Text(session.profileSnapshot.map { saved in
                            model.profileCatalog?.profiles.first(where: { $0.id == saved.id }).map { "Assigned: \($0.name) · latest version" } ?? "Deleted profile: \(saved.name) — choose a replacement"
                        } ?? "Default: \(model.defaultMeetingProfile?.name ?? "Unavailable") · latest version").tag("")
                        ForEach(model.profileCatalog?.profiles ?? []) { Text($0.name).tag($0.id.uuidString) }
                        if let p = session.profileSnapshot { Text("Use saved profile settings · \(p.name) v\(p.revision)").tag("saved") }
                    }.onChange(of: selected) { _, _ in analysisProfileChoice = "" }
                    if session.audioDeleted { Text("Audio deleted by retention policy. Analysis remains available from Markdown.").font(.caption).foregroundStyle(.secondary) }
                    if documentReader.document?.url == session.markdownURL, let hash = documentReader.document?.transcriptFingerprint, session.analyses.values.contains(where: { $0.transcriptFingerprint != hash }) { Label("Analysis is based on an older transcript. Regenerate to include your corrections.", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange) }
                    if let error = session.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    if session.status == .failed {
                        Text("Retry starts transcription again using the model currently selected in Settings. Your recording is preserved.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.error { HStack { Text(error).foregroundStyle(.red).font(.caption); Button("Dismiss") { model.error = nil } } }
                    Text(model.progress).font(.caption).foregroundStyle(.secondary)
                    MeetingDocumentViewer(url: session.markdownURL, updateToken: model.progress + model.documentUpdateID.uuidString, reader: documentReader, mode: $viewerMode)
                }.padding(20)
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView("Your meeting notebook", systemImage: "text.book.closed", description: Text("Choose a transcription model in Settings, then start a recording from the menu bar. Each meeting gets a Markdown transcript and matching audio."))
                    OpenSettingsButton { Text("Configure models & settings…") }.buttonStyle(.borderedProminent)
                }
            }
        }.onAppear { UserDefaults.standard.set(true, forKey: "hasOpenedNotebook"); Task { await model.reload() } }
    }
}
