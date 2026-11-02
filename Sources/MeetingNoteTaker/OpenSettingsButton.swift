import AppKit
import SwiftUI

/// A menu-bar popover can receive clicks while its accessory app is inactive.
/// Activate explicitly and raise the native Settings scene, including on repeat
/// clicks when the window already exists behind another application.
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    var closesContainingWindow = false
    @State private var sourceWindow = SettingsSourceWindowReference()
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            SettingsWindowPresentation.shared.open(dismissing: closesContainingWindow ? sourceWindow.window : nil) { openSettings() }
        } label: { label() }
        .background(SettingsSourceWindowRegistration(reference: sourceWindow))
    }
}

@MainActor
final class SettingsWindowPresentation {
    static let shared = SettingsWindowPresentation()
    private weak var window: NSWindow?
    private var requested = false

    func open(dismissing sourceWindow: NSWindow? = nil, using openScene: () -> Void) {
        sourceWindow?.orderOut(nil)
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

/// Track the button's own window, rather than whichever window happens to be key.
/// A weak reference avoids retaining the hosting window through its SwiftUI view.
@MainActor
private final class SettingsSourceWindowReference {
    weak var window: NSWindow?
}

private struct SettingsSourceWindowRegistration: NSViewRepresentable {
    let reference: SettingsSourceWindowReference
    func makeNSView(context: Context) -> RegistrationView { RegistrationView(reference: reference) }
    func updateNSView(_ view: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        let reference: SettingsSourceWindowReference
        init(reference: SettingsSourceWindowReference) { self.reference = reference; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference.window = window
        }
    }
}
