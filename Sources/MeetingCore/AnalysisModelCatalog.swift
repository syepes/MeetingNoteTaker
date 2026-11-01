import Foundation

/// Serialized with AnalysisSettings so queued jobs retain their generation behavior.
public struct AnalysisInferencePreset: Codable, Equatable, Sendable {
    public var disableThinking: Bool
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public init(disableThinking: Bool, temperature: Double, topP: Double = 0.95, topK: Int = 40) {
        self.disableThinking = disableThinking; self.temperature = temperature; self.topP = topP; self.topK = topK
    }
}
public struct CatalogModelIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let revision: String
    public let sha256: String
}
public struct AnalysisCatalogEntry: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let repository: String
    public let filename: String
    public let revision: String
    public let sha256: String
    public let bytes: Int64
    public let quantization: String
    public let preset: AnalysisInferencePreset
    public let runtimeVerified: Bool
    public var license: String { "Apache-2.0" }
    public var balanced: Bool { id == "qwen35-9b-q4km" }
    public var identity: CatalogModelIdentity { .init(id: id, revision: revision, sha256: sha256) }
    public var sourceURL: URL { URL(string: "https://huggingface.co/\(repository)")! }
    public var downloadURL: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")! }
    public func configuring(_ settings: AnalysisSettings, path: String, resetBudgets: Bool) -> AnalysisSettings {
        var result = settings
        result.engine = .builtin; result.modelPath = path; result.catalogModel = identity; result.inferencePreset = preset
        if resetBudgets { result.contextTokens = 8192; result.outputTokens = 1536 }
        return result
    }
}
public enum AnalysisModelCatalog {
    public static let entries: [AnalysisCatalogEntry] = [
        .init(id: "qwen35-4b-q4km", title: "Qwen3.5 4B", detail: "Lightweight · Multilingual", repository: "unsloth/Qwen3.5-4B-GGUF", filename: "Qwen3.5-4B-Q4_K_M.gguf", revision: "e87f176479d0855a907a41277aca2f8ee7a09523", sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4", bytes: 2740937888, quantization: "Q4_K_M", preset: .init(disableThinking: true, temperature: 0.7, topP: 0.8, topK: 20), runtimeVerified: false),
        .init(id: "qwen35-9b-q4km", title: "Qwen3.5 9B", detail: "Balanced · Provisional recommendation", repository: "unsloth/Qwen3.5-9B-GGUF", filename: "Qwen3.5-9B-Q4_K_M.gguf", revision: "3885219b6810b007914f3a7950a8d1b469d598a5", sha256: "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8", bytes: 5680522464, quantization: "Q4_K_M", preset: .init(disableThinking: true, temperature: 0.7, topP: 0.8, topK: 20), runtimeVerified: false),
        .init(id: "gemma4-12b-q4km", title: "Gemma 4 12B IT", detail: "Summarization alternative · Multilingual", repository: "unsloth/gemma-4-12b-it-GGUF", filename: "gemma-4-12b-it-Q4_K_M.gguf", revision: "fc034cfff751157913579611efad8462ac1be606", sha256: "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42", bytes: 7121861440, quantization: "Q4_K_M", preset: .init(disableThinking: true, temperature: 0.1), runtimeVerified: false),
        .init(id: "ministral3-14b-q4km", title: "Ministral 3 14B Instruct", detail: "English/French extraction · Instruction tuned", repository: "mistralai/Ministral-3-14B-Instruct-2512-GGUF", filename: "Ministral-3-14B-Instruct-2512-Q4_K_M.gguf", revision: "74fac473c43357d7fb2671713608183cc72496d0", sha256: "824e0f3373e69b84f2cae46fdcb9bd1ebc6ab3bfc7acc125d818b7b8178cc613", bytes: 8239593024, quantization: "Q4_K_M", preset: .init(disableThinking: false, temperature: 0.05), runtimeVerified: false),
        .init(id: "qwen38-27b-udq4km", title: "Qwen3.8 27B", detail: "Larger analysis model · Multilingual", repository: "unsloth/Qwen3.8-27B-GGUF", filename: "Qwen3.8-27B-UD-Q4_K_M.gguf", revision: "4ca720788d1e01f1bff70c033e0d0028fd02e502", sha256: "322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482", bytes: 16464440224, quantization: "UD-Q4_K_M", preset: .init(disableThinking: true, temperature: 0.7, topP: 0.8, topK: 20), runtimeVerified: false)
    ]
    public static func entry(_ id: String) -> AnalysisCatalogEntry? { entries.first { $0.id == id } }
}

struct CatalogInstallReceipt: Codable {
    var model: CatalogModelIdentity
    var bytes: Int64
    var modified: Date
}
