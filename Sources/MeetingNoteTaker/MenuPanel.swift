import AppKit
import Carbon
import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(spacing: 0) {
            recordingStatus
                .padding(12)

            Divider().padding(.horizontal, 6)

            VStack(spacing: 2) {
                Button(action: model.toggleRecording) {
                    menuLabel(
                        model.recording == nil ? "Start meeting" : "Stop and transcribe",
                        symbol: model.recording == nil ? "record.circle" : "stop.circle",
                        shortcut: recordingShortcut
                    )
                }
                .disabled(model.preparingRecording || model.audioCheckRunning)

                if model.recording == nil, model.profileCatalog != nil {
                    Button(action: model.showProfileChooser) {
                        menuLabel("Start meeting with profile", symbol: "record.circle", shortcut: shortcutLabel(addingShift: true))
                    }
                    .disabled(model.preparingRecording || model.audioCheckRunning)
                }

                if model.recording != nil {
                    Button(action: model.togglePause) {
                        menuLabel(model.recordingPaused ? "Resume recording" : "Pause recording", symbol: model.recordingPaused ? "play.circle" : "pause.circle", shortcut: "⇧⌘P")
                    }.keyboardShortcut("p", modifiers: [.command, .shift])
                    Toggle("Record microphone", isOn: Binding(
                        get: { model.settings.microphoneEnabled }, set: model.setMicrophone
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .help("Meeting-app mute does not mute this recorder.")
                }

                if model.working {
                    Button(action: model.cancelWork) {
                        menuLabel("Cancel processing", shortcut: "⌘.")
                    }
                    .keyboardShortcut(".", modifiers: .command)
                }

                Divider().padding(.vertical, 3)

                if let profile = model.recording?.profileSnapshot { Text("Profile: \(profile.name)").font(.caption).foregroundStyle(.secondary) }
                Button {
                    openWindow(id: "meetings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    menuLabel("Meetings & transcripts…", symbol: "text.book.closed", shortcut: "⇧⌘M")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.outputFolder))
                } label: {
                    menuLabel("Open output folder", symbol: "folder", shortcut: "⇧⌘O")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider().padding(.vertical, 3)

                Button {
                    openWindow(id: "keyboard-shortcuts")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    menuLabel("Keyboard Shortcuts", symbol: "keyboard")
                }
                OpenSettingsButton(closesContainingWindow: true) { menuLabel("Settings…", symbol: "gearshape", shortcut: "⌘,") }
                    .keyboardShortcut(",", modifiers: .command)
                Button {
                    if model.recording == nil {
                        model.quit()
                    } else {
                        model.error = "Stop the recording before quitting so its audio can be finalized."
                    }
                } label: {
                    menuLabel("Quit", symbol: "power", shortcut: "⌘Q")
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(6)
        }
        .font(.system(size: 13))
        .frame(width: 300)
        .modifier(MenuPopoverSizing(onVisibilityChange: { model.recordingMetersVisible = $0 }))
        .onDisappear { model.recordingMetersVisible = false }
    }

    private var recordingStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.badge.mic")
                    .foregroundStyle(.secondary)
                Text("MeetingNoteTaker").fontWeight(.semibold)
                Spacer()
                if let started = model.startedAt {
                    Text(started, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Elapsed recording time")
                }
            }

            HStack(alignment: .top, spacing: 7) {
                if model.recording != nil {
                    Image(systemName: model.recordingPaused ? "pause.circle.fill" : "record.circle.fill")
                        .foregroundStyle(model.recordingPaused ? .orange : .red)
                        .accessibilityHidden(true)
                } else if model.working || model.preparingRecording {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: model.error == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(model.progress)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)

            if model.recording != nil {
                LiveAudioLevels(state: model.audioLevels, microphoneEnabled: model.settings.microphoneEnabled)
                Text(model.captureHealthText)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Meeting-app mute does not mute this recorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { model.error = nil }
                    .controlSize(.small)
            }
        }
    }

    private var recordingShortcut: String? {
        shortcutLabel(addingShift: false)
    }

    private func shortcutLabel(addingShift: Bool) -> String? {
        let keys = ShortcutReferenceEntry.recordingKeys(keyCode: model.settings.shortcutKeyCode,
                                                       modifiers: model.settings.shortcutModifiers,
                                                       addingShift: addingShift)
        return keys.isEmpty ? nil : keys.joined()
    }

    private func menuLabel(_ title: String, symbol: String? = nil, shortcut: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).frame(width: 16) }
            Text(title)
            Spacer(minLength: 8)
            if let shortcut {
                Text(shortcut).opacity(0.65).accessibilityHidden(true)
            }
        }
    }
}

// Keep live recording information in the system menu-bar popover; menu-style
// MenuBarExtra does not display the audio meters. Rows use system selection colors.
private struct MenuRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isEnabled: isEnabled)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let isEnabled: Bool
        @State private var hovered = false

        private var highlighted: Bool { isEnabled && (hovered || configuration.isPressed) }

        var body: some View {
            configuration.label
                .font(Font(NSFont.menuFont(ofSize: 0)))
                .fontWeight(.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .foregroundStyle(
                    !isEnabled ? Color(nsColor: .disabledControlTextColor) :
                        highlighted ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary
                )
                .background(highlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .onHover { hovered = $0 }
        }
    }
}

struct LevelRow: View {
    let title: String
    let value: Float
    var enabled = true

    var body: some View {
        HStack {
            Text(enabled ? title : "\(title) off")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 85, alignment: .leading)
            ProgressView(value: enabled ? Double(min(1, max(0, value * 3))) : 0)
                .tint(value > 0.95 ? .red : .accentColor)
                .accessibilityLabel("\(title) audio level")
        }
    }
}

