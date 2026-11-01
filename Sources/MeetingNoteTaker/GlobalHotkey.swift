import Foundation
import Carbon

final class GlobalHotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32
    init(id: UInt32 = 1, action: @escaping () -> Void) {
        self.id = id
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(data).takeUnretainedValue()
            var pressed = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr,
                  pressed.signature == 0x4d4e5431, pressed.id == hotkey.id else { return OSStatus(eventNotHandledErr) }
            hotkey.action(); return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(keyCode: UInt32, modifiers: UInt32) throws {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x4d4e5431, id: id), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            throw NSError(domain: "MeetingNoteTaker.Shortcut", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "The \(id == 1 ? "recording" : "profile recording") shortcut is unavailable. Choose another combination."
            ])
        }
    }
    deinit { if let reference { UnregisterEventHotKey(reference) }; if let handler { RemoveEventHandler(handler) } }
}
