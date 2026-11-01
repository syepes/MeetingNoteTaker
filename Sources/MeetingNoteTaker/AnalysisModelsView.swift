import SwiftUI
import MeetingCore

struct AnalysisModelsView: View {
    @EnvironmentObject var model: AppModel
    let accent: Color
    let surface: Color
    let border: Color
    let busy: Bool
    @State private var removal: InstalledModel?
    @State private var modelIDs: [String] = []
    @State private var connectionMessage = ""
    @State private var connectionFailed = false
    @State private var testing = false
    @State private var connectionTask: Task<Void, Never>?
    private var engine: LLMEngine { model.analysisModelDraft.engine }
    private var activeName: String? {
        let settings = model.settings.analysis
        if settings.engine == .builtin {
            guard FileManager.default.fileExists(atPath: settings.modelPath) else { return nil }
            if let id = settings.catalogModel?.id, let entry = AnalysisModelCatalog.entry(id) { return entry.title }
            return URL(fileURLWithPath: settings.modelPath).deletingPathExtension().lastPathComponent
        }
        return settings.engine == .unconfigured || settings.model.isEmpty ? nil : "\(settings.engine.title) · \(settings.model)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Analysis provider").font(.headline).fixedSize()
                    Spacer()
                    ModelBadge(text: activeName.map { "Active · " + $0 } ?? "No active model", kind: activeName == nil ? .inactive : .active)
                }
                HStack(spacing: 10) {
                    providerCard(.builtin, title: "Built-in local", detail: "GGUF · Metal on this Mac")
                    providerCard(.ollama, title: "Ollama", detail: "Models installed on your server")
                    providerCard(.compatible, title: "Server", detail: "OpenAI-compatible API")
                }
            }
            if engine == .builtin { suggestedModels; localModels }
            else { serverSettings }
            card {
                Text("Model configuration").font(.headline)
                HStack {
                    Text("Context tokens"); Spacer()
                    TextField("8192", value: $model.analysisModelDraft.contextTokens, format: .number.grouping(.never)).frame(width: 130)
                }
                HStack {
                    Text("Maximum output tokens"); Spacer()
                    TextField("1536", value: $model.analysisModelDraft.outputTokens, format: .number.grouping(.never)).frame(width: 130)
                }
                Text("Use the context size supported by this model. The output budget must be below half the context.").font(.caption).foregroundStyle(.secondary)
                if engine == .compatible {
                    Toggle("Use structured JSON schema output", isOn: $model.analysisModelDraft.structuredOutput)
                    Text("Enable only when the server supports json_schema responses. Otherwise the app requests and validates JSON.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Activate a model from the list, or use Save Settings to apply the selected model and configuration. Browsing providers does not change the active model.")
                .font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder)
            .onChange(of: engine) { _, _ in resetConnection() }
            .onChange(of: model.analysisModelDraft.endpoint) { old, new in
                resetConnection()
                if KeychainStore.analysisAccount(endpoint: old) != KeychainStore.analysisAccount(endpoint: new) {
                    model.analysisModelKey = KeychainStore.get(KeychainStore.analysisAccount(endpoint: new))
                }
                model.reloadAnalysisClientSecret()
            }
            .onChange(of: model.analysisModelDraft.authentication) { old, new in
                resetConnection()
                if (old ?? .init()).secretAccount(purpose: "analysis", endpoint: model.analysisModelDraft.endpoint) != (new ?? .init()).secretAccount(purpose: "analysis", endpoint: model.analysisModelDraft.endpoint) { model.reloadAnalysisClientSecret() }
            }
            .onChange(of: model.analysisClientSecret) { _, _ in resetConnection() }
            .onChange(of: model.analysisModelKey) { _, _ in resetConnection() }
            .onDisappear { cancelTest() }
            .confirmationDialog("Remove \(removal?.url.lastPathComponent ?? "model")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                if let item = removal { Button("Remove model", role: .destructive) { model.removeModel(item); removal = nil } }
                Button("Cancel", role: .cancel) { removal = nil }
            } message: { Text("Only the app’s copy is removed. Original imports and meeting files are preserved.") }
    }
    private var suggestedModels: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model").font(.headline)
                Spacer()
                Button { model.importModel(.gguf) } label: { Label("Import GGUF…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.plain).foregroundStyle(accent).disabled(busy)
            }
            VStack(spacing: 0) {
                ForEach(Array(AnalysisModelCatalog.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().overlay(border) }
                    catalogRow(entry)
                }
            }.background(surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
            Text("Downloads contain model weights only. Runtime memory is higher than download size and grows with context. Nothing is activated automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func catalogRow(_ entry: AnalysisCatalogEntry) -> some View {
        let installed = model.models.first { $0.catalogID == entry.id }
        let downloading = model.catalogDownloadID == entry.id
        let failure = model.catalogDownloadErrors[entry.id]
        let detail = "\(entry.detail) · \(entry.quantization)" + (installed == nil ? "" : " · Installed") + " · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))"
        return VStack(alignment: .leading, spacing: 0) {
            ModelRow(title: entry.title, detail: detail, recommended: entry.balanced, sourceURL: entry.sourceURL, sourceLabel: "Source · \(entry.license)") {
                if let item = installed {
                    installedActions(item, name: entry.title)
                } else if downloading {
                    Button("Cancel", action: model.cancelDownload).accessibilityLabel("Cancel \(entry.title) download")
                } else {
                    Button(failure == nil ? "Download" : "Retry") { model.downloadAnalysisModel(entry) }
                        .disabled(busy).accessibilityLabel("\(failure == nil ? "Download" : "Retry") \(entry.title)")
                }
            }
            if downloading {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: model.modelProgress).tint(accent)
                    Text(model.modelStatus).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.bottom, 14)
            } else if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            }
        }
    }
    @ViewBuilder private func installedActions(_ item: InstalledModel, name: String) -> some View {
        if model.settings.analysis.engine == .builtin && ModelManager.sameLocation(model.settings.analysis.modelPath, item.url) {
            ModelBadge(text: "Active")
        } else {
            Button("Activate") { model.selectModel(item.url, kind: .gguf) }.buttonStyle(.bordered).disabled(busy).accessibilityLabel("Activate \(name)")
        }
        ModelRemoveButton(name: name, disabled: busy) { removal = item }
    }
    private var localModels: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Imported models").font(.headline)
            let installed = model.models.filter { $0.kind == .gguf && $0.catalogID == nil }
            if installed.isEmpty {
                Text("No imported models. Use a suggested download above or import your own compatible instruction-tuned GGUF.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(installed.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(border) }
                        ModelRow(title: item.url.deletingPathExtension().lastPathComponent,
                                 detail: "Installed · Imported · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))") {
                            installedActions(item, name: item.url.lastPathComponent)
                        }
                    }
                }.background(surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
            }
            card {
                TextField("Path to an external GGUF model (optional)", text: $model.analysisModelDraft.modelPath).accessibilityLabel("GGUF model path")
                Text("Imported originals are preserved. External models stay at their existing location. No model is downloaded or selected automatically.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var serverSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            card {
                Text(engine == .ollama ? "Ollama server" : "Server").font(.headline)
                Text("Analysis sends transcript text and necessary metadata to this server, without audio.").font(.callout).foregroundStyle(accent)
                Divider()
                LabeledContent("Server URL") {
                    TextField(engine == .ollama ? "http://localhost:11434" : "http://localhost:1234/v1", text: $model.analysisModelDraft.endpoint).frame(width: 330)
                }
                Text("Include http:// or https://. Compatible servers normally use an API prefix such as /v1; Ollama uses its server root.").font(.caption).foregroundStyle(.secondary)
                Divider()
                ServerAuthenticationFields(configuration: $model.analysisModelDraft.authentication, apiKey: $model.analysisModelKey,
                    clientSecret: $model.analysisClientSecret, credentialLabel: "Analysis server API key")
                Divider()
                HStack {
                    Text("Connection").font(.headline); Spacer()
                    if testing { ProgressView().controlSize(.small); Button("Cancel", action: cancelTest) }
                    else { Button("Test connection & list models", action: testConnection).disabled((try? RemoteSpeechConfiguration.normalizedEndpoint(model.analysisModelDraft.endpoint)) == nil) }
                }
                if !connectionMessage.isEmpty { Text(connectionMessage).font(.caption).foregroundStyle(connectionFailed ? Color.red : Color.secondary).textSelection(.enabled) }
                Text("Connection tests request model metadata only. Generation support is checked when analysis runs.").font(.caption).foregroundStyle(.secondary)
            }
            card {
                Text(engine == .ollama ? "Installed server models" : "Available server models").font(.headline)
                if !modelIDs.isEmpty {
                    Picker("Model", selection: Binding(get: { modelIDs.contains(model.analysisModelDraft.model) ? model.analysisModelDraft.model : "" }, set: { model.analysisModelDraft.model = $0 })) {
                        Text("Custom model ID…").tag("")
                        ForEach(modelIDs, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Enter an instruction-tuned model ID", text: $model.analysisModelDraft.model).accessibilityLabel("Analysis model ID")
                Text(engine == .ollama ? "Install models with Ollama, then refresh the list here. You can also enter an installed model ID manually." : "Test the connection to discover models or enter an ID manually. Choose a model that supports chat completions.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func providerCard(_ value: LLMEngine, title: String, detail: String) -> some View {
        ModelProviderCard(title: title, detail: detail, selected: engine == value,
                          active: model.settings.analysis.engine == value && activeName != nil,
                          accessibilityTitle: "Browse \(title) analysis models") {
            if engine != value { model.browseAnalysisProvider(value) }
        }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
    }
    private func cancelTest() { connectionTask?.cancel(); connectionTask = nil; testing = false }
    private func resetConnection() { cancelTest(); modelIDs = []; connectionMessage = "" }
    private func testConnection() {
        resetConnection(); testing = true; connectionFailed = false
        let draft = model.analysisModelDraft; let key = model.analysisModelKey; let secret = model.analysisClientSecret
        connectionTask = Task { @MainActor in
            do {
                let ids: [String]
                if draft.engine == .ollama { ids = try await ChatAnalysisProvider.models(settings: draft, key: key.trimmingCharacters(in: .whitespacesAndNewlines), clientSecret: secret) }
                else {
                    let result = try await RemoteSpeechServer.test(endpoint: draft.endpoint, key: key.trimmingCharacters(in: .whitespacesAndNewlines), authentication: draft.authentication, clientSecret: secret)
                    ids = result.models
                    if !result.supportsDiscovery { connectionMessage = "Server responded, but model discovery is unavailable. Check the API prefix or enter a model ID manually." }
                }
                try Task.checkCancellation()
                guard draft.engine == engine, draft.endpoint == model.analysisModelDraft.endpoint, draft.authentication == model.analysisModelDraft.authentication, secret == model.analysisClientSecret, key == model.analysisModelKey else { return }
                modelIDs = ids
                if connectionMessage.isEmpty { connectionMessage = "Connected · \(ids.count) models available." }
            } catch {
                guard !Task.isCancelled else { return }
                connectionFailed = true; connectionMessage = error.localizedDescription
            }
            testing = false; connectionTask = nil
        }
    }
}
