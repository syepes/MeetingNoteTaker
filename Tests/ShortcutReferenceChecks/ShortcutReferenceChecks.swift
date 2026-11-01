import AppKit
import Carbon
import SwiftUI

@main
struct ShortcutReferenceChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        for (code, label) in [(UInt32(15), "R"), (UInt32(46), "M"), (UInt32(49), "Space")] {
            let groups = ShortcutReferenceEntry.groups(keyCode: code, modifiers: UInt32(cmdKey | optionKey))
            let rows = groups.flatMap(\.commands)
            precondition(rows.count == 8 && Set(rows.map(\.id)).count == 8)
            precondition(rows[0].keys == ["⌥", "⌘", label])
            precondition(rows[1].keys == ["⌥", "⇧", "⌘", label])
            precondition(rows.filter(\.global).count == 2)
        }
        precondition(ShortcutReferenceEntry.recordingKeys(keyCode: 15, modifiers: UInt32(controlKey | cmdKey | shiftKey), addingShift: true) == ["⌃", "⇧", "⌘", "R"])
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = ShortcutReferenceView(keyCode: 15, modifiers: UInt32(cmdKey | optionKey), customize: {})
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
            let size = host.fittingSize
            precondition(size.width == 620 && size.height == 680)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.setFrameSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/shortcut-reference-\(name).png"))
            window.close()
        }
        print("Passed shortcut reference checks: all configured keys, Shift derivation, unique entries, global scope, light/dark layout.")
    }
}
