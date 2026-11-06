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
    @State private var playbackWindowOpen = true
    @State private var deletionCandidate: MeetingSession?
    @State private var searchText = ""
    @State private var searchMatches: Set<UUID> = []
    @State private var searching = false
    @State private var unreadableSearchFiles = 0
    private var searchingQuery: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visibleSessions: [MeetingSession] { searchingQuery ? model.sessions.filter { searchMatches.contains($0.id) } : model.sessions }
    private struct SearchRequest: Equatable { let query: String; let update: UUID }

    @StateObject private var documentReader = MeetingDocumentReader()
    @State private var analysisProfileChoice = ""
    @State private var viewerMode: MeetingViewerMode = .preview
    var current: MeetingSession? { model.sessions.first { $0.id == selected } }
    private var playbackSelection: PlaybackSelection? {
        guard let session = current, !session.audioDeleted, session.deletionRequestedAt == nil,
              !model.deletingMeeting, model.processingMeetingID != session.id, model.playbackRemovalID != session.id,
              let fingerprint = session.audioFingerprint else { return nil }
        return .init(id: session.id, url: session.audioURL, version: fingerprint)
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search meetings", text: $searchText)
                    .textFieldStyle(.roundedBorder).padding(10)
                    .accessibilityLabel("Search meeting filenames and contents")
                if searching { ProgressView().controlSize(.small).padding(.bottom, 6) }
                if unreadableSearchFiles > 0 && searchingQuery {
                    Text("\(unreadableSearchFiles) files unavailable for content search").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                }
                List(visibleSessions, selection: $selected) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.stem).font(.headline)
                        HStack { Text(session.deletionRequestedAt == nil ? session.status.rawValue.capitalized : "Deletion pending"); if session.audioDeleted { Image(systemName: "waveform.slash") }; if !session.analyses.isEmpty { Image(systemName: "sparkles") } }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(session.id)
                }
                .overlay {
                    if searchingQuery && !searching && visibleSessions.isEmpty { Text("No matching meetings").foregroundStyle(.secondary) }
                }
            }.navigationTitle("Meetings")
            .toolbar {
                Button { model.toggleRecording() } label: {
                    Label {
                        Text(model.recording == nil ? "Record" : "Stop")
                    } icon: {
                        Image(systemName: model.recording == nil ? "record.circle" : "record.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(model.recording == nil ? Color.secondary : Color.red)
                    }
                }
                .help(model.recording == nil ? "Start recording" : "Stop recording")
                .disabled(model.deletingMeeting)
            }
        } detail: {
            if let session = current {
                VStack(alignment: .leading, spacing: 12) {
                    if model.recording != nil, model.captureHealth.microphone.availability == .recovering || model.captureHealth.computer.availability == .recovering {
                        Label("Current recording — " + model.captureHealthText, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    HStack {
                        VStack(alignment: .leading) { Text(session.stem).font(.title2.bold()); Text("\(MarkdownExporter.time(session.duration)) · \(session.speech.engine.title)").foregroundStyle(.secondary) }
                        Spacer()
                        Button("Open Markdown") { NSWorkspace.shared.open(session.markdownURL) }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([session.markdownURL]) } label: { Image(systemName: "folder") }
                        Button { deletionCandidate = session } label: {
                            Label(session.deletionRequestedAt == nil ? "Delete Meeting…" : "Retry deletion…", systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                        .help(session.deletionRequestedAt == nil ? "Delete Meeting…" : "Retry deletion…")
                        .accessibilityLabel(session.deletionRequestedAt == nil ? "Delete Meeting…" : "Retry deletion…")
                        .disabled(!model.canDeleteMeeting)

                    }
                    HStack {
                        if !session.audioDeleted && session.audioFingerprint != nil {
                            MeetingPlaybackButtons(playback: model.playback)
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
                    .disabled(model.deletingMeeting || session.deletionRequestedAt != nil)
                    if !session.audioDeleted && session.audioFingerprint != nil {
                        MeetingPlaybackProgress(playback: model.playback)
                            .disabled(model.deletingMeeting || session.deletionRequestedAt != nil)
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
                    if model.recording?.id == session.id {
                        Text(model.captureHealthText).font(.caption).foregroundStyle(.orange)
                    } else {
                        ForEach(session.captureWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if let error = session.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    if session.status == .failed && session.deletionRequestedAt == nil {
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
        }
        .task(id: SearchRequest(query: searchText, update: model.documentUpdateID)) {
            guard searchingQuery else { searching = false; unreadableSearchFiles = 0; return }
            searching = true
            do {
                try await Task.sleep(for: .milliseconds(250))
                let result = try await MeetingSearch.search(searchText, sessions: model.sessions)
                try Task.checkCancellation()
                searchMatches = result.ids; unreadableSearchFiles = result.unreadableFiles; searching = false
            } catch { if !Task.isCancelled { searching = false } }
        }
        .alert("Move meeting to Trash?", isPresented: Binding(get: { deletionCandidate != nil }, set: { if !$0 { deletionCandidate = nil } }), presenting: deletionCandidate) { candidate in
            Button("Cancel", role: .cancel) { deletionCandidate = nil }.keyboardShortcut(.defaultAction)
            Button("Move to Trash", role: .destructive) {
                deletionCandidate = nil
                Task {
                    if await model.deleteMeeting(candidate.id), selected == candidate.id {
                        selected = nil; documentReader.clear()
                    }
                }
            }.disabled(!model.canDeleteMeeting)
        } message: { candidate in
            Text("“\(candidate.stem)” and its transcript, personal notes, analyses, audio, recovery files and meeting history will move to macOS Trash.")
        }
        .onChange(of: playbackSelection, initial: true) { _, selection in if playbackWindowOpen { model.playback.select(selection) } }
        .onChange(of: model.documentUpdateID) { _, _ in if playbackWindowOpen { model.playback.select(playbackSelection) } }
        .onDisappear { playbackWindowOpen = false; model.playback.release() }
        .background(MeetingPlaybackWindowLifecycle(opened: {
            playbackWindowOpen = true; model.playback.select(playbackSelection)
            Task { await model.reload() }
        }, closed: {
            playbackWindowOpen = false; model.playback.release()
        }))
        .onAppear {
            playbackWindowOpen = true
            model.playback.select(playbackSelection)
            UserDefaults.standard.set(true, forKey: "hasOpenedNotebook"); Task { await model.reload() }
        }
    }
}
