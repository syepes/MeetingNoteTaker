import AppKit
import CoreAudio
import Darwin

public enum AudioApplications {
    public static func available() -> [CaptureTarget] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return CaptureTarget(bundleID: id, name: app.localizedName ?? id)
        }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
    static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = initial; var size = UInt32(MemoryLayout<T>.size)
        _ = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return value
    }
    static func checkedProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = initial; var size = UInt32(MemoryLayout<T>.size)
        let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard result == noErr else { throw MeetingError.message("Audio process identity is temporarily unavailable.") }
        return value
    }
    static func processes() -> [AudioObjectID] { (try? checkedProcesses()) ?? [] }
    static func checkedProcesses() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { throw MeetingError.message("Audio application discovery is temporarily unavailable.") }
        var result = [AudioObjectID](repeating: 0, count: Int(size)/4)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &result) == noErr else { throw MeetingError.message("Audio application discovery is temporarily unavailable.") }
        return result
    }
    /// Exact bundle identity or a verified process ancestor. A bundle-ID prefix
    /// alone is not sufficient to attribute another application's audio.
    static func resolves(_ pid: pid_t, targetPIDs: Set<pid_t>) -> Bool {
        var current = pid
        for _ in 0..<12 {
            if targetPIDs.contains(current) { return true }
            guard current > 1 else { return false }
            var info = proc_bsdinfo()
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info), info.pbi_ppid != UInt32(current) else { return false }
            current = pid_t(info.pbi_ppid)
        }
        return false
    }
    static func resolve(_ target: CaptureTarget) -> (ids: [AudioObjectID], active: Bool) {
        (try? checkedResolve(target)) ?? ([], false)
    }
    static func checkedResolve(_ target: CaptureTarget) throws -> (ids: [AudioObjectID], active: Bool) {
        let all = try checkedProcesses()
        let ids: [AudioObjectID]
        if let bundleID = target.bundleID {
            let parents = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
            ids = try all.filter { object in
                let bundle = try checkedProperty(object, kAudioProcessPropertyBundleID, initial: "" as CFString) as String
                let pid = try checkedProperty(object, kAudioProcessPropertyPID, initial: pid_t(0))
                return bundle == bundleID || resolves(pid, targetPIDs: parents)
            }
        } else { ids = try all.filter { try checkedProperty($0, kAudioProcessPropertyPID, initial: pid_t(0)) != getpid() } }
        return (ids.sorted(), ids.contains { property($0, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) != 0 })
    }
}
