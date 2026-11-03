import AppKit
import Carbon
import SwiftUI

struct ShortcutReferenceEntry: Identifiable, Equatable {
    let title: String
    let keys: [String]
    var global = false
    var id: String { title }

    static func recordingKeys(keyCode: UInt32, modifiers: UInt32, addingShift: Bool = false) -> [String] {
        let key: String
        switch keyCode {
        case 15: key = "R"
        case 46: key = "M"
        case 49: key = "Space"
        default: return []
        }
        let flags = modifiers | (addingShift ? UInt32(shiftKey) : 0)
        return [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { flags & UInt32($0.0) != 0 }.map { $0.1 } + [key]
    }

    static func groups(keyCode: UInt32, modifiers: UInt32) -> [(title: String, symbol: String, commands: [Self])] {
        [
            ("Recording & Processing", "record.circle", [
                .init(title: "Start / stop meeting", keys: recordingKeys(keyCode: keyCode, modifiers: modifiers), global: true),
                .init(title: "Start meeting with profile", keys: recordingKeys(keyCode: keyCode, modifiers: modifiers, addingShift: true), global: true),
                .init(title: "Pause / resume recording", keys: ["⇧", "⌘", "P"]),
                .init(title: "Cancel processing", keys: ["⌘", "."])
            ]),
            ("Navigation & Application", "macwindow", [
                .init(title: "Meetings & transcripts", keys: ["⇧", "⌘", "M"]),
                .init(title: "Open output folder", keys: ["⇧", "⌘", "O"]),
                .init(title: "Settings", keys: ["⌘", ","]),
                .init(title: "Quit", keys: ["⌘", "Q"])
            ])
        ]
    }
}

struct ShortcutReferenceView: View {
    let keyCode: UInt32
    let modifiers: UInt32
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var closeWindow
    let customize: () -> Void
    @State private var search = ""

    private var groups: [(title: String, symbol: String, commands: [ShortcutReferenceEntry])] {
        ShortcutReferenceEntry.groups(keyCode: keyCode, modifiers: modifiers)
    }
    private func matching(_ commands: [ShortcutReferenceEntry], title: String) -> [ShortcutReferenceEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return commands.filter { command in
            query.isEmpty || title.localizedCaseInsensitiveContains(query) ||
            command.title.localizedCaseInsensitiveContains(query) ||
            command.keys.joined().localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 26, weight: .medium)).foregroundStyle(Color.accentColor)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                        Text("Record meetings and navigate your notebook.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a shortcut", text: $search).textFieldStyle(.plain)
                        .accessibilityLabel("Find a shortcut")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.1)))
            }.padding(22)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if groups.allSatisfy({ matching($0.commands, title: $0.title).isEmpty }) {
                        ContentUnavailableView.search(text: search).frame(maxWidth: .infinity).padding(.vertical, 50)
                    }
                    ForEach(groups.indices, id: \.self) { index in
                        let group = groups[index]
                        let commands = matching(group.commands, title: group.title)
                        if !commands.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                Label(group.title, systemImage: group.symbol)
                                    .font(.headline).foregroundStyle(.secondary).padding(.horizontal, 4)
                                VStack(spacing: 0) {
                                    ForEach(commands) { command in
                                        HStack(spacing: 12) {
                                            Text(command.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                                            if command.global {
                                                Image(systemName: "globe").font(.caption).foregroundStyle(.tertiary)
                                                    .help("Works from any app").accessibilityLabel("Global shortcut")
                                            }
                                            Spacer(minLength: 12)
                                            ShortcutKeycaps(keys: command.keys)
                                        }.padding(.horizontal, 14).padding(.vertical, 9)
                                        if command != commands.last { Divider().padding(.leading, 14) }
                                    }
                                }.background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
                            }
                        }
                    }
                }.padding(22)
            }
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Works from any app", systemImage: "globe")
                    Text("Other shortcuts apply while the meeting menu is open.")
                }.font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Customize…") {
                    customize()
                    SettingsWindowPresentation.shared.open { openSettings() }
                }
                .help("Change the recording shortcut in General settings")
                Button("Done") { closeWindow() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }.padding(.horizontal, 22).padding(.vertical, 16)
        }.frame(width: 620, height: 680).background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ShortcutKeycaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 4) {
            if keys.isEmpty { Text("Unavailable").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key).font(.system(size: 17, weight: .medium, design: .monospaced))
                    .frame(minWidth: 19, minHeight: 32).padding(.horizontal, 3)
                    .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)))
            }
        }.fixedSize().accessibilityElement(children: .ignore).accessibilityLabel(keys.joined(separator: " "))
    }
}
