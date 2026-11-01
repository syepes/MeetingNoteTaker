import AppKit
import Carbon

@main
struct ShortcutChecks {
    static func main() {
        _ = NSApplication.shared
        var recordingCalls = 0
        var profileCalls = 0
        let recording = GlobalHotkey { recordingCalls += 1 }
        let profile = GlobalHotkey(id: 2) { profileCalls += 1 }
        func send(_ id: UInt32, signature: OSType = 0x4d4e5431) {
            var event: EventRef?
            precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr)
            guard let event else { fatalError("Missing event") }
            defer { ReleaseEvent(event) }
            var hotkeyID = EventHotKeyID(signature: signature, id: id)
            precondition(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotkeyID) == noErr)
            _ = SendEventToEventTarget(event, GetApplicationEventTarget())
        }
        withExtendedLifetime((recording, profile)) {
            send(1)
            precondition(recordingCalls == 1 && profileCalls == 0, "Recording shortcut routed to wrong action")
            send(2)
            precondition(recordingCalls == 1 && profileCalls == 1, "Profile shortcut routed to wrong action")
            send(3)
            send(2, signature: 0)
            precondition(recordingCalls == 1 && profileCalls == 1, "Unrelated shortcuts must be ignored")
            send(1); send(2)
            precondition(recordingCalls == 2 && profileCalls == 2, "Repeated shortcuts must stay independent")
        }
        print("Passed 4 global shortcut routing checks.")
    }
}
