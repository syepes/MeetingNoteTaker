import SwiftUI
import ServiceManagement
import MeetingCore

enum SettingsPage: Hashable { case general, transcription, analysis, models, storage }

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $model.settingsPage) {
                GeneralSettings().tabItem { Label("General", systemImage: "gear") }.tag(SettingsPage.general)
                SpeechSettingsView().tabItem { Label("Transcription", systemImage: "waveform") }.tag(SettingsPage.transcription)
                AnalysisSettingsView().tabItem { Label("Analysis", systemImage: "sparkles") }.tag(SettingsPage.analysis)
                ModelsView().tabItem { Label("Models", systemImage: "externaldrive") }.tag(SettingsPage.models)
                StorageSettingsView().tabItem { Label("Storage", systemImage: "folder") }.tag(SettingsPage.storage)
            }.padding()
            Divider()
            HStack {
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3); Button("Dismiss") { model.error = nil } }
                else { Text(model.progress).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button("Save Settings", action: model.saveVisibleSettings).buttonStyle(.borderedProminent)
            }.padding()
        }
    }
}
struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var login = SMAppService.mainApp.status == .enabled
    var body: some View {
        Form {
            Section("Recording") {
                Picker("Computer audio", selection: Binding(get: { model.settings.captureTarget?.bundleID ?? "" }, set: { id in
                    model.settings.captureTarget = id.isEmpty ? CaptureTarget() : model.captureApplications.first(where: { $0.bundleID == id }) ?? CaptureTarget(bundleID: id)
                })) {
                    Text("All computer audio").tag("")
                    if let selected = model.settings.captureTarget, let id = selected.bundleID, !model.captureApplications.contains(where: { $0.bundleID == id }) { Text(selected.label + " (unavailable)").tag(id) }
                    ForEach(model.captureApplications, id: \.bundleID) { app in Text(app.label).tag(app.bundleID ?? "") }
                }
                Button("Refresh applications", action: model.refreshCaptureApplications)
                Text("Applies to the next recording. Selecting a browser captures the whole browser, not an individual tab. A missing app never switches to all computer audio.").font(.caption).foregroundStyle(.secondary)
                Picker("Microphone", selection: $model.settings.microphoneID) {
                    Text("System default").tag("")
                    ForEach(model.microphones) { Text($0.name).tag($0.id) }
                }
                Button("Refresh microphones", action: model.refreshMicrophones)
                Toggle("Record microphone", isOn: Binding(get: { model.settings.microphoneEnabled }, set: model.setMicrophone))
            }
            Section("Behavior") {
                Toggle("Launch at login", isOn: $login).onChange(of: login) { _, value in model.setLogin(value) }
                Picker("Recording shortcut", selection: $model.settings.shortcutKeyCode) {
                    Text("⌘⌥R").tag(UInt32(15)); Text("⌘⌥M").tag(UInt32(46)); Text("⌘⌥Space").tag(UInt32(49))
                }
            }
            Section("Audio check") {
                Button(model.audioCheckRunning ? "Checking audio…" : "Check audio for 10 seconds", action: model.checkAudio)
                    .disabled(model.audioCheckRunning || model.working || model.recording != nil || model.preparingRecording)
                if model.audioCheckRunning {
                    LevelRow(title: "Microphone", value: model.microphoneLevel, enabled: model.settings.microphoneEnabled)
                    LevelRow(title: "Computer", value: model.computerLevel)
                }
                Text(model.audioCheckStatus.isEmpty ? "Checks permissions, audio sources and free disk space. No recording or transcript is saved." : model.audioCheckStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                Text("Microphone and System Audio Recording access are requested when you first record. Screen video is never saved.")
                Button("Open Privacy & Security") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!) }
            }
        }.formStyle(.grouped)
    }
}
struct SpeechSettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section("Transcription") {
                LabeledContent("Active engine", value: model.settings.speech.engine.title)
                Button("Manage transcription models…", action: model.showTranscriptionModels)
                Text("Transcription runs after you stop recording. Microphone and computer audio keep their own labels and timestamps.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Language") {
                if model.settings.speech.engine == .apple {
                    LabeledContent("Language asset", value: model.settings.speech.appleLocale ?? model.settings.speech.language)
                    Text("Select and install Apple language assets in Models → Transcription → Apple.").font(.caption).foregroundStyle(.secondary)
                } else if model.settings.speech.engine == .parakeet {
                    Text(model.settings.speech.parakeetVersion == "v2" ? "English only, determined by the active model." : "Automatic language detection. English and French are preserved without translation.")
                } else if model.settings.speech.engine == .whisper && !ModelManager.whisperIsMultilingual(model.settings.speech.modelPath) {
                    Text("English only, determined by the active model.")
                } else {
                    Picker("Spoken language", selection: Binding(get: {
                        model.settings.speech.engine == .remote ? (model.settings.speech.remoteLanguage ?? model.settings.speech.language) : model.settings.speech.language
                    }, set: { value in
                        if model.settings.speech.engine == .remote { model.settings.speech.remoteLanguage = value }
                        else { model.settings.speech.language = value }
                    })) { Text("Automatic").tag("auto"); Text("English").tag("en"); Text("French").tag("fr") }
                }
            }
            Section("Audio processing") {
                Toggle("Reduce speaker echo after recording", isOn: $model.settings.echoReduction)
                Text("Uses computer audio as the reference. Original audio is preserved; headphones provide the clearest source separation.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Transcript") {
                LabeledContent("Microphone label", value: "Me — Microphone")
                LabeledContent("Computer label", value: "Others — Computer")
                Text("Labels identify audio sources, not individual participants. Transcript files can be edited externally before analysis.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
struct AnalysisSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    var body: some View {
        VStack {
            ProfileControls()
            Picker("Analysis settings", selection: $tab) { Text("Behavior").tag(0); Text("Prompts").tag(1) }.pickerStyle(.segmented).padding(.horizontal)
            if tab == 1 { PromptEditor() }
            else {
                Form {
                    Section("Analysis") {
                        LabeledContent("Active provider", value: model.settings.analysis.engine.title)
                        Button("Manage analysis models…", action: model.showAnalysisModels)
                        Toggle("Analyze automatically after transcription", isOn: $model.settings.analysis.automatic)
                        Picker("Output language", selection: Binding(get: { model.profileDraft?.language ?? "English" }, set: { model.profileDraft?.language = $0 })) { Text("English").tag("English"); Text("French").tag("French"); Text("Spanish").tag("Spanish") }
                    }
                    Section("Profile") {
                        TextField("Profile name", text: Binding(get: { model.profileDraft?.name ?? "" }, set: { model.profileDraft?.name = $0 }))
                        TextField("Default tags (comma separated)", text: Binding(get: { model.profileDraft?.tags.joined(separator: ", ") ?? "" }, set: { model.profileDraft?.tags = $0.components(separatedBy: ",") }))
                        Text("Tags apply to new meetings only. Rename the profile using its name field, then Save Settings.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Enabled analyses") {
                        ForEach(model.definitions.indices, id: \.self) { index in
                            Toggle(model.definitions[index].kind.title, isOn: $model.definitions[index].enabled)
                                .onChange(of: model.definitions[index].enabled) { _, _ in model.savePromptToggles() }
                        }
                    }
                    Text("Customize each analysis in Prompts. Existing results stay unchanged until you regenerate them.").font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped)
            }
        }
    }
}
struct PromptEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var kind: AnalysisKind = .summary
    @State private var draft = ""
    @State private var meeting: UUID?
    @State private var showPreview = false
    @State private var showShared = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Analysis type", selection: $kind) { ForEach(AnalysisKind.allCases) { Text($0.title).tag($0) } }.frame(width: 290)
                if let index = model.definitions.firstIndex(where: { $0.kind == kind }) {
                    Toggle("Enabled", isOn: $model.definitions[index].enabled).onChange(of: model.definitions[index].enabled) { _, _ in model.savePromptToggles() }
                    Text("Revision \(model.definitions[index].revisions.count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("System prompt").font(.headline)
            TextEditor(text: Binding(get: { draft }, set: { value in
                draft = value
                model.promptDrafts[kind] = value
            })).font(.system(.body, design: .monospaced)).border(.quaternary)
            HStack {
                Button("Save prompt") { model.savePrompt(kind, text: draft) }.buttonStyle(.borderedProminent)
                Button("Restore default") { draft = (model.profileDraft?.template ?? .general).prompt(kind); model.savePrompt(kind, text: draft) }
                Button("Shared instructions…") { showShared = true }
            }
            HStack {
                Picker("Test meeting", selection: $meeting) {
                    Text("Select a saved meeting").tag(nil as UUID?)
                    ForEach(model.sessions.filter { $0.firstSuccessfulExport != nil }) { Text($0.stem).tag(Optional($0.id)) }
                }
                Button("Test on saved meeting") { if let session = model.sessions.first(where: { $0.id == meeting }) { model.analyze(session, kind: kind, previewOnly: true, draft: draft); showPreview = true } }.disabled(meeting == nil || model.working)
            }
            Text("Tests use your draft prompt and selected model. Results are preview-only; the meeting file stays unchanged.").font(.caption).foregroundStyle(.secondary)
        }.padding().onAppear { load() }.onChange(of: model.profileDraft?.id) { _, _ in load() }.onChange(of: kind) { _, _ in load() }
        .sheet(isPresented: $showPreview) {
            VStack(alignment: .leading) {
                HStack { Text("Analysis preview").font(.title2); Spacer(); Button("Close") { showPreview = false } }
                if model.working { ProgressView(model.progress) }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                ScrollView { Text(model.preview).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(24).frame(width: 700, height: 500)
        }
        .sheet(isPresented: $showShared) {
            VStack { ScrollView { Text(DefaultPrompts.shared(language: model.profileDraft?.language ?? "English")+"\n\n"+DefaultPrompts.contract).font(.system(.body, design: .monospaced)).textSelection(.enabled) }; Button("Close") { showShared = false } }.padding(24).frame(width: 650, height: 500)
        }
    }
    func load() { draft = model.promptDrafts[kind] ?? model.definitions.first(where: { $0.kind == kind })?.current.text ?? DefaultPrompts.text(for: kind) }
}
struct StorageSettingsView: View {
    @EnvironmentObject var model: AppModel
    var immediate: Binding<Bool> { Binding(get: { model.settings.retention == .afterSuccessfulTranscription }, set: { model.settings.retention = $0 ? .afterSuccessfulTranscription : .afterDays(30) }) }
    var days: Binding<Int> { Binding(get: { if case .afterDays(let days) = model.settings.retention { return days }; return 30 }, set: { model.settings.retention = .afterDays($0) }) }
    var body: some View {
        Form {
            Section("Meeting files") {
                LabeledContent("Output folder") { Text(model.settings.outputFolder).textSelection(.enabled).lineLimit(2) }
                Button("Choose folder…", action: model.chooseFolder)
                Text("Each meeting creates YYYYMMDD - HHmmss.md and a matching .m4a in this folder. Left audio channel: microphone. Right: computer.").font(.caption)
            }
            Section("Audio retention") {
                Toggle("Delete audio immediately after transcription", isOn: immediate)
                if !immediate.wrappedValue { TextField("Delete after days", value: days, format: .number) }
                Text("Default: 30 days from the first successful transcript export. Saving applies the policy to existing and future completed recordings.")
                Text("Only audio and temporary audio files are deleted. Markdown, analysis, personal notes, and history remain. Failed or unfinished recordings are protected. Analysis does not need audio.").font(.caption).foregroundStyle(.secondary)
                Button("Check retention now") { model.saveSettings(); Task { await model.cleanup() } }
            }
        }.formStyle(.grouped)
    }
}
