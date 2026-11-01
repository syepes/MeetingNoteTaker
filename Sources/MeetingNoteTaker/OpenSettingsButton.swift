import AppKit
import SwiftUI

/// A menu-bar popover can receive clicks while its accessory app is inactive.
/// Activate explicitly and raise the native Settings scene, including on repeat
/// clicks when the window already exists behind another application.
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            SettingsWindowPresentation.shared.open { openSettings() }
        } label: { label() }
    }
}

@MainActor
final class SettingsWindowPresentation {
    static let shared = SettingsWindowPresentation()
    private weak var window: NSWindow?
    private var requested = false

    func open(using openScene: () -> Void) {
        requested = true
        NSApp.activate(ignoringOtherApps: true)
        openScene()
        raiseIfRequested()
    }

    func attach(_ window: NSWindow) {
        self.window = window
        raiseIfRequested()
    }

    private func raiseIfRequested() {
        guard requested, let window else { return }
        requested = false
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Register the actual Settings window without relying on private window IDs or
/// deprecated AppKit preference selectors. Handles asynchronous first creation.
struct SettingsWindowRegistration: NSViewRepresentable {
    func makeNSView(context: Context) -> RegistrationView { RegistrationView() }
    func updateNSView(_ nsView: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { SettingsWindowPresentation.shared.attach(window) }
        }
    }
}
