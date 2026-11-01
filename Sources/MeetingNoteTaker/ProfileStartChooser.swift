import AppKit
import SwiftUI

extension AppModel {
    func showProfileChooser() {
        guard recording == nil, !preparingRecording, !audioCheckRunning, profileCatalog != nil else { return }
        if profileChooserWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Start meeting with profile"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ProfileStartChooser().environmentObject(self))
            window.center()
            profileChooserWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        profileChooserWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct ProfileStartChooser: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a meeting profile").font(.headline)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.profileCatalog?.profiles ?? []) { profile in
                        Button {
                            model.profileChooserWindow?.close()
                            model.startRecording(profileID: profile.id)
                        } label: {
                            HStack {
                                Text(profile.name)
                                Spacer()
                                if profile.id == model.profileCatalog?.defaultID {
                                    Text("Default").foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity)
                        }
                        .disabled(model.recording != nil || model.preparingRecording || model.audioCheckRunning)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.profileChooserWindow?.close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360, height: 280)
        .onChange(of: model.recording != nil || model.preparingRecording || model.audioCheckRunning) { _, unavailable in
            if unavailable { model.profileChooserWindow?.close() }
        }
    }
}
