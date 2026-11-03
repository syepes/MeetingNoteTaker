import SwiftUI
import Carbon
import AVFoundation
import ServiceManagement
import MeetingCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var settings = AppSettings()
    @Published var modelSection: ModelSection = .transcription
    @Published var analysisModelDraft = AnalysisSettings()
    @Published var analysisModelKey = ""
    @Published var analysisClientSecret = ""
    @Published var installedAppleLocales: [String] = []
    @Published var modelBrowserEngine: SpeechEngine?
    @Published var remoteSpeechDraft = RemoteSpeechConfiguration(speech: SpeechSettings())
    @Published var remoteSpeechKey = ""
    @Published var remoteSpeechClientSecret = ""
    @Published var settingsPage: SettingsPage = .general
    @Published var definitions: [AnalysisDefinition] = []
    @Published var profileCatalog: MeetingProfileCatalog?
    @Published var profileDraft: MeetingProfile?
    @Published var promptDrafts: [AnalysisKind: String] = [:]
    @Published var sessions: [MeetingSession] = []
    @Published private(set) var documentUpdateID = UUID()
    @Published var recording: MeetingSession?
    @Published private(set) var deletingMeeting = false
    @Published var working = false
    @Published var progress = "Ready"
    @Published var error: String?
    var recordingMetersVisible = false { didSet { capture?.metersEnabled = recordingMetersVisible } }
    let audioLevels = AudioLevelState()
    @Published var startedAt: Date?
    @Published var models: [InstalledModel] = []
    @Published var modelStatus = ""
    @Published var modelProgress: Double = 0
    @Published var catalogDownloadID: String?
    @Published var catalogDownloadErrors: [String: String] = [:]
    @Published var modelTaskRunning = false
    @Published var preview = ""
    @Published var appleLocales: [String] = []
    @Published var microphones: [MicrophoneDevice] = []
    let persistence: SettingsStore
    let store: SessionStore
    let modelManager: ModelManager
    let pipeline = MeetingPipeline()
    private var capture: CoreAudioCapture?
    private let coordinator = ProcessingCoordinator()
    private var job: Task<Void,Never>? { get { coordinator.task } set { coordinator.task = newValue } }
    @Published var recordingPaused = false
    @Published var captureHealth = CaptureHealthSnapshot()
    @Published var audioCheckRunning = false
    @Published var audioCheckStatus = ""
    @Published var captureApplications: [CaptureTarget] = []
    @Published var memorySuspended = false
    private var memoryPausedJob = false
    private var activeUsesLocalInference = false
    private var memorySource: DispatchSourceMemoryPressure?
    private var memoryRecovery: Task<Void, Never>?
    private var modelJob: Task<Void,Never>?
    private var busyID: UUID?
    @Published private(set) var preparingRecording = false
    private var player: AVAudioPlayer?
    private var retentionTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    var hotkey: GlobalHotkey?
    var profileHotkey: GlobalHotkey?
    var profileChooserWindow: NSWindow?
    init() {
        do {
            let persistence = try SettingsStore(); self.persistence = persistence
            store = try SessionStore(root: persistence.root.appendingPathComponent("sessions"))
            modelManager = try ModelManager(root: persistence.root.appendingPathComponent("models"))
            settings = try persistence.loadSettings()
            if !FileManager.default.fileExists(atPath: persistence.root.appendingPathComponent("meeting-profiles.json").path) { definitions = try persistence.loadPrompts() }
        } catch { fatalError("Cannot open MeetingNoteTaker storage: \(error.localizedDescription)") }
        do {
            let catalog = try MeetingProfileStore(root: persistence.root).loadOrMigrate(settings: settings, definitions: definitions)
            profileCatalog = catalog; loadProfile(catalog.defaultID)
        } catch { self.error = error.localizedDescription }
        remoteSpeechDraft = .init(speech: settings.speech)
        do {
            try KeychainStore.migrateSpeechKey(endpoint: settings.speech.endpoint)
            try KeychainStore.migrateAnalysisKey(endpoint: settings.analysis.endpoint)
            remoteSpeechKey = KeychainStore.get(RemoteSpeechConfiguration.credentialAccount(endpoint: settings.speech.endpoint))
            reloadSpeechClientSecret()
        } catch { self.error = error.localizedDescription }
        browseAnalysisProvider(settings.analysis.engine == .unconfigured ? .builtin : settings.analysis.engine)
        refreshMicrophones(); refreshCaptureApplications(); watchMemory()
        hotkey = GlobalHotkey { [weak self] in Task { @MainActor in self?.toggleRecording() } }
        profileHotkey = GlobalHotkey(id: 2) { [weak self] in Task { @MainActor in self?.showProfileChooser() } }
        configureHotkey()
        configureDefaultLogin()
        Task { appleLocales = await ModelManager.appleLocales(); installedAppleLocales = await ModelManager.installedAppleLocales() }
        Task { await reload(); await refreshModels(); await recover(); await cleanup(); resumeQueuedWork() }
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor in await self?.cleanup() } }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stopRecording(interrupted: true) } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.cleanup(); self?.refreshMicrophones(); self?.resumeQueuedWork() } })
    }
    var captureHealthText: String {
        "Microphone: \(captureHealth.microphone.message) · Computer: \(captureHealth.computer.message)" +
            (captureHealth.microphone.droppedBuffers + captureHealth.computer.droppedBuffers > 0 ? " · \(captureHealth.microphone.droppedBuffers + captureHealth.computer.droppedBuffers) buffers dropped" : "")
    }
    func quit() {
        guard !deletingMeeting, recording == nil, !preparingRecording, !audioCheckRunning else { return }
        Task { await coordinator.cancelAndWait(); NSApp.terminate(nil) }
    }
    func configureHotkey() {
        do { try hotkey?.register(keyCode: settings.shortcutKeyCode, modifiers: settings.shortcutModifiers) }
        catch { self.error = error.localizedDescription }
        do { try profileHotkey?.register(keyCode: settings.shortcutKeyCode, modifiers: settings.shortcutModifiers | UInt32(shiftKey)) }
        catch { self.error = error.localizedDescription }
    }
    func refreshMicrophones() {
        Task { microphones = await AudioDevices.discoverMicrophones() }
    }
    func refreshCaptureApplications() { captureApplications = AudioApplications.available() }
    private func watchMemory() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.memoryRecovery?.cancel()
                if source.data.contains(.critical) {
                    self.memorySuspended = true
                    if self.recording == nil, self.working, self.busyID != nil, self.activeUsesLocalInference {
                        self.memoryPausedJob = true
                        self.job?.cancel()
                        self.progress = "Processing paused — critical memory pressure"
                    }
                } else if source.data.contains(.normal), self.memorySuspended {
                    self.memoryRecovery = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                        guard let self else { return }
                        self.memorySuspended = false; self.resumeQueuedWork()
                    }
                }
            }
        }
        memorySource = source; source.resume()
    }
    func togglePause() {
        guard let capture, recording != nil else { return }
        if recordingPaused { capture.resume() } else { capture.pause() }
        recordingPaused.toggle()
    }
    func checkAudio() {
        guard !deletingMeeting, recording == nil, !working, !preparingRecording, !audioCheckRunning else { return }
        audioCheckRunning = true; audioCheckStatus = "Checking permissions and audio…"
        Task {
            let check = CoreAudioCapture(); check.microphoneEnabled = settings.microphoneEnabled
            check.onLevels = { [weak self] mic, computer in self?.audioLevels.update(microphone: mic, computer: computer) }
            check.onHealth = { [weak self] health in
                self?.audioCheckStatus = "Microphone: \(health.microphone.message). Computer: \(health.computer.message)." + (health.storageWarning.map { " " + $0 } ?? "")
            }
            check.onFatal = { [weak self] message in self?.audioCheckStatus = message }
            do {
                try await check.startCheck(folder: URL(fileURLWithPath: settings.outputFolder), target: settings.captureTarget ?? .init(), microphoneID: settings.microphoneID)
                try await Task.sleep(for: .seconds(10))
                _ = try await check.stop()
                audioCheckStatus += " Check complete; no audio saved."
            } catch { _ = try? await check.stop(); audioCheckStatus = error.localizedDescription }
            audioCheckRunning = false; audioLevels.update(microphone: 0, computer: 0)
        }
    }
    func saveSettings() {
        do { try persistence.save(settings); configureHotkey(); progress = "Settings saved"; Task { await cleanup() } }
        catch { self.error = error.localizedDescription }
    }
    func saveVisibleSettings() {
        if settingsPage == .analysis { guard saveProfile() else { return }; saveSettings(); return }
        if settingsPage == .models && modelSection == .analysis { _ = saveAnalysisModel(activate: analysisModelDraft.hasModelSelection) }
        else if settingsPage == .models && (modelBrowserEngine ?? settings.speech.engine) == .remote { _ = saveRemoteSpeech(activate: remoteSpeechDraft.hasModelSelection) }
        else { saveSettings() }
    }
    @discardableResult func saveRemoteSpeech(activate: Bool) -> Bool {
        do {
            var draft = remoteSpeechDraft
            draft.language = settings.speech.remoteLanguage ?? RemoteSpeechConfiguration(speech: settings.speech).language
            draft = try draft.validated(requireModel: activate)
            let updated = try draft.applying(to: settings, activate: activate)
            if let auth = draft.authentication, auth.method == .oauthClientCredentials {
                guard !remoteSpeechClientSecret.isEmpty else { throw MeetingError.message("Enter an OAuth client secret.") }
                try KeychainStore.set(remoteSpeechClientSecret, account: auth.secretAccount(purpose: "speech", endpoint: draft.endpoint))
            } else {
                try KeychainStore.set(remoteSpeechKey.trimmingCharacters(in: .whitespacesAndNewlines), account: RemoteSpeechConfiguration.credentialAccount(endpoint: draft.endpoint))
            }
            try persistence.save(updated)
            settings = updated; remoteSpeechDraft = draft; error = nil
            progress = activate ? "Server active · \(draft.model)" : "Server settings saved"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func reloadSpeechClientSecret() {
        remoteSpeechClientSecret = KeychainStore.get((remoteSpeechDraft.authentication ?? .init()).secretAccount(purpose: "speech", endpoint: remoteSpeechDraft.endpoint))
    }
    func reloadAnalysisClientSecret() {
        analysisClientSecret = KeychainStore.get((analysisModelDraft.authentication ?? .init()).secretAccount(purpose: "analysis", endpoint: analysisModelDraft.endpoint))
    }
    func showServerSettings() { modelSection = .transcription; modelBrowserEngine = .remote; settingsPage = .models }
    func browseAnalysisProvider(_ engine: LLMEngine) {
        if let profile = settings.analysisProfiles?[engine.rawValue] { analysisModelDraft = profile }
        else if settings.analysis.engine == engine { analysisModelDraft = settings.analysis }
        else {
            analysisModelDraft = AnalysisSettings(); analysisModelDraft.engine = engine
            analysisModelDraft.endpoint = engine == .compatible ? "http://localhost:1234/v1" : "http://localhost:11434"
        }
        analysisModelKey = KeychainStore.get(KeychainStore.analysisAccount(endpoint: analysisModelDraft.endpoint))
        reloadAnalysisClientSecret()
    }
    @discardableResult func saveAnalysisModel(activate: Bool) -> Bool {
        do {
            var draft = analysisModelDraft
            guard draft.engine != .unconfigured else { throw MeetingError.message("Choose an analysis provider.") }
            if draft.engine != .builtin {
                draft.endpoint = try RemoteSpeechConfiguration.normalizedEndpoint(draft.endpoint)
                draft.authentication = try draft.authentication?.validated(endpoint: draft.endpoint)
            }
            if draft.engine == .builtin, let installed = models.first(where: { $0.kind == .gguf && ModelManager.sameLocation(draft.modelPath, $0.url) }),
               let id = installed.catalogID, let entry = AnalysisModelCatalog.entry(id) {
                draft = entry.configuring(draft, path: installed.url.path, resetBudgets: draft.catalogModel != entry.identity)
            } else { draft.catalogModel = nil; draft.inferencePreset = nil }
            draft.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard draft.contextTokens >= 2048, draft.outputTokens >= 128, draft.outputTokens < draft.contextTokens / 2 else { throw MeetingError.message("Use at least 2048 context tokens and an output budget below half the context.") }
            if activate {
                if draft.engine == .builtin { try ModelManager.validateFile(URL(fileURLWithPath: draft.modelPath), kind: .gguf) }
                else if draft.model.isEmpty { throw MeetingError.message("Choose or enter an analysis model before activation.") }
            }
            let updated = draft.applyingModelConfiguration(to: settings, activate: activate)
            if draft.engine != .builtin {
                if let auth = draft.authentication, auth.method == .oauthClientCredentials {
                    guard !analysisClientSecret.isEmpty else { throw MeetingError.message("Enter an OAuth client secret.") }
                    try KeychainStore.set(analysisClientSecret, account: auth.secretAccount(purpose: "analysis", endpoint: draft.endpoint))
                } else {
                    try KeychainStore.set(analysisModelKey.trimmingCharacters(in: .whitespacesAndNewlines), account: KeychainStore.analysisAccount(endpoint: draft.endpoint))
                }
            }
            try persistence.save(updated); settings = updated; analysisModelDraft = draft; error = nil
            progress = activate ? "Analysis model settings saved and active" : "Provider settings saved. Select a model to activate it."
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func showAnalysisModels() { modelSection = .analysis; settingsPage = .models }
    func showTranscriptionModels() { modelSection = .transcription; modelBrowserEngine = settings.speech.engine; settingsPage = .models }
    func activateApple(_ locale: String) {
        guard installedAppleLocales.contains(locale) else { error = "Install this Apple Speech language before activating it."; return }
        settings.speech.engine = .apple; settings.speech.appleLocale = locale; saveSettings()
    }
    func reload() async { do { sessions = try await store.load(); documentUpdateID = UUID() } catch { self.error = error.localizedDescription } }
    func refreshModels() async { do { models = try await modelManager.installed() } catch { self.error = error.localizedDescription } }
    func toggleRecording() { if recording != nil { stopRecording() } else { startRecording() } }
    func startRecording(profileID: UUID? = nil) {
        guard !deletingMeeting, recording == nil, !preparingRecording, !audioCheckRunning else { return }
        let selectedProfile: MeetingProfileSnapshot
        do { selectedProfile = try resolveProfile(override: profileID) } catch { self.error = error.localizedDescription; return }
        let recordingSettings = settings
        preparingRecording = true
        let previous = job; let token = coordinator.begin(); previous?.cancel()
        job = Task {
            await pipeline.cancel(); await previous?.value
            guard coordinator.owns(token) else { return }
            defer { preparingRecording = false }
            do {
                var session = try await store.reserve(settings: recordingSettings, profile: selectedProfile)
                if recordingSettings.analysis.automatic && recordingSettings.analysis.engine != .unconfigured {
                    session.analysisSnapshot = selectedProfile.configuring(recordingSettings.analysis)
                    session.promptSnapshot = selectedProfile.definitions.filter(\.enabled)
                    session.analysisPending = session.promptSnapshot?.map(\.kind) ?? []
                }
                try await store.save(session)
                let capture = CoreAudioCapture(); self.capture = capture
                capture.microphoneEnabled = settings.microphoneEnabled
                capture.metersEnabled = recordingMetersVisible
                capture.onLevels = { [weak self] mic, computer in self?.audioLevels.update(microphone: mic, computer: computer) }
                capture.onHealth = { [weak self] health in
                    guard let self, self.coordinator.owns(token) else { return }
                    self.captureHealth = health
                    if self.progress != health.summary { self.progress = health.summary }
                }
                capture.onFatal = { [weak self] text in
                    guard let self, self.coordinator.owns(token) else { return }
                    self.error = text; self.stopRecording(interrupted: true)
                }
                refreshMicrophones()
                refreshCaptureApplications()
                working = true; progress = "Requesting audio access…"
                do { try await capture.start(session: session, microphoneID: settings.microphoneID) }
                catch { var failed = session; failed.status = .interrupted; failed.error = error.localizedDescription; try await store.save(failed); throw error }
                session.captureStartedAt = capture.wallStart; try await store.save(session)
                recording = session; recordingPaused = false; startedAt = capture.wallStart; progress = capture.health.summary; working = false
                if let failure = capture.fatalError { error = failure; stopRecording(interrupted: true) }
                await reload()
            } catch { self.error = error.localizedDescription; self.capture = nil; working = false; await reload() }
        }
    }
    func stopRecording(interrupted: Bool = false) {
        guard var session = recording, let capture else { return }
        let token = coordinator.begin()
        recording = nil; recordingPaused = false; startedAt = nil; working = true; progress = "Saving audio…"
        job = Task {
            do {
                session.events += try await capture.stop(); session.duration = capture.stoppedElapsed
                self.capture = nil; audioLevels.update(microphone: 0, computer: 0)
                if interrupted { session.events.append(.init(time: Date().timeIntervalSince(session.startedAt), message: "Recording ended because the Mac went to sleep.")) }
                session.status = .interrupted; session.queuedForProcessing = true; try await store.save(session)
                let finalized = try await pipeline.finalize(session, store: store)
                await reload(); guard coordinator.owns(token) else { return }; working = false
                if !interrupted { process(finalized, resume: true) }
            } catch {
                session.duration = max(session.duration, capture.stoppedElapsed)
                session.status = .interrupted; session.error = error.localizedDescription; try? await store.save(session)
                if coordinator.owns(token) { self.capture = nil; self.error = error.localizedDescription; working = false; audioLevels.update(microphone: 0, computer: 0); await reload() }
            }
        }
    }
    func setMicrophone(_ enabled: Bool) {
        settings.microphoneEnabled = enabled
        if enabled, recording != nil, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio); capture?.microphoneEnabled = settings.microphoneEnabled }
        } else { capture?.microphoneEnabled = enabled }
    }
    func recoverSession(_ session: MeetingSession) {
        guard session.deletionRequestedAt == nil else { return }
        guard !deletingMeeting, !working, recording == nil, !preparingRecording, !audioCheckRunning, !memorySuspended else { return }; working = true; progress = "Recovering audio…"
        let token = coordinator.begin()
        job = Task {
            do { let result = try await pipeline.finalize(session, store: store); await reload(); guard coordinator.owns(token) else { return }; working = false; process(result, resume: true) }
            catch { if coordinator.owns(token) { self.error = error.localizedDescription; working = false } }
        }
    }
    private func resumeQueuedWork() {
        guard !deletingMeeting, !working, recording == nil, !preparingRecording, !audioCheckRunning, !memorySuspended else { return }
        if let next = sessions.reversed().first(where: { $0.deletionRequestedAt == nil && $0.queuedForProcessing == true && ($0.status == .recorded || $0.status == .complete) }) {
            process(next, resume: true)
        }
    }
    private func finishJob(_ id: UUID, token: UUID, preview: Bool = false) async {
        guard coordinator.owns(token) else { return }
        // A cancellation caused by starting a recording retains the durable queue entry.
        if !preview, !Task.isCancelled, var current = try? await store.load().first(where: { $0.id == id }) {
            current.queuedForProcessing = false; try? await store.save(current)
        }
        guard coordinator.owns(token) else { return }
        working = false; busyID = nil; await reload()
        if !Task.isCancelled || (memoryPausedJob && !memorySuspended) { memoryPausedJob = false; resumeQueuedWork() }
    }
    func process(_ original: MeetingSession, useCurrentSettings: Bool = false, resume: Bool = false) {
        guard original.deletionRequestedAt == nil else { return }
        guard !deletingMeeting, !working, recording == nil, !preparingRecording, !audioCheckRunning else { return }
        let retryProfile: MeetingProfileSnapshot?
        do {
            // Retrying transcription keeps the recording's profile, including
            // after profile deletion. Manual Analyze separately resolves latest.
            if resume { retryProfile = nil }
            else if let captured = original.profileSnapshot { retryProfile = captured }
            else { retryProfile = try resolveProfile(for: original) }
        } catch { self.error = error.localizedDescription; return }
        let localSpeech = (original.status != .complete || useCurrentSettings) && (useCurrentSettings ? settings.speech.engine : original.speech.engine) != .remote
        let localAnalysis = (resume ? !original.analysisPending.isEmpty : settings.analysis.automatic) && (resume ? original.analysisSnapshot?.engine : settings.analysis.engine) == .builtin
        guard !memorySuspended || !(localSpeech || localAnalysis) else { progress = "Processing paused — waiting for memory pressure to clear"; return }
        activeUsesLocalInference = localSpeech || localAnalysis
        let token = coordinator.begin()
        working = true; busyID = original.id
        var session = original
        let attempt: TranscriptionAttempt = useCurrentSettings ? .restart(settings: settings.speech, echoReduction: settings.echoReduction) : .resume
        error = nil
        if let retryProfile {
            session.profileSnapshot = retryProfile
            session.analysisSnapshot = retryProfile.configuring(settings.analysis)
            session.promptSnapshot = retryProfile.definitions.filter(\.enabled)
            session.analysisPending = settings.analysis.automatic && settings.analysis.engine != .unconfigured ? session.promptSnapshot!.map(\.kind) : []
        }
        session.queuedForProcessing = true
        job = Task {
            do {
                try await store.save(session)
                var result = session
                if result.status != .complete || useCurrentSettings {
                    activeUsesLocalInference = (useCurrentSettings ? settings.speech.engine : session.speech.engine) != .remote
                    result = try await pipeline.transcribe(session, store: store, attempt: attempt, progress: { text in await MainActor.run { if self.coordinator.owns(token) { self.progress = text } } })
                }
                result = try await applyRetention(result)
                if let config = result.analysisSnapshot, !result.analysisPending.isEmpty {
                    activeUsesLocalInference = config.engine == .builtin
                    if memorySuspended && activeUsesLocalInference { memoryPausedJob = true; job?.cancel(); throw CancellationError() }
                    let prompts = (result.promptSnapshot ?? []).filter { result.analysisPending.contains($0.kind) }
                    let analyzed = try await pipeline.analyze(result, settings: config, definitions: prompts, store: store, progress: { text in await MainActor.run { if self.coordinator.owns(token) { self.progress = text } } }); result = analyzed.0
                }
                if coordinator.owns(token) { progress = "Saved \(result.stem)" }
            } catch {
                if !Task.isCancelled, coordinator.owns(token) { self.error = error.localizedDescription; progress = "Processing needs attention" }
            }
            await finishJob(session.id, token: token)
        }
    }
    func analyze(_ session: MeetingSession, kind: AnalysisKind? = nil, previewOnly: Bool = false, draft: String? = nil, profileID: UUID? = nil, useSavedProfile: Bool = false) {
        guard !deletingMeeting, !working, recording == nil, !preparingRecording, !audioCheckRunning else { return }
        guard !memorySuspended || settings.analysis.engine != .builtin else { progress = "Processing paused — waiting for memory pressure to clear"; return }
        guard session.deletionRequestedAt == nil else { return }
        activeUsesLocalInference = settings.analysis.engine == .builtin
        let profile: MeetingProfileSnapshot
        do {
            if previewOnly, var editing = profileDraft { editing.definitions = definitions; profile = editing.snapshot }
            else { profile = try resolveProfile(for: session, override: profileID, useSaved: useSavedProfile) }
        } catch { self.error = error.localizedDescription; return }
        var prompts = profile.definitions.filter { kind == nil ? $0.enabled : $0.kind == kind }
        if let draft, !prompts.isEmpty { prompts[0].revisions.append(.init(text: draft)) }
        let config = profile.configuring(settings.analysis)
        var request = session
        request.profileSnapshot = profile
        if !previewOnly { for prompt in prompts { request.analysisCheckpoints?[prompt.kind] = nil } }
        if previewOnly { preview = "" }
        let token = coordinator.begin()
        working = true; busyID = session.id
        job = Task {
            do {
                if !previewOnly { var queued = request; queued.queuedForProcessing = true; queued.analysisSnapshot = config; queued.promptSnapshot = prompts; queued.analysisPending = prompts.map(\.kind); try await store.save(queued) }
                let (_, results) = try await pipeline.analyze(request, settings: config, definitions: prompts, store: store, preview: previewOnly, progress: { text in await MainActor.run { if self.coordinator.owns(token) { self.progress = text } } })
                try Task.checkCancellation(); guard coordinator.owns(token) else { return }
                if previewOnly { let segments = try MarkdownExporter.readTranscript(session.markdownURL); preview = results.map { MarkdownExporter.renderAnalysis($0, segments: segments) }.joined(separator: "\n\n") }
                progress = previewOnly ? "Preview ready — file unchanged" : "Analysis saved"; await reload()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription }; await reload() }
            await finishJob(session.id, token: token, preview: previewOnly)
        }
    }
    func cancelWork() {
        let cancelled = job; let id = busyID; let token = coordinator.id
        memoryPausedJob = false
        cancelled?.cancel()
        Task {
            await pipeline.cancel(); await cancelled?.value
            guard coordinator.owns(token) else { return }
            if let id, var session = try? await store.load().first(where: { $0.id == id }) {
                session.queuedForProcessing = false; try? await store.save(session); await reload()
            }
        }
        progress = "Cancelling…"
    }
    func savePrompt(_ kind: AnalysisKind, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, var catalog = profileCatalog,
              let p = catalog.profiles.firstIndex(where: { $0.id == profileDraft?.id }),
              let d = catalog.profiles[p].definitions.firstIndex(where: { $0.kind == kind }) else { return }
        catalog.profiles[p].definitions[d].revisions.append(.init(text: text)); catalog.profiles[p].revision += 1
        do {
            try MeetingProfileStore(root: persistence.root).save(catalog); profileCatalog = catalog
            profileDraft?.revision = catalog.profiles[p].revision
            profileDraft?.definitions[d].revisions = catalog.profiles[p].definitions[d].revisions
            definitions[d].revisions = catalog.profiles[p].definitions[d].revisions
            promptDrafts.removeValue(forKey: kind); progress = "\(kind.title) prompt saved"; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func savePromptToggles() { /* Saved with the profile through Save Settings. */ }
    private func recover() async {
        for var session in sessions where session.deletionRequestedAt == nil {
            if session.status == .recording { session.status = .interrupted; session.error = "Recording was interrupted. Recover the saved audio from the meeting list."; try? await store.save(session) }
            else if session.status == .transcribing { session.status = .recorded; session.error = "Transcription was interrupted; resuming the saved job."; session.queuedForProcessing = true; try? await store.save(session) }
        }
        await reload()
    }
    private func applyRetention(_ session: MeetingSession) async throws -> MeetingSession {
        let policy = settings.retention
        let task = Task.detached { try RetentionService.apply(session, policy: policy) }
        let updated = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try await store.save(updated); return updated
    }
    func cleanup() async {
        guard !deletingMeeting, recording == nil, !working, !preparingRecording else { return }
        do {
            let failures = try await store.cleanup(policy: settings.retention)
            if let first = failures.first { progress = "Cleanup deferred: \(first)" }
        } catch { progress = "Cleanup deferred: \(error.localizedDescription)" }
        await reload()
    }
    func play(_ session: MeetingSession) { guard !deletingMeeting, session.deletionRequestedAt == nil else { return }; do { player?.stop(); player = try AVAudioPlayer(contentsOf: session.audioURL); player?.play() } catch { self.error = error.localizedDescription } }
    func stopPlayback() { player?.stop() }
    var canDeleteMeeting: Bool {
        !deletingMeeting && !working && recording == nil && !preparingRecording && !audioCheckRunning
    }
    func deleteMeeting(_ id: UUID) async -> Bool {
        guard canDeleteMeeting, sessions.contains(where: { $0.id == id }) else { return false }
        deletingMeeting = true
        defer { deletingMeeting = false; resumeQueuedWork() }
        stopPlayback(); player = nil; error = nil; progress = "Moving meeting to Trash…"
        do {
            try await store.trashMeeting(id)
            await reload(); preview = ""; progress = "Meeting moved to Trash"
            return true
        } catch {
            self.error = error.localizedDescription
            progress = "Deletion incomplete — retry in Meetings"
            await reload()
            return false
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { settings.outputFolder = url.path; saveSettings() }
    }
    func importModel(_ kind: ModelKind) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = kind == .parakeet; panel.canChooseFiles = kind != .parakeet
        if kind == .parakeet { panel.message = "Choose the complete model folder. Include config.json to identify Parakeet Ultra, even if the folder has been renamed." }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelTaskRunning = true
        modelJob = Task {
            defer { modelTaskRunning = false }
            do { let result = try await modelManager.importModel(url, kind: kind); try Task.checkCancellation(); await refreshModels(); modelStatus = "Imported: \(result.lastPathComponent). Activate it to use this model."; progress = modelStatus }
            catch { self.error = error.localizedDescription }
        }
    }
    func selectModel(_ url: URL, kind: ModelKind) {
        let parakeetVersion: String?
        do {
            try ModelManager.validateFile(url, kind: kind)
            parakeetVersion = kind == .parakeet ? try ModelManager.parakeetVersion(at: url) : nil
        } catch { self.error = error.localizedDescription; return }
        if kind == .gguf {
            analysisModelDraft.engine = .builtin; analysisModelDraft.modelPath = url.path
            _ = saveAnalysisModel(activate: true); return
        }
        else {
            settings.speech.engine = kind == .whisper ? .whisper : .parakeet; settings.speech.modelPath = url.path
            settings.speech.language = "auto"
            if let parakeetVersion { settings.speech.parakeetVersion = parakeetVersion }
            if kind == .whisper, !ModelManager.whisperIsMultilingual(url.path) { settings.speech.language = "en" }
        }
        saveSettings()
    }
    func downloadModel(_ kind: ModelKind, name: String) {
        modelTaskRunning = true; modelProgress = 0; modelStatus = "Downloading \(name)…"; error = nil
        modelJob = Task {
            defer { modelTaskRunning = false }
            do {
                let update: @Sendable (Double) -> Void = { [weak self] value in Task { @MainActor in self?.modelProgress = value } }
                let url = kind == .whisper ? try await modelManager.downloadWhisper(name: name, progress: update) : try await modelManager.downloadParakeet(version: name, progress: update, status: { [weak self] status in Task { @MainActor in self?.modelStatus = status } })
                try Task.checkCancellation()
                await refreshModels()
                modelStatus = "Installed: \(url.lastPathComponent). Activate it to use this model."; progress = modelStatus
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func downloadAnalysisModel(_ entry: AnalysisCatalogEntry) {
        guard !modelTaskRunning, !working, recording == nil else { return }
        modelTaskRunning = true; catalogDownloadID = entry.id; catalogDownloadErrors[entry.id] = nil
        modelProgress = 0; modelStatus = "Preparing \(entry.title)…"; error = nil
        modelJob = Task { [self] in
            defer { modelTaskRunning = false; catalogDownloadID = nil }
            do {
                _ = try await modelManager.downloadGGUF(id: entry.id, progress: { [weak self] value in
                    Task { @MainActor in self?.modelProgress = value }
                }, status: { [weak self] status in
                    Task { @MainActor in self?.modelStatus = status }
                })
                try Task.checkCancellation(); await refreshModels()
                modelStatus = "Installed: \(entry.title). Activate it to use this model."; progress = modelStatus
            } catch {
                let message = Task.isCancelled ? "Download cancelled. Retry when ready." : error.localizedDescription
                catalogDownloadErrors[entry.id] = message; modelStatus = message
                if !Task.isCancelled { self.error = message }
                await refreshModels()
            }
        }
    }
    func cancelDownload() { modelJob?.cancel() }
    func removeModel(_ installed: InstalledModel) {
        guard !deletingMeeting, !working, recording == nil, !modelTaskRunning else { return }
        Task {
            do {
                try await modelManager.remove(installed.url)
                for (engine, path) in settings.speech.modelPaths where ModelManager.sameLocation(path, installed.url) {
                    settings.speech.modelPaths.removeValue(forKey: engine)
                }
                if ModelManager.sameLocation(settings.analysis.modelPath, installed.url) {
                    settings.analysis.modelPath = ""; settings.analysis.catalogModel = nil; settings.analysis.inferencePreset = nil
                }
                if var profiles = settings.analysisProfiles {
                    for (provider, var profile) in profiles where ModelManager.sameLocation(profile.modelPath, installed.url) { profile.modelPath = ""; profile.catalogModel = nil; profile.inferencePreset = nil; profiles[provider] = profile }
                    settings.analysisProfiles = profiles
                }
                if ModelManager.sameLocation(analysisModelDraft.modelPath, installed.url) { analysisModelDraft.modelPath = ""; analysisModelDraft.catalogModel = nil; analysisModelDraft.inferencePreset = nil }
                saveSettings(); await refreshModels()
                modelStatus = "Removed \(installed.url.lastPathComponent)"; progress = modelStatus
            } catch { self.error = error.localizedDescription }
        }
    }
    func installApple(locale: String) {
        modelTaskRunning = true
        modelJob = Task {
            defer { modelTaskRunning = false }
            do { try await ModelManager.installApple(locale: locale); installedAppleLocales = await ModelManager.installedAppleLocales(); progress = "Apple Speech language installed" }
            catch { self.error = error.localizedDescription }
        }
    }
    private func configureDefaultLogin() {
        let key = "launchAtLoginDefaultConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        // Existing installations keep their macOS login-item choice, including opt-outs.
        guard !FileManager.default.fileExists(atPath: persistence.root.appendingPathComponent("settings.json").path),
              SMAppService.mainApp.status == .notRegistered else { return }
        setLogin(true)
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { self.error = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
