import SwiftUI
import MeetingCore

private enum SpeechServerPreset: String, CaseIterable, Identifiable {
    case custom = "Custom", openAI = "OpenAI", groq = "Groq"
    var id: String { rawValue }
    var endpoint: String? {
        switch self {
        case .custom: return nil
        case .openAI: return "https://api.openai.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        }
    }
}

struct ServerModelsView: View {
    @EnvironmentObject var model: AppModel
    let accent: Color
    let surface: Color
    let border: Color
    @State private var preset: SpeechServerPreset = .custom
    @State private var modelIDs: [String] = []
    @State private var connectionMessage = ""
    @State private var connectionFailed = false
    @State private var testing = false
    @State private var connectionTask: Task<Void, Never>?

    private var endpointValid: Bool { (try? RemoteSpeechConfiguration.normalizedEndpoint(model.remoteSpeechDraft.endpoint)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Server").font(.headline)
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "network")
                        Text("Audio is sent to the server you configure. Use a local endpoint to keep processing on this Mac.")
                    }.font(.callout).foregroundStyle(accent).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).background(accent.opacity(0.07))
                    Divider().overlay(border)
                    row("Service", detail: "Presets fill the API address. Custom accepts any compatible server.") {
                        Picker("Service", selection: $preset) {
                            ForEach(SpeechServerPreset.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 150)
                            .onChange(of: preset) { _, value in
                                if let endpoint = value.endpoint, (try? RemoteSpeechConfiguration.normalizedEndpoint(model.remoteSpeechDraft.endpoint)) != endpoint {
                                    model.remoteSpeechDraft.endpoint = endpoint
                                    model.remoteSpeechDraft.model = ""
                                }
                            }
                    }
                    Divider().overlay(border)
                    row("Server URL", detail: "Include http:// or https:// and the API prefix, such as /v1.") {
                        TextField("http://localhost:8000/v1", text: $model.remoteSpeechDraft.endpoint)
                            .textFieldStyle(.roundedBorder).frame(width: 300).accessibilityLabel("Server URL")
                    }
                    Divider().overlay(border)
                    ServerAuthenticationFields(configuration: $model.remoteSpeechDraft.authentication, apiKey: $model.remoteSpeechKey,
                        clientSecret: $model.remoteSpeechClientSecret, credentialLabel: "Server API key").padding(16)
                    Divider().overlay(border)
                    row("Connection", detail: "Tests authentication and lists model IDs. No audio is uploaded.") {
                        HStack(spacing: 10) {
                            if testing {
                                ProgressView().controlSize(.small)
                                Button("Cancel") { cancelTest() }
                            } else {
                                Button("Test connection", action: testConnection).disabled(!endpointValid)
                            }
                        }
                    }
                    if !connectionMessage.isEmpty {
                        Text(connectionMessage).font(.caption).foregroundStyle(connectionFailed ? Color.red : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 14)
                            .textSelection(.enabled)
                    }
                }.background(surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Model").font(.headline)
                VStack(alignment: .leading, spacing: 12) {
                    if !modelIDs.isEmpty {
                        Picker("Available models", selection: Binding(get: {
                            modelIDs.contains(model.remoteSpeechDraft.model) ? model.remoteSpeechDraft.model : ""
                        }, set: { model.remoteSpeechDraft.model = $0 })) {
                            Text("Custom model ID…").tag("")
                            ForEach(modelIDs, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("Enter a transcription model ID", text: $model.remoteSpeechDraft.model)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Transcription model ID")
                    Text(modelIDs.isEmpty ? "Test the connection to discover models, or enter an ID manually if the server does not list them." : "Choose an audio transcription model. The server’s list may also contain chat or embedding models.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The server must support /audio/transcriptions. A successful connection test does not verify transcription support.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Server response format").font(.headline)
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle("Request detailed segment timestamps", isOn: $model.remoteSpeechDraft.detailedTimestamps).tint(accent)
                        Text("Enable only if the selected model supports verbose_json with segment timestamps. Otherwise, transcript times are approximate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.background(surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
            }
            Text("Choose a model from the list or enter its ID, then use Save Settings to apply the configuration and activate Server. Browsing servers does not change the active model.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { updatePreset() }
        .onDisappear { cancelTest() }
        .onChange(of: model.remoteSpeechDraft.endpoint) { old, new in
            cancelTest(); modelIDs = []; connectionMessage = ""
            if RemoteSpeechConfiguration.credentialAccount(endpoint: old) != RemoteSpeechConfiguration.credentialAccount(endpoint: new) {
                model.remoteSpeechKey = KeychainStore.get(RemoteSpeechConfiguration.credentialAccount(endpoint: new))
            }
            model.reloadSpeechClientSecret()
            updatePreset()
        }
        .onChange(of: model.remoteSpeechDraft.authentication) { old, new in
            cancelTest(); modelIDs = []; connectionMessage = ""
            if (old ?? .init()).secretAccount(purpose: "speech", endpoint: model.remoteSpeechDraft.endpoint) != (new ?? .init()).secretAccount(purpose: "speech", endpoint: model.remoteSpeechDraft.endpoint) { model.reloadSpeechClientSecret() }
        }
        .onChange(of: model.remoteSpeechClientSecret) { _, _ in cancelTest(); modelIDs = []; connectionMessage = "" }
        .onChange(of: model.remoteSpeechKey) { _, _ in cancelTest(); modelIDs = []; connectionMessage = "" }
    }

    private func row<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            content()
        }.padding(.horizontal, 16).padding(.vertical, 14)
    }
    private func updatePreset() {
        let endpoint = try? RemoteSpeechConfiguration.normalizedEndpoint(model.remoteSpeechDraft.endpoint)
        preset = SpeechServerPreset.allCases.first { $0.endpoint != nil && $0.endpoint == endpoint } ?? .custom
    }
    private func cancelTest() { connectionTask?.cancel(); connectionTask = nil; testing = false }
    private func testConnection() {
        cancelTest(); modelIDs = []; connectionMessage = ""; connectionFailed = false; testing = true
        let endpoint = model.remoteSpeechDraft.endpoint
        let authentication = model.remoteSpeechDraft.authentication, secret = model.remoteSpeechClientSecret
        let key = model.remoteSpeechKey.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionTask = Task { @MainActor in
            do {
                let result = try await RemoteSpeechServer.test(endpoint: endpoint, key: key, authentication: authentication, clientSecret: secret)
                try Task.checkCancellation()
                guard endpoint == model.remoteSpeechDraft.endpoint, authentication == model.remoteSpeechDraft.authentication, secret == model.remoteSpeechClientSecret, key == model.remoteSpeechKey.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                modelIDs = result.models
                connectionMessage = result.supportsDiscovery ? "Connected · \(result.models.count) model IDs available. Select an audio transcription model below." : "Server responded, but model discovery is unavailable. Check the API prefix or enter a model ID manually."
            } catch {
                guard !Task.isCancelled else { return }
                connectionFailed = true; connectionMessage = error.localizedDescription
            }
            testing = false; connectionTask = nil
        }
    }
}
