import Foundation
import AVFoundation
import AudioDSP

/// A bounded, timestamped stream reader. A truncated final packet is ignored on recovery.
final class PacketReader {
    let file: FileHandle
    var samples: [Float] = []
    var time: Double = 0
    var rate: Double = 48000
    var eof = false
    init(_ url: URL) throws { file = try FileHandle(forReadingFrom: url); try advance() }
    deinit { try? file.close() }
    func advance() throws {
        guard let header = try file.read(upToCount: 20), header.count == 20 else { eof = true; samples = []; return }
        time = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Double.self) }
        rate = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Double.self) }
        let count = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        guard time.isFinite, time >= -1, rate.isFinite, rate >= 8000, rate <= 384000, count > 0, count <= 8192 else { throw MeetingError.message("Damaged audio recovery packet.") }
        guard let payload = try file.read(upToCount: Int(count)*4), payload.count == Int(count)*4 else { eof = true; samples = []; return }
        samples = payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    func sample(at target: Double) throws -> Float {
        while !eof && target >= time + Double(samples.count)/rate { try advance() }
        guard !eof, target >= time else { return 0 }
        let position = (target-time)*rate; let index = min(samples.count-1, Int(position)); let next = min(samples.count-1,index+1)
        let alpha = Float(position-Double(index)); return samples[index]*(1-alpha) + samples[next]*alpha
    }
    static func duration(_ url: URL) throws -> Double {
        let reader = try PacketReader(url); var end: Double = 0
        while !reader.eof { end = max(end, reader.time + Double(reader.samples.count)/reader.rate); try reader.advance() }
        return end
    }
}
public enum AudioFiles {
    public static func finalize(_ session: MeetingSession) throws -> (duration: Double, fingerprint: String) {
        let receipt = session.stagingURL.appendingPathComponent("finalized.sha256")
        if let expected = try? String(contentsOf: receipt, encoding: .utf8), FileManager.default.fileExists(atPath: session.audioURL.path),
           (try? audioFingerprint(session.audioURL)) == expected {
            let file = try AVAudioFile(forReading: session.audioURL)
            guard file.processingFormat.channelCount == 2 else { throw MeetingError.message("Recovery audio has an invalid channel layout.") }
            return (Double(file.length)/file.processingFormat.sampleRate, expected)
        }
        let micURL = session.stagingURL.appendingPathComponent("microphone.packets")
        let computerURL = session.stagingURL.appendingPathComponent("computer.packets")
        let duration = try max(session.duration, max(PacketReader.duration(micURL), PacketReader.duration(computerURL)))
        guard duration > 0 else { throw MeetingError.message("No audio was captured. Check microphone and system-audio permissions.") }
        let mic = try PacketReader(micURL); let computer = try PacketReader(computerURL)
        let temp = session.stagingURL.appendingPathComponent("final.m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
        var output: AVAudioFile? = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var pauses: [(Double, Double)] = []; var pauseStart: Double?
        for event in session.events {
            if event.kind == .paused { pauseStart = event.time }
            if event.kind == .resumed, let start = pauseStart { pauses.append((start, event.time)); pauseStart = nil }
        }
        if let start = pauseStart { pauses.append((start, duration)) }
        var pauseIndex = 0
        let frames = Int64((duration*48000).rounded(.up)); var position: Int64 = 0
        while position < frames {
            try Task.checkCancellation()
            let count = min(4096, Int(frames-position)); buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count {
                let time = Double(position + Int64(i))/48000
                while pauseIndex < pauses.count && pauses[pauseIndex].1 <= time { pauseIndex += 1 }
                let paused = pauseIndex < pauses.count && time >= pauses[pauseIndex].0
                let micSample = try mic.sample(at: time), computerSample = try computer.sample(at: time)
                buffer.floatChannelData![0][i] = paused ? 0 : micSample
                buffer.floatChannelData![1][i] = paused ? 0 : computerSample
            }
            try output!.write(from: buffer); position += Int64(count)
        }
        output = nil // finalize the M4A container before verifying or replacing the reserved file
        let check = try AVAudioFile(forReading: temp)
        guard check.length == frames, check.processingFormat.channelCount == 2 else { throw MeetingError.message("Audio finalization verification failed.") }
        let checksum = try audioFingerprint(temp)
        try Task.checkCancellation()
        try checksum.write(to: receipt, atomically: true, encoding: .utf8)
        // The original file is our exclusively reserved placeholder, or a prior finalization.
        if FileManager.default.fileExists(atPath: session.audioURL.path) {
            let size = (try session.audioURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size == 0 else { throw MeetingError.message("The reserved audio path already contains data; recovery will not overwrite it.") }
            _ = try FileManager.default.replaceItemAt(session.audioURL, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: session.audioURL) }
        return (duration, checksum)
    }
    /// Read only one bounded window; the full meeting is never materialized in memory.
    public static func samples(_ url: URL, channel: Int, start: Double, duration: Double, rate: Double = 16000) throws -> [Float] {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        guard channel >= 0, channel < Int(format.channelCount) else { throw MeetingError.message("Invalid source channel.") }
        input.framePosition = min(input.length, AVAudioFramePosition(start * format.sampleRate))
        let count = min(Int(input.length-input.framePosition), Int(duration * format.sampleRate))
        guard count > 0 else { return [] }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        try input.read(into: buffer, frameCount: AVAudioFrameCount(count))
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength)!
        mono.frameLength = buffer.frameLength
        guard let data = buffer.floatChannelData else { throw MeetingError.message("Audio decoder did not provide Float32 samples.") }
        if format.isInterleaved { for i in 0..<Int(buffer.frameLength) { mono.floatChannelData![0][i] = data[0][i*Int(format.channelCount)+channel] } }
        else { mono.floatChannelData![0].update(from: data[channel], count: Int(buffer.frameLength)) }
        let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard let converter = AVAudioConverter(from: monoFormat, to: target) else { throw MeetingError.message("Cannot convert audio format.") }
        let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(count)*rate/format.sampleRate)+1024))!
        var fed = false; var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return mono
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
    }
    public static func writeWAV(_ samples: [Float], to url: URL, rate: Double = 16000) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1,samples.count)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { if let base = $0.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) } }
        try output.write(from: buffer)
    }
    public static func reduceEcho(microphone: inout [Float], computer: [Float]) {
        let count = min(microphone.count, computer.count)
        guard count > 0 else { return }
        microphone.withUnsafeMutableBufferPointer { mic in computer.withUnsafeBufferPointer { ref in _ = mnt_reduce_echo(mic.baseAddress!, ref.baseAddress!, UInt32(count), 16000) } }
    }
    public static func containsSpeechEnergy(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        let energy = samples.reduce(0.0) { $0 + Double($1*$1) } / Double(samples.count)
        return energy > 0.00000025 // silence gate, not a semantic voice classifier
    }
}
