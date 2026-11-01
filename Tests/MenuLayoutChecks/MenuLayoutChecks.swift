import AppKit
import SwiftUI

// Compile with the production MenuPanel and MenuPopoverSizing sources. This
// isolated model exercises their layout without audio, inference, or user files.
@MainActor
final class AppModel: ObservableObject {
    struct Settings {
        var microphoneEnabled = true
        var outputFolder = "/tmp"
        var shortcutKeyCode: UInt32 = 15
        var shortcutModifiers: UInt32 = 4352
    }
    @Published var settings = Settings()
    struct Profile: Identifiable { var id = UUID(); var name = "Technical review" }
    struct Catalog { var profiles: [Profile]; var defaultID: UUID }
    struct Recording { var profileSnapshot: Profile? }
    let profile = Profile()
    var profileCatalog: Catalog? { .init(profiles: [profile], defaultID: profile.id) }
    @Published var recording: Recording?
    @Published var startedAt: Date?
    @Published var working = false
    @Published var recordingPaused = false
    @Published var audioCheckRunning = false
    @Published var captureHealthText = "Microphone: Receiving audio · Computer: Receiving audio"
    func togglePause() {}
    func quit() {}
    @Published var preparingRecording = false
    @Published var microphoneLevel: Float = 0.15
    @Published var computerLevel: Float = 0.2
    @Published var progress = "Ready"
    @Published var error: String?
    func toggleRecording() {}
    func showProfileChooser() {}
    func startRecording(profileID: UUID? = nil) {}
    func setMicrophone(_ enabled: Bool) { settings.microphoneEnabled = enabled }
    func cancelWork() {}
}

@main
struct MenuLayoutChecks {
    @MainActor
    static func main() {
        if Bundle.main.bundleIdentifier == "com.meetingnotetaker.layoutcheck" {
            MenuBarLayoutCheckApp.main()
            return
        }
        _ = NSApplication.shared
        let model = AppModel()
        let hosting = NSHostingView(rootView: MenuPanel().environmentObject(model))
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 200, width: 300, height: 500),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        let top = panel.frame.maxY
        var checks = 0

        func settle() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
        }
        func check(_ name: String) {
            settle()
            let actual = panel.contentRect(forFrameRect: panel.frame).size
            let expected = hosting.fittingSize
            precondition(abs(actual.height - ceil(expected.height)) <= 1,
                         "\(name): window height \(actual.height), content height \(expected.height)")
            precondition(abs(actual.width - 300) <= 1, "\(name): unexpected width")
            precondition(abs(panel.frame.maxY - top) <= 1, "\(name): top anchor moved")
            checks += 1
            print("PASS \(name): \(Int(actual.height)) pt, no excess height")
        }

        check("initial oversized panel")
        let idleHeight = panel.frame.height
        for cycle in 1...3 {
            model.recording = .init(profileSnapshot: model.profile)
            model.startedAt = Date()
            model.progress = "Recording"
            check("recording \(cycle)")
            model.recordingPaused = true; model.progress = "Paused — elapsed time is preserved"
            check("paused \(cycle)")
            model.recordingPaused = false; model.progress = "Recording degraded — retrying audio source"
            model.captureHealthText = "Microphone: selected device disconnected · Computer: Receiving audio"
            check("degraded \(cycle)")
            model.captureHealthText = "Microphone: Receiving audio · Computer: Waiting for audio"
            check("waiting for audio \(cycle)")
            precondition(panel.frame.height > idleHeight + 50, "Recording controls must remain visible")
            model.recording = nil
            model.startedAt = nil
            model.working = true
            model.progress = "Saving audio…"
            check("stopped / processing \(cycle)")
            model.working = false
            model.progress = "Saved 20261031 - 014845"
            check("saved \(cycle)")
            precondition(abs(panel.frame.height - idleHeight) <= 1, "Must return to compact height")

            // Reproduce a cached size being reapplied by the window host.
            var staleFrame = panel.frame
            staleFrame.origin.y -= 120
            staleFrame.size.height += 120
            panel.setFrame(staleFrame, display: false)
            check("host reapplied stale height \(cycle)")
            panel.orderOut(nil)
            check("closed \(cycle)")
        }
        model.error = String(repeating: "Audio processing needs attention. ", count: 8)
        check("multiline error")
        model.error = nil
        check("error dismissed")
        model.progress = String(repeating: "Transcribing the next audio chunk. ", count: 6)
        check("multiline progress")
        model.progress = "Ready"
        check("progress cleared")
        precondition(abs(panel.frame.height - idleHeight) <= 1, "Final panel must be compact")
        // Settings must open even when the scene's window is created later,
        // and a closed/hidden existing window must be raised on every click.
        let presentation = SettingsWindowPresentation()
        let preferences = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        preferences.isReleasedWhenClosed = false
        var requests = 0
        presentation.open { requests += 1 }
        presentation.attach(preferences)
        precondition(preferences.isVisible, "First Settings request must show a later-created window")
        preferences.close()
        presentation.open { requests += 1 }
        precondition(preferences.isVisible, "Settings must reopen after closing")
        preferences.orderOut(nil)
        presentation.open { requests += 1 }
        precondition(preferences.isVisible, "Settings must raise a hidden existing window")
        precondition(requests == 3, "Every Settings click must invoke the native scene action")
        preferences.close()
        let unsolicited = SettingsWindowPresentation()
        unsolicited.attach(preferences)
        precondition(!preferences.isVisible, "Window registration alone must never open Settings")
        print("Passed 4 Settings presentation checks (first creation, reopen, hidden window, no unsolicited opening).")
        print("Passed \(checks) menu layout checks; no audio recorded or user files changed.")
    }
}

// Optional UI harness: run the same checks inside the real MenuBarExtra host.
struct MenuBarLayoutCheckApp: App {
    @StateObject private var model = AppModel()
    @State private var measuredSize = CGSize.zero
    @State private var started = false

    var body: some Scene {
        MenuBarExtra("Layout check", systemImage: "ruler") {
            MenuPanel().environmentObject(model)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { measuredSize = $0 }
                .task {
                    guard !started else { return }
                    started = true
                    await runChecks()
                }
        }.menuBarExtraStyle(.window)
        Window("Menu layout check", id: "layout-check") {
            Text("Open the ruler icon in the menu bar to run simulated recording transitions.")
                .padding(20).frame(width: 360)
        }.defaultLaunchBehavior(.presented)
    }

    @MainActor
    private func runChecks() async {
        var lines: [String] = []
        func check(_ label: String) async {
            try? await Task.sleep(for: .milliseconds(400))
            guard let window = NSApp.windows.first(where: { $0.isVisible && abs($0.frame.width - 300) < 1 }) else {
                lines.append("FAIL \(label): menu window missing")
                return
            }
            let height = window.contentRect(forFrameRect: window.frame).height
            let passed = abs(height - ceil(measuredSize.height)) <= 1
            lines.append("\(passed ? "PASS" : "FAIL") \(label): window \(height), content \(measuredSize.height)")
            try? lines.joined(separator: "\n").write(toFile: "/tmp/MeetingNoteTaker-menu-bar-layout-check.log", atomically: true, encoding: .utf8)
        }
        await check("idle")
        for cycle in 1...3 {
            model.recording = .init(profileSnapshot: model.profile)
            model.startedAt = Date()
            model.progress = "Recording"
            await check("recording \(cycle)")
            model.recording = nil
            model.startedAt = nil
            model.working = true
            model.progress = "Saving audio…"
            await check("stopped / processing \(cycle)")
            model.working = false
            model.progress = "Saved 20261031 - 014845"
            await check("saved \(cycle)")
        }
        model.error = String(repeating: "Audio processing needs attention. ", count: 8)
        await check("multiline error")
        model.error = nil
        await check("error dismissed")
        lines.append("DONE")
        try? lines.joined(separator: "\n").write(toFile: "/tmp/MeetingNoteTaker-menu-bar-layout-check.log", atomically: true, encoding: .utf8)
    }
}
