import SwiftUI
import MeetingCore

/// Shared server-authentication UI for speech, compatible analysis and Ollama.
struct ServerAuthenticationFields: View {
    @Binding var configuration: ServerAuthentication?
    @Binding var apiKey: String
    @Binding var clientSecret: String
    let credentialLabel: String
    @State private var revealSecret = false
    private var config: Binding<ServerAuthentication> {
        Binding(get: { configuration ?? .init() }, set: { configuration = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Authentication") {
                Picker("Authentication method", selection: config.method) {
                    Text("API key / None").tag(ServerAuthenticationMethod.apiKey)
                    Text("OAuth 2.0").tag(ServerAuthenticationMethod.oauthClientCredentials)
                }.labelsHidden().frame(width: 300)
            }
            if config.wrappedValue.method == .oauthClientCredentials {
                Text("Client credentials: the app requests an access token from your identity server. No browser sign-in is required.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Client ID") {
                    TextField("Client ID", text: config.clientID).frame(width: 300).accessibilityLabel("OAuth client ID")
                }
                LabeledContent("Token URL") {
                    TextField("https://identity.example.com/oauth/token", text: config.tokenURL).frame(width: 300).accessibilityLabel("OAuth token URL")
                }
                LabeledContent("Scope") {
                    TextField("Optional · space-separated scopes", text: config.scope).frame(width: 300).accessibilityLabel("OAuth scope")
                }
                LabeledContent("Client secret") {
                    secretField($clientSecret, placeholder: "Client secret", label: "OAuth client secret")
                }
                LabeledContent("Client authentication") {
                    Picker("Client authentication", selection: config.clientAuthentication) {
                        Text("HTTP Basic").tag(OAuthClientAuthentication.basic)
                        Text("Form body").tag(OAuthClientAuthentication.formBody)
                    }.labelsHidden().frame(width: 300)
                }
                Text("The client secret is stored in Keychain. Tokens renew automatically. OAuth URLs require HTTPS, except localhost development servers.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("API key") { secretField($apiKey, placeholder: "Optional", label: credentialLabel) }
                Text("Optional for servers without authentication. Stored in Keychain for this server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder)
            .onChange(of: configuration) { _, _ in revealSecret = false }
            .onDisappear { revealSecret = false }
    }
    private func secretField(_ binding: Binding<String>, placeholder: String, label: String) -> some View {
        HStack(spacing: 7) {
            Group {
                if revealSecret { TextField(placeholder, text: binding) }
                else { SecureField(placeholder, text: binding) }
            }.accessibilityLabel(label)
            Button { revealSecret.toggle() } label: { Image(systemName: revealSecret ? "eye.slash" : "eye") }
                .buttonStyle(.plain).help(revealSecret ? "Hide credential" : "Show credential")
                .accessibilityLabel(revealSecret ? "Hide credential" : "Show credential")
        }.frame(width: 300)
    }
}
