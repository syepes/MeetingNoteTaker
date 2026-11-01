import SwiftUI
import MeetingCore

struct AppleModelsView: View {
    @EnvironmentObject var model: AppModel
    let busy: Bool
    @State private var locale = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Apple-managed language assets").font(.callout).foregroundStyle(.secondary)
            if model.appleLocales.isEmpty {
                Text("Apple Speech is unavailable on this Mac, or its supported languages are still loading.")
            } else {
                Picker("Language asset", selection: $locale) {
                    ForEach(model.appleLocales, id: \.self) { value in
                        Text("\(Locale.current.localizedString(forIdentifier: value) ?? value) · \(model.installedAppleLocales.contains(value) ? "Installed" : "Available")").tag(value)
                    }
                }
                HStack {
                    if model.installedAppleLocales.contains(locale) {
                        if model.settings.speech.engine == .apple && (model.settings.speech.appleLocale ?? model.settings.speech.language) == locale {
                            Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Activate language") { model.activateApple(locale) }.disabled(busy)
                        }
                    } else {
                        Button("Install language asset") { model.installApple(locale: locale) }.disabled(busy || locale.isEmpty)
                    }
                }
                Text("macOS manages these assets. Select an installed language to activate Apple Speech; installing an asset does not switch engines.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            .onAppear { selectInitialLocale() }
            .onChange(of: model.appleLocales) { _, _ in selectInitialLocale() }
    }
    private func selectInitialLocale() {
        guard !model.appleLocales.contains(locale) else { return }
        let saved = model.settings.speech.appleLocale ?? model.settings.speech.language
        locale = model.appleLocales.contains(saved) ? saved : (model.appleLocales.first(where: { $0.hasPrefix("en") }) ?? model.appleLocales.first ?? "")
    }
}
