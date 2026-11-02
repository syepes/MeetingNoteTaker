import XCTest
@testable import MeetingCore

final class ParakeetPartialDownloadTests: XCTestCase {
    func testInterruptedBundlesAreNotInstalledOrSelectableAndRemainForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try ModelManager(root: root)
        let model = root.appendingPathComponent("parakeet").appendingPathComponent(ModelManager.parakeetFolderName("v3"))
        for name in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"] {
            let component = model.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
            try Data([1]).write(to: component.appendingPathComponent("coremldata.bin"))
        }
        try Data("{}".utf8).write(to: model.appendingPathComponent("parakeet_vocab.json"))
        let partial = model.appendingPathComponent("Encoder.mlmodelc/weight.bin.partial")
        try Data([1,2,3]).write(to: partial)
        XCTAssertThrowsError(try ModelManager.validateFile(model, kind: .parakeet))
        let installed = try await manager.installed(); XCTAssertTrue(installed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: partial), Data([1,2,3]))
        try FileManager.default.moveItem(at: partial, to: partial.deletingPathExtension())
        XCTAssertNoThrow(try ModelManager.validateFile(model, kind: .parakeet))
        let complete = try await manager.installed(); XCTAssertEqual(complete.count, 1)
        try FileManager.default.removeItem(at: model.appendingPathComponent("Decoder.mlmodelc/coremldata.bin"))
        XCTAssertThrowsError(try ModelManager.validateFile(model, kind: .parakeet))
    }
}
