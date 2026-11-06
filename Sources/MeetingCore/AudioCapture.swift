import Foundation
import AVFoundation
import CoreAudio
import AudioDSP
import Accelerate

public struct MicrophoneDevice: Identifiable, Sendable { public var id: String; public var name: String; public var objectID: AudioDeviceID }
public enum AudioDevices {
    public static func discoverMicrophones() async -> [MicrophoneDevice] {
        await Task { @CaptureControl in microphones() }.value
    }
    static func selectedUID(requested: String, defaultDevice: AudioDeviceID, devices: [MicrophoneDevice]) -> String {
        requested.isEmpty ? (devices.first { $0.objectID == defaultDevice }?.id ?? "") : requested
    }
    public static func microphones() -> [MicrophoneDevice] { (try? checkedMicrophones()) ?? [] }
    static func checkedMicrophones() throws -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { throw MeetingError.message("Microphone discovery is temporarily unavailable.") }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size)/4)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { throw MeetingError.message("Microphone discovery is temporarily unavailable.") }
        return try ids.compactMap { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n) == noErr else { throw MeetingError.message("Microphone discovery is temporarily unavailable.") }
            guard n > 0 else { return nil }
            func string(_ selector: AudioObjectPropertySelector) throws -> String {
                var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var value: CFString = "" as CFString; var size = UInt32(MemoryLayout<CFString>.size)
                let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
                guard result == noErr else { throw MeetingError.message("Microphone identity is temporarily unavailable.") }
                return value as String
            }
            return try .init(id: string(kAudioDevicePropertyDeviceUID), name: string(kAudioObjectPropertyName), objectID: id)
        }
    }
}
@MainActor public protocol AudioCaptureBackend: AnyObject {
    func start(session: MeetingSession, microphoneID: String) async throws
    func pause()
    func resume()
    func stop() async throws -> [CaptureEvent]
}

final class CaptureRings: @unchecked Sendable {
    let mic = mnt_ring_create()!, computer = mnt_ring_create()!
    deinit { mnt_ring_destroy(mic); mnt_ring_destroy(computer) }
}

/// The audio callbacks only copy into preallocated C++ rings. Disk access,
/// journaling and allocation are confined to this serial writer queue.
final class CaptureWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "MeetingNoteTaker.audio.writer", qos: .userInitiated)
    let rings: CaptureRings
    let folder: URL
    let startHost: Double
    var handles: [AudioSource: FileHandle] = [:]
    var journal: CaptureEventJournal?
    var events: [CaptureEvent] = []
    var timer: DispatchSourceTimer?
    var failure: Error?
    var lastSync: Double = 0
    var batches: [AudioSource: Data] = [:]
    var metersEnabled = false
    var lastMeterUpdate: Double = 0
    var meterPeaks: [Float] = [0, 0]
    var pausedAt: Double?
    var pauses: [(Double, Double)] = []
    var onUpdate: (@Sendable (Float, Float, Int64?, String?) -> Void)?
    init(rings: CaptureRings, folder: URL, startHost: Double, session: MeetingSession?) throws {
        self.rings = rings; self.folder = folder; self.startHost = startHost
        if let session {
            journal = try CaptureEventJournal(directory: session.stagingURL)
            for source in AudioSource.allCases {
                let url = session.stagingURL.appendingPathComponent(source.rawValue + ".packets")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handles[source] = try FileHandle(forWritingTo: url)
            }
        }
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(30), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.drain() }; self.timer = timer; timer.resume()
    }
    func event(_ event: CaptureEvent) { queue.async { self.append(event) } }
    private func append(_ event: CaptureEvent) {
        if event.kind == .paused { pausedAt = event.time }
        if event.kind == .resumed, let start = pausedAt { pauses.append((start, event.time)); pausedAt = nil }
        // Heartbeats preserve elapsed silence on crash without filling UI/Markdown.
        if event.kind != .heartbeat { events.append(event) }
        do { try journal?.append(event, synchronize: event.kind != .heartbeat) }
        catch { failure = error }
    }
    func drain() {
        var levels: [Float] = []
        for (source, ring) in [(AudioSource.microphone, rings.mic), (.computer, rings.computer)] {
            var packet = MNTPacket(); var peak: Float = 0
            var data = batches.removeValue(forKey: source) ?? Data()
            data.removeAll(keepingCapacity: true)
            while mnt_ring_pop(ring, &packet) {
                guard failure == nil else { continue }
                do {
                    withUnsafeBytes(of: packet.time) { data.append(contentsOf: $0) }
                    withUnsafeBytes(of: packet.rate) { data.append(contentsOf: $0) }
                    withUnsafeBytes(of: packet.count) { data.append(contentsOf: $0) }
                    let packetTime = packet.time, packetRate = packet.rate, packetCount = Int(packet.count)
                    withUnsafeMutablePointer(to: &packet) { pointer in
                        let samples = UnsafeMutablePointer(mutating: mnt_packet_samples(pointer)!)
                        let packetEnd = packetTime + Double(packetCount-1)/packetRate
                        let overlaps = (pausedAt.map { packetEnd >= $0 } ?? false) || pauses.contains { packetEnd >= $0.0 && packetTime < $0.1 }
                        let fullyPaused = (pausedAt.map { packetTime >= $0 } ?? false) || pauses.contains { packetTime >= $0.0 && packetEnd < $0.1 }
                        if fullyPaused { samples.update(repeating: 0, count: packetCount) }
                        else if overlaps {
                            for i in 0..<packetCount {
                                let time = packetTime + Double(i)/packetRate
                                if (pausedAt.map { time >= $0 } ?? false) || pauses.contains(where: { time >= $0.0 && time < $0.1 }) { samples[i] = 0 }
                            }
                        }
                        if metersEnabled {
                            var packetPeak: Float = 0
                            vDSP_maxmgv(samples, 1, &packetPeak, vDSP_Length(packetCount))
                            peak = max(peak, packetPeak)
                        }
                        data.append(UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: packetCount*4)
                    }
                    // Bound batching memory even if callbacks keep filling the ring during a drain.
                    if data.count >= 256*1024 {
                        try handles[source]?.write(contentsOf: data)
                        data.removeAll(keepingCapacity: true)
                    }
                } catch { failure = error }
            }
            if failure == nil && !data.isEmpty {
                do { try handles[source]?.write(contentsOf: data) } catch { failure = error }
            }
            batches[source] = data
            levels.append(peak)
        }
        let elapsed = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - startHost
        var free: Int64?
        if elapsed-lastSync >= 5 {
            lastSync = elapsed
            free = (try? FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber)?.int64Value
            if let free, free < 128*1024*1024 { failure = MeetingError.message("Less than 128 MB of disk space remains. Recording stopped; saved chunks are recoverable.") }
            do {
                let syncStart = ProcessInfo.processInfo.systemUptime
                for handle in handles.values { try handle.synchronize() }
                // Force the heartbeat to stable storage with the audio checkpoint.
                try journal?.append(.init(time: elapsed, message: "", kind: .heartbeat), synchronize: true)
                let syncMilliseconds = Int((ProcessInfo.processInfo.systemUptime-syncStart)*1000)
                if syncMilliseconds >= 100 {
                    try journal?.append(.init(time: elapsed, message: "Audio checkpoint synchronization took \(syncMilliseconds) ms.", kind: .captureDiagnostic))
                }
            } catch { failure = error }
        }
        // A processed packet cannot arrive before its ring's previous packet. Retain
        // only pause intervals that can still intersect delayed buffers (10 seconds).
        pauses.removeAll { $0.1 < elapsed-10 }
        meterPeaks[0] = max(meterPeaks[0], levels[0]); meterPeaks[1] = max(meterPeaks[1], levels[1])
        if (metersEnabled && elapsed-lastMeterUpdate >= 0.1) || free != nil || failure != nil {
            lastMeterUpdate = elapsed
            onUpdate?(meterPeaks[0], meterPeaks[1], free, failure?.localizedDescription)
            meterPeaks = [0, 0]
        }
    }
    func stop(at time: Double) async throws -> [CaptureEvent] {
        timer?.cancel(); timer = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.drain(); self.append(.init(time: time, message: "Recording stopped.", kind: .stopped))
                var closeError: Error?
                for handle in self.handles.values { do { try handle.synchronize(); try handle.close() } catch { closeError = error } }
                self.handles = [:]
                do { try self.journal?.close() } catch { closeError = error }; self.journal = nil
                if let error = self.failure ?? closeError { continuation.resume(throwing: error) }
                else { continuation.resume(returning: self.events) }
            }
        }
    }
}

/// All source lifecycle operations run on the capture-control executor. The realtime callbacks
/// capture only rings and a fixed monotonic origin, never mutable capture state.
@CaptureControl final class CaptureWorker {
    private let rings = CaptureRings()
    private var writer: CaptureWriter?
    public var metersEnabled = false {
        didSet { if let writer { let enabled = metersEnabled; writer.queue.async { writer.metersEnabled = enabled; writer.meterPeaks = [0, 0] } } }
    }
    private var discoveryDirty = true
    private var lastDiscovery: Double = -.infinity
    private var cachedMicrophones: [MicrophoneDevice] = []
    private var cachedProcesses: [AudioObjectID] = []
    private var discoveryListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var engine: AVAudioEngine?
    private var tapID: AudioObjectID = 0, aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var monitor: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var startHost: Double = 0
    private var micID = "", resolvedMicID = ""
    private var target = CaptureTarget()
    private var microphoneWasAvailable = false
    private var outputDevice: AudioDeviceID = 0
    private var processIDs: [AudioObjectID] = []
    private var running = false, paused = false, fatalReported = false
    private var recovery: [AudioSource: SourceRecovery] = [:]
    private var configurationTask: Task<Void, Never>?
    private var configurationWindow = ConfigurationChangeWindow()
    private var inputRate: Double = 0
    private var inputChannels: AVAudioChannelCount = 0
    private var microphoneDiscoveryValid = false
    private var processDiscoveryValid = false
    private var outputWasAvailable = true
    private var lastDiscoveredProcesses: [AudioObjectID] = []
    public private(set) var diagnostics = CaptureDiagnostics(microphoneUID: nil, microphoneEnabled: true)
    private var gapStart: [AudioSource: Double] = [:]
    private var restartedAt: [AudioSource: Double] = [:]
    public private(set) var health = CaptureHealthSnapshot()
    public private(set) var wallStart = Date()
    public private(set) var fatalError: String?
    public private(set) var stoppedElapsed: Double = 0
    public var elapsed: Double { running ? AVAudioTime.seconds(forHostTime: mach_absolute_time()) - startHost : stoppedElapsed }
    public var onLevels: ((Float, Float) -> Void)?
    public var onFailure: ((String) -> Void)?
    public var onFatal: ((String) -> Void)?
    public var onHealth: ((CaptureHealthSnapshot) -> Void)?
    private var publishedHealth: CaptureHealthSnapshot?
    private func publishHealth() {
        let presentation = health.presentation
        guard presentation != publishedHealth else { return }
        publishedHealth = presentation
        onHealth?(health)
    }
    public var microphoneEnabled: Bool {
        get { !mnt_ring_is_muted(rings.mic) }
        set {
            mnt_ring_set_muted(rings.mic, !newValue)
            if running {
                record(.microphoneChanged, source: .microphone, "Microphone recording \(newValue ? "enabled" : "disabled").")
                if newValue && engine == nil { recovery[.microphone, default: .init()].failed(at: elapsed); recovery[.microphone, default: .init()].returned(at: elapsed) }
                if newValue { diagnostics.microphone.expected = true }
                if !newValue { health.microphone.availability = .disabled; health.microphone.message = "Microphone recording off" }
            }
        }
    }
    nonisolated init() {}
    var state: (health: CaptureHealthSnapshot, wallStart: Date, fatalError: String?, stoppedElapsed: Double, startHost: Double, running: Bool, diagnostics: CaptureDiagnostics) {
        (health, wallStart, fatalError, stoppedElapsed, startHost, running, diagnostics)
    }
    private func check(_ code: OSStatus, _ operation: String) throws {
        guard code == noErr else { throw MeetingError.message("\(operation) failed (Core Audio \(code)). Check audio permissions and the selected device.") }
    }
    public func start(session: MeetingSession, microphoneID: String) async throws {
        try await start(folder: URL(fileURLWithPath: session.folder), session: session, target: session.captureTarget ?? .init(), microphoneID: microphoneID)
    }
    public func startCheck(folder: URL, target: CaptureTarget, microphoneID: String) async throws {
        metersEnabled = true
        try await start(folder: folder, session: nil, target: target, microphoneID: microphoneID)
    }
    private func start(folder: URL, session: MeetingSession?, target: CaptureTarget, microphoneID: String) async throws {
        guard !running else { throw MeetingError.message("Audio capture is already running.") }
        if microphoneEnabled { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        mnt_ring_reset(rings.mic); mnt_ring_reset(rings.computer)
        health = .init(); publishedHealth = nil; recovery = [:]; gapStart = [:]; restartedAt = [:]; processIDs = []
        self.target = target; micID = microphoneID
        cachedMicrophones = []; cachedProcesses = []; lastDiscoveredProcesses = []
        // Always discover again after permission prompts, before opening either source.
        refreshDiscovery(at: 0)
        // Resolve the system default once. Reconnection must not substitute another microphone.
        if micID.isEmpty {
            let id = AudioApplications.property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0))
            resolvedMicID = AudioDevices.selectedUID(requested: micID, defaultDevice: id, devices: cachedMicrophones)
        } else { resolvedMicID = micID }
        diagnostics = .init(microphoneUID: resolvedMicID.isEmpty ? nil : resolvedMicID, microphoneEnabled: microphoneEnabled)
        microphoneWasAvailable = cachedMicrophones.contains { $0.id == resolvedMicID }
        startHost = AVAudioTime.seconds(forHostTime: mach_absolute_time()); wallStart = Date()
        stoppedElapsed = 0; paused = false; fatalReported = false; fatalError = nil; health.phase = .recording
        let free = (try FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber)?.int64Value
        if let free {
            guard free >= 128*1024*1024 else { throw MeetingError.message("At least 128 MB of free space is required to start recording.") }
            health.availableBytes = free; health.storageWarning = CaptureRecoveryPolicy.storageState(bytes: free)
        }
        outputDevice = AudioApplications.property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
        let writer = try CaptureWriter(rings: rings, folder: folder, startHost: startHost, session: session); self.writer = writer
        writer.metersEnabled = metersEnabled
        discoveryDirty = true; lastDiscovery = -.infinity
        installDiscoveryListeners()
        writer.onUpdate = { [weak self] mic, computer, free, error in
            Task { @CaptureControl in
                guard let self, self.running else { return }
                if self.metersEnabled { self.onLevels?(mic, computer) }
                if let free { self.health.availableBytes = free; self.health.storageWarning = CaptureRecoveryPolicy.storageState(bytes: free) }
                if let error, !self.fatalReported { self.fatalReported = true; self.fatalError = error; self.onFatal?(error) }
            }
        }
        running = true; writer.start(); record(.started, "Capture started.")
        // Subscribe before either device is started; startup can itself change the I/O graph.
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            Task { @CaptureControl in
                guard let self, self.running, let engine = self.engine, note.object as? AVAudioEngine === engine else { return }
                self.scheduleConfigurationCheck()
            }
        })
        retry(.computer)
        if microphoneEnabled { retry(.microphone) } else { health.microphone.availability = .disabled }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.running else { return }
                self.inspect()
            }
        }
        publishHealth()
    }
    private func record(_ kind: CaptureEventKind, source: AudioSource? = nil, _ text: String) {
        let time = elapsed
        writer?.event(.init(time: time, message: text, kind: kind, source: source, wallTime: wallStart.addingTimeInterval(time)))
    }
    public func pause() {
        guard running, !paused else { return }; paused = true
        let time = elapsed; mnt_ring_pause(rings.mic, time); mnt_ring_pause(rings.computer, time)
        health.phase = .paused; record(.paused, "Recording paused; silence preserves elapsed time."); publishHealth()
    }
    public func resume() {
        guard running, paused else { return }; paused = false
        let time = elapsed; mnt_ring_resume(rings.mic, time); mnt_ring_resume(rings.computer, time)
        health.phase = .recording; record(.resumed, "Recording resumed."); publishHealth()
    }
    private func scheduleConfigurationCheck() {
        let now = elapsed
        configurationWindow.changed(at: now)
        guard configurationTask == nil else { return }
        configurationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.running else { return }
                let remaining = self.configurationWindow.deadline - self.elapsed
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)); continue }
                self.configurationTask = nil; self.configurationWindow.reset()
                guard let engine = self.engine else { return }
                let format = engine.inputNode.outputFormat(forBus: 0)
                let recent = self.elapsed - mnt_ring_last_time(self.rings.mic) < 3
                if !engine.isRunning || format.sampleRate != self.inputRate || format.channelCount != self.inputChannels || !recent {
                    self.degrade(.microphone, "Microphone configuration changed; reconnecting the selected microphone.")
                    self.publishHealth()
                }
                return
            }
        }
    }
    private func degrade(_ source: AudioSource, _ message: String) {
        if gapStart[source] == nil { gapStart[source] = elapsed; record(.gapBegan, source: source, message + " Missing audio remains silence.") }
        recovery[source, default: .init()].failed(at: elapsed)
        if source == .microphone {
            health.microphone.availability = .recovering; health.microphone.message = message
            diagnostics.microphone.lastFailure = message; stopMicrophone()
        } else {
            health.computer.availability = .recovering; health.computer.message = message
            diagnostics.computer.lastFailure = message; stopSystemAudio()
        }
    }
    private func retry(_ source: AudioSource) {
        recovery[source, default: .init()].started()
        let began = elapsed
        if source == .microphone { if diagnostics.microphone.lastFailure != nil { diagnostics.microphone.recoveryAttempts += 1 } }
        else if diagnostics.computer.lastFailure != nil { diagnostics.computer.recoveryAttempts += 1 }
        do {
            if source == .microphone {
                guard microphoneEnabled else { return }
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw MeetingError.message("Microphone permission is unavailable.") }
                try startMicrophone(); health.microphone.message = "Waiting for microphone audio"
            } else {
                try startSystemAudio(); health.computer.message = "Waiting for computer audio"
            }
            restartedAt[source] = began
        } catch { degrade(source, error.localizedDescription) }
        let milliseconds = Int((elapsed-began)*1000)
        record(.recoveryAttempt, source: source, "Capture attempt completed in \(milliseconds) ms.")
    }
    private func installDiscoveryListeners() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @CaptureControl in self?.discoveryDirty = true }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr { discoveryListeners.append((address, block)) }
        }
    }
    private func refreshDiscovery(at time: Double) {
        do { cachedMicrophones = try AudioDevices.checkedMicrophones(); microphoneDiscoveryValid = true }
        catch { microphoneDiscoveryValid = false }
        do { cachedProcesses = try AudioApplications.checkedResolve(target).ids; processDiscoveryValid = true }
        catch { processDiscoveryValid = false }
        discoveryDirty = false; lastDiscovery = time
    }
    private func inspect() {
        let now = elapsed
        if discoveryDirty || now-lastDiscovery >= 5 { refreshDiscovery(at: now) }
        let microphoneAvailable = cachedMicrophones.contains { $0.id == resolvedMicID }
        if microphoneDiscoveryValid {
            if microphoneAvailable && !microphoneWasAvailable { recovery[.microphone, default: .init()].returned(at: now) }
            microphoneWasAvailable = microphoneAvailable
            if microphoneEnabled && engine != nil && !microphoneAvailable { degrade(.microphone, "Selected microphone disconnected.") }
        }
        if processDiscoveryValid {
            if target.bundleID != nil && cachedProcesses != processIDs {
                degrade(.computer, cachedProcesses.isEmpty ? "Selected application is unavailable." : "Selected application audio processes changed.")
                if !cachedProcesses.isEmpty && cachedProcesses != lastDiscoveredProcesses { recovery[.computer, default: .init()].returned(at: now) }
            }
            lastDiscoveredProcesses = cachedProcesses
        }
        do {
            let output = try AudioApplications.checkedProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
            let available = try output != 0 && AudioApplications.checkedProperty(output, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) != 0
            if !available && outputWasAvailable { degrade(.computer, "Computer output device disconnected.") }
            if available && (!outputWasAvailable || output != outputDevice) {
                outputDevice = output; degrade(.computer, "Computer output device changed or reconnected.")
                recovery[.computer, default: .init()].returned(at: now)
            }
            outputWasAvailable = available
        } catch { /* An unavailable query is not evidence of a disconnect. */ }
        let computerActive = cachedProcesses.contains { AudioApplications.property($0, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) != 0 }
        for source in AudioSource.allCases {
            if source == .microphone && !microphoneEnabled { continue }
            let ring = source == .microphone ? rings.mic : rings.computer
            let last = mnt_ring_last_time(ring), dropped = mnt_ring_dropped(ring)
            var status = source == .microphone ? health.microphone : health.computer
            if dropped > status.droppedBuffers { record(.buffersDropped, source: source, "\(dropped-status.droppedBuffers) audio buffers rejected; gaps preserved.") }
            status.droppedBuffers = dropped; status.lastBufferTime = last >= 0 ? last : nil
            let attached = source == .microphone ? engine != nil : aggregateID != 0
            let active = source == .microphone || computerActive
            let liveness = SourceLiveness.evaluate(attached: attached, active: active, lastAccepted: last, started: restartedAt[source] ?? now, now: now)
            if liveness == .receiving {
                recovery[source, default: .init()].received(at: now)
                status.availability = .available; status.message = "Receiving audio"
                if gapStart.removeValue(forKey: source) != nil { record(.gapEnded, source: source, "\(source.label) capture recovered.") }
            } else {
                recovery[source, default: .init()].interrupted()
                if attached && !active { status.availability = .waiting; status.message = "Waiting for audio" }
            }
            status.recoveryAttempt = recovery[source]?.failures ?? 0
            if source == .microphone { health.microphone = status } else { health.computer = status }
            if liveness == .stalled { degrade(source, "No audio buffers received; reconnecting the selected source.") }
            if recovery[source]?.due(at: now) == true { retry(source) }
        }
        publishHealth()
    }
    private func stopMicrophone() {
        configurationTask?.cancel(); configurationTask = nil; configurationWindow.reset()
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
    }
    private func startMicrophone() throws {
        let e = AVAudioEngine(); let input = e.inputNode
        guard !resolvedMicID.isEmpty else { throw MeetingError.message("The selected microphone is unavailable.") }
        if !resolvedMicID.isEmpty {
            guard let device = try AudioDevices.checkedMicrophones().first(where: { $0.id == resolvedMicID }) else { throw MeetingError.message("Selected microphone is unavailable.") }
            if let unit = input.audioUnit {
                var current = AudioDeviceID(0); var size = UInt32(MemoryLayout.size(ofValue: current))
                try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size), "Read microphone")
                if current != device.objectID {
                    var id = device.objectID
                    try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id))), "Select microphone")
                }
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else { throw MeetingError.message("Microphone has no input channels.") }
        let rings = self.rings, origin = startHost
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            guard let data = buffer.floatChannelData else { return }
            let time = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) - origin : AVAudioTime.seconds(forHostTime: mach_absolute_time()) - origin
            let channels = UnsafeRawPointer(data).assumingMemoryBound(to: UnsafePointer<Float>?.self)
            _ = mnt_ring_push(rings.mic, channels, buffer.format.channelCount, buffer.format.isInterleaved ? buffer.format.channelCount : 1, buffer.frameLength, buffer.format.sampleRate, time, false)
        }
        inputRate = format.sampleRate; inputChannels = format.channelCount
        engine = e
        e.prepare(); try e.start()
    }
    private func startSystemAudio() throws {
        var processID: AudioObjectID = 0; var pid = getpid()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout.size(ofValue: processID))
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout.size(ofValue: pid)), &pid, &size, &processID)
        let resolved = try AudioApplications.checkedResolve(target); processIDs = resolved.ids
        if target.bundleID != nil && processIDs.isEmpty { throw MeetingError.message("Selected application is unavailable; waiting for its audio process.") }
        let description = target.bundleID == nil ? CATapDescription(stereoGlobalTapButExcludeProcesses: processID == 0 ? [] : [processID]) : CATapDescription(stereoMixdownOfProcesses: processIDs)
        defer { if aggregateID == 0 { stopSystemAudio() } }
        description.name = "MeetingNoteTaker system audio"; description.isPrivate = true; description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create audio tap")
        var asbd = AudioStreamBasicDescription()
        addr.mSelector = kAudioTapPropertyFormat; size = UInt32(MemoryLayout.size(ofValue: asbd))
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "Read tap format")
        guard asbd.mSampleRate > 0, asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { throw MeetingError.message("Unsupported system audio format.") }
        let dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingNoteTaker private tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregateID), "Create capture device")
        let rate = asbd.mSampleRate, origin = startHost
        let rings = self.rings
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { _, input, stamp, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let raw = first.mData, first.mDataByteSize > 0 else { return }
            guard first.mNumberChannels > 0 else { return }
            let time = stamp.pointee.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: stamp.pointee.mHostTime) - origin : AVAudioTime.seconds(forHostTime: mach_absolute_time()) - origin
            if buffers.count == 1 {
                let pointer = raw.assumingMemoryBound(to: Float.self)
                let n = first.mNumberChannels
                var ptrs: (UnsafePointer<Float>?, UnsafePointer<Float>?) = (UnsafePointer(pointer), n > 1 ? UnsafePointer(pointer.advanced(by: 1)) : nil)
                withUnsafePointer(to: &ptrs) { p in p.withMemoryRebound(to: UnsafePointer<Float>?.self, capacity: 2) { _ = mnt_ring_push(rings.computer, $0, min(n, 2), n, first.mDataByteSize / 4 / n, rate, time, false) } }
            } else {
                var ptrs: (UnsafePointer<Float>?, UnsafePointer<Float>?) = (UnsafePointer(raw.assumingMemoryBound(to: Float.self)), buffers.count > 1 ? buffers[1].mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) } : nil)
                withUnsafePointer(to: &ptrs) { p in p.withMemoryRebound(to: UnsafePointer<Float>?.self, capacity: 2) { _ = mnt_ring_push(rings.computer, $0, 2, 1, first.mDataByteSize / 4, rate, time, false) } }
            }
        }, "Install capture callback")
        try check(AudioDeviceStart(aggregateID, ioProc), "Start system audio")
    }
    public func stop() async throws -> [CaptureEvent] {
        guard running else { return [] }
        stoppedElapsed = elapsed; running = false; health.phase = .stopped
        monitor?.cancel(); monitor = nil
        for (var address, block) in discoveryListeners { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) }
        discoveryListeners.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        stopMicrophone(); stopSystemAudio()
        for source in AudioSource.allCases {
            let ring = source == .microphone ? rings.mic : rings.computer
            var detail = source == .microphone ? diagnostics.microphone : diagnostics.computer
            detail.acceptedFrames = mnt_ring_accepted_frames(ring); detail.rejectedBuffers = mnt_ring_dropped(ring)
            let first = mnt_ring_first_time(ring), last = mnt_ring_last_time(ring)
            detail.firstBufferTime = detail.acceptedFrames > 0 ? first : nil; detail.lastBufferTime = last >= 0 ? last : nil
            if source == .microphone { diagnostics.microphone = detail } else { diagnostics.computer = detail }
        }
        let writer = self.writer; self.writer = nil
        return try await writer?.stop(at: stoppedElapsed) ?? []
    }
    private func stopSystemAudio() {
        if aggregateID != 0 { _ = AudioDeviceStop(aggregateID, ioProc); if let ioProc { _ = AudioDeviceDestroyIOProcID(aggregateID, ioProc) }; _ = AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { _ = AudioHardwareDestroyProcessTap(tapID); tapID = 0 }; ioProc = nil
    }
}
