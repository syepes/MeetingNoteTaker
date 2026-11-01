import XCTest
import FluidAudio
@testable import MeetingCore

final class ParakeetSampleIntegrationTests: XCTestCase {
    func testASROnlyConfiguration() {
        XCTAssertFalse(TextNormalizer().isNativeAvailable, "NeMo must not be linked in the ASR-only build")
        XCTAssertTrue(ASRConfig.default.seamTimingRealignment)
    }

    func testV2FileAndSamples() async throws { try await compare(version: "v2", modelVariable: "MNT_PARAKEET_V2_MODEL") }
    func testV3FileAndSamples() async throws { try await compare(version: "v3", modelVariable: "MNT_PARAKEET_V3_MODEL") }
    func testUltraFileAndSamples() async throws { try await compare(version: "ultra", modelVariable: "MNT_PARAKEET_ULTRA_MODEL") }

    private func compare(version: String, modelVariable: String) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let model = env[modelVariable], let english = env["MNT_TEST_AUDIO"] else {
            throw XCTSkip("Set \(modelVariable) and MNT_TEST_AUDIO for offline file/sample parity; no weights are downloaded.")
        }
        var audio = [english]
        if version != "v2" {
            guard let french = env["MNT_FRENCH_TEST_AUDIO"] else { throw XCTSkip("Set MNT_FRENCH_TEST_AUDIO for multilingual parity.") }
            audio.append(french)
        }
        var settings = SpeechSettings(); settings.engine = .parakeet
        settings.modelPath = model; settings.parakeetVersion = version
        let provider = ParakeetProvider(settings)
        try await provider.prepare()
        do {
            for path in audio {
                let samples = try AudioFiles.samples(URL(fileURLWithPath: path), channel: 0, start: 0, duration: 25)
                XCTAssertFalse(samples.isEmpty)
                let duration = Double(samples.count) / 16000
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
                defer { try? FileManager.default.removeItem(at: file) }
                try AudioFiles.writeWAV(samples, to: file)
                let direct = try await provider.transcribe(samples: samples, sampleRate: 16000, source: .computer, offset: 25, duration: duration)
                let decoded = try await provider.transcribe(file, source: .computer, offset: 25, duration: duration)
                XCTAssertFalse(direct.isEmpty, "Use a spoken-language fixture, not silence")
                XCTAssertEqual(direct.map(\.text), decoded.map(\.text))
                XCTAssertEqual(direct.count, decoded.count)
                for (a, b) in zip(direct, decoded) {
                    XCTAssertEqual(a.start, b.start, accuracy: 0.08)
                    XCTAssertEqual(a.end, b.end, accuracy: 0.08)
                    XCTAssertEqual(a.source, .computer)
                    XCTAssertGreaterThanOrEqual(a.start, 25)
                    XCTAssertLessThanOrEqual(a.end, 25 + duration)
                }
            }
            await provider.shutdown()
        } catch { await provider.shutdown(); throw error }
    }
}
