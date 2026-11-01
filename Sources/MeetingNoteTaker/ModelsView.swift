import SwiftUI
import MeetingCore

enum ModelSection: String, CaseIterable, Identifiable {
    case transcription = "Transcription", analysis = "Analysis"
    var id: String { rawValue }
}

private struct ModelDownloadOption: Identifiable {
    let id: String
    let title: String
    let detail: String
    let kind: ModelKind
    let filename: String
    var sourceURL: URL {
        if kind == .parakeet {
            let repository = id == "ultra" ? "parakeet-ultra-coreml" : "parakeet-tdt-0.6b-\(id)-coreml"
            return URL(string: "https://huggingface.co/FluidInference/\(repository)")!
        }
        return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/blob/main/\(filename)")!
    }
    var license: String { kind == .parakeet ? "CC-BY-4.0" : "MIT" }
}

struct ModelsView: View {
    @EnvironmentObject var model: AppModel
    private var engine: SpeechEngine {
        get { model.modelBrowserEngine ?? model.settings.speech.engine }
        nonmutating set { model.modelBrowserEngine = newValue }
    }
    @State private var removal: InstalledModel?

    private var accent: Color { .accentColor }
    private var surface: Color { Color(nsColor: .controlBackgroundColor) }
    private var border: Color { Color(nsColor: .separatorColor) }
    private var busy: Bool { model.modelTaskRunning || model.working || model.recording != nil }
    private var kind: ModelKind { engine == .parakeet ? .parakeet : .whisper }
    private var options: [ModelDownloadOption] {
        if engine == .parakeet {
            return [("ultra", "Parakeet Ultra", "Multilingual · English & French · Enhanced v3 model"),
                    ("v3", "Parakeet v3", "Multilingual · English & French"),
                    ("v2", "Parakeet v2", "English only")].map {
                .init(id: $0.0, title: $0.1, detail: $0.2, kind: .parakeet, filename: ModelManager.parakeetFolderName($0.0))
            }
        }
        return [("large-v3-turbo", "Whisper Large v3 Turbo", "Multilingual · Recommended"),
                ("large-v3-turbo-q5_0", "Whisper Large v3 Turbo · Q5", "Multilingual · Smaller download"),
                ("large-v3", "Whisper Large v3", "Multilingual · Full-size model"),
                ("medium", "Whisper Medium", "Multilingual · Balanced size"),
                ("small", "Whisper Small", "Multilingual · Lightweight")].map {
            .init(id: $0.0, title: $0.1, detail: $0.2, kind: .whisper, filename: "ggml-\($0.0).bin")
        }
    }
    private func installed(_ option: ModelDownloadOption) -> InstalledModel? {
        model.models.first { $0.kind == option.kind && $0.url.lastPathComponent == option.filename }
    }
    private var imports: [InstalledModel] {
        let names = Set(options.map(\.filename))
        return model.models.filter { $0.kind == kind && !names.contains($0.url.lastPathComponent) }
    }
    private func samePath(_ path: String, _ url: URL) -> Bool {
        ModelManager.sameLocation(path, url)
    }
    private func active(_ item: InstalledModel) -> Bool {
        if item.kind == .gguf { return model.settings.analysis.engine == .builtin && samePath(model.settings.analysis.modelPath, item.url) }
        let expected: SpeechEngine = item.kind == .parakeet ? .parakeet : .whisper
        return model.settings.speech.engine == expected && samePath(model.settings.speech.modelPath, item.url)
    }
    private func available(_ path: String) -> Bool { !path.isEmpty && FileManager.default.fileExists(atPath: path) }
    private var speechName: String? {
        let speech = model.settings.speech
        switch speech.engine {
        case .parakeet:
            guard available(speech.modelPath) else { return nil }
            return speech.parakeetVersion == "ultra" ? "Parakeet Ultra" : "Parakeet \(speech.parakeetVersion)"
        case .whisper:
            guard available(speech.modelPath) else { return nil }
            return "Whisper · " + URL(fileURLWithPath: speech.modelPath).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
        case .apple: return "Apple Speech · \(speech.appleLocale ?? speech.language)"
        case .remote: return speech.remoteModel.isEmpty ? nil : "Server · \(speech.remoteModel)"
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Models for", selection: $model.modelSection) {
                    ForEach(ModelSection.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if model.modelSection == .transcription {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Transcription engine").font(.headline).fixedSize()
                        Spacer()
                        status(speechName.map { "Active · " + $0 } ?? "No active model", active: speechName != nil)
                    }
                    HStack(spacing: 10) {
                        engineCard(.parakeet, title: "Parakeet", detail: "Fast, on this Mac")
                        engineCard(.whisper, title: "Whisper", detail: "Multilingual, local")
                        engineCard(.apple, title: "Apple", detail: "Built into macOS")
                        engineCard(.remote, title: "Server", detail: "Your inference endpoint")
                    }
                }

                if engine == .remote {
                    ServerModelsView(accent: accent, surface: surface, border: border)
                } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Model").font(.headline)
                        Spacer()
                        if engine == .parakeet || engine == .whisper {
                            Button { model.importModel(kind) } label: { Label("Import model…", systemImage: "square.and.arrow.down") }
                                .buttonStyle(.plain).foregroundStyle(accent).disabled(busy)
                        }
                    }
                    if engine == .parakeet || engine == .whisper {
                        VStack(spacing: 0) {
                            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                                if index > 0 { Divider().overlay(border) }
                                downloadRow(option)
                            }
                            ForEach(imports) { item in
                                Divider().overlay(border)
                                installedRow(item, title: item.url.deletingPathExtension().lastPathComponent, detail: "Installed · Imported · \(size(item))")
                            }
                        }.background(surface).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
                        externalSelection
                    } else {
                        AppleModelsView(busy: busy)
                    }
                    Text("Activate a model to use it for new recordings. Saved jobs keep their own model settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                }

                } else {
                    AnalysisModelsView(accent: accent, surface: surface, border: border, busy: busy)
                }
                if model.modelTaskRunning || !model.modelStatus.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.modelStatus.isEmpty ? "Preparing model…" : model.modelStatus).font(.callout)
                            Spacer()
                            if model.modelTaskRunning { Button("Cancel", action: model.cancelDownload) }
                        }
                        if model.modelTaskRunning { ProgressView(value: model.modelProgress).tint(accent) }
                    }
                }

            }.padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if model.modelBrowserEngine == nil { model.modelBrowserEngine = model.settings.speech.engine }; await model.refreshModels() }
        .confirmationDialog("Remove \(removal?.url.lastPathComponent ?? "model")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            if let item = removal { Button("Remove model", role: .destructive) { model.removeModel(item); removal = nil } }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("The app’s copy will be removed and deselected. Original imports and meeting files are preserved.")
        }
    }

    private func engineCard(_ value: SpeechEngine, title: String, detail: String) -> some View {
        ModelProviderCard(title: title, detail: detail, selected: engine == value,
                          active: model.settings.speech.engine == value && speechName != nil,
                          accessibilityTitle: "Browse \(title) models") { engine = value }
    }
    private func status(_ text: String, active: Bool) -> some View {
        ModelBadge(text: text, kind: active ? .active : .inactive)
    }
    private func size(_ item: InstalledModel) -> String { ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file) }
    private func downloadRow(_ option: ModelDownloadOption) -> some View {
        let item = installed(option)
        return ModelRow(title: option.title, detail: option.detail + (item.map { " · Installed · \(size($0))" } ?? ""),
                        sourceURL: option.sourceURL, sourceLabel: "Source · \(option.license)") {
            if let item { installedActions(item) }
            else {
                Button("Download") { model.downloadModel(option.kind, name: option.id) }
                    .buttonStyle(.bordered).disabled(busy).accessibilityLabel("Download \(option.title)")
            }
        }
    }
    private func installedRow(_ item: InstalledModel, title: String, detail: String) -> some View {
        ModelRow(title: title, detail: detail) { installedActions(item) }
    }
    @ViewBuilder private func installedActions(_ item: InstalledModel) -> some View {
        if active(item) { status("Active", active: true) }
        else {
            Button("Activate") { model.selectModel(item.url, kind: item.kind) }
                .buttonStyle(.bordered).disabled(busy).accessibilityLabel("Activate \(item.url.lastPathComponent)")
        }
        ModelRemoveButton(name: item.url.lastPathComponent, disabled: busy) { removal = item }
    }
    @ViewBuilder private var externalSelection: some View {
        let speech = model.settings.speech
        if speech.engine == engine, available(speech.modelPath), !model.models.contains(where: { samePath(speech.modelPath, $0.url) }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: speech.modelPath).lastPathComponent).font(.headline)
                    Text("External model · \(speech.modelPath)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(); status("Active", active: true)
            }.padding(16).background(surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
