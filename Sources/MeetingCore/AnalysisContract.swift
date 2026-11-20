import Foundation

/// The same field definitions drive the provider schema, plain-JSON instructions,
/// and strict response validation for all three provider modes.
public struct AnalysisContract {
    let kind: AnalysisKind
    let changes: Bool

    public init(kind: AnalysisKind, changes: Bool = false) {
        self.kind = kind
        self.changes = changes
    }

    enum Operation: String { case items, add, revise, resolve, withdraw }
    private var operations: [Operation] { changes ? [.add, .revise, .resolve, .withdraw] : [.items] }
    private func fields(_ op: Operation) -> [String] {
        var keys = ["evidenceSegmentIDs"]
        if op != .add && op != .items { keys.append("id") }
        if op != .resolve && op != .withdraw {
            keys.append("text")
            if kind == .actionItems { keys += ["owner", "dueDateText"] }
        }
        return keys
    }

    public var instructions: String {
        let shape = operations.map { op in
            let fields = fields(op).map { key -> String in
                switch key {
                case "evidenceSegmentIDs": return "\"\(key)\":[\"segment-id\"]"
                case "owner", "dueDateText": return "\"\(key)\":null"
                case "id": return "\"id\":1"
                default: return "\"text\":\"finding\""
                }
            }.joined(separator: ",")
            return "\"\(op.rawValue)\":[{\(fields)}]"
        }.joined(separator: ",")
        let rules = changes
            ? "Return changes only. Omission keeps a finding. Add new findings; revise by existing numeric id with complete replacement fields and supporting references; resolve answered questions and withdraw cancelled or superseded findings by id. Cite this transcript part for each change."
            : "Return supported findings, citing supplied segment IDs."
        let detail = kind == .actionItems ? " Owner and dueDateText are strings when explicitly stated, otherwise null." : (kind == .summary ? " Each item is one summary paragraph." : "")
        return "\(rules)\(detail) Return only JSON shaped like {\(shape)}. All shown keys are required. Use empty arrays for no findings or changes."
    }

    func schema(evidence: Set<String>) -> [String: Any] {
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
        }
        var reference: [String: Any] = ["type": "string"]
        if !evidence.isEmpty { reference["enum"] = evidence.sorted() }
        let types: [String: Any] = [
            "text": ["type": "string", "minLength": 1], "id": ["type": "integer", "minimum": 1],
            "evidenceSegmentIDs": ["type": "array", "minItems": 1, "items": reference],
            "owner": ["type": ["string", "null"]], "dueDateText": ["type": ["string", "null"]]
        ]
        var arrays: [String: Any] = [:]
        for op in operations {
            let keys = Set(fields(op))
            arrays[op.rawValue] = ["type": "array", "items": object(types.filter { keys.contains($0.key) })]
        }
        return object(arrays)
    }

    func applying(_ output: String, to prior: FindingLedger, current: Set<String>, allowed: Set<String>) throws -> FindingLedger {
        func invalid(_ reason: String) -> MeetingError { .message(reason) }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              Set(root.keys) == Set(operations.map(\.rawValue)) else { throw invalid("Return a JSON object with the required arrays.") }
        var ledger = prior, touched = Set<Int>()
        let existing = Set(prior.ids)
        for op in operations {
            guard let rows = root[op.rawValue] as? [[String: Any]] else { throw invalid("Each output array must contain objects.") }
            for row in rows {
                guard Set(row.keys) == Set(fields(op)), let evidence = row["evidenceSegmentIDs"] as? [String],
                      !current.isDisjoint(with: evidence), Set(evidence).isSubset(of: allowed) else {
                    throw invalid("Use exactly the required fields and cite supplied segment IDs, including this transcript part.")
                }
                var index: Int?
                if row["id"] != nil {
                    guard let number = row["id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          let id = row["id"] as? Int, existing.contains(id), touched.insert(id).inserted,
                          let position = ledger.ids.firstIndex(of: id) else { throw invalid("Each change must target a distinct active finding ID.") }
                    index = position
                }
                if let index, op == .resolve || op == .withdraw {
                    ledger.ids.remove(at: index); ledger.items.remove(at: index)
                    continue
                }
                guard let text = row["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalid("Each finding needs nonempty text.")
                }
                for field in ["owner", "dueDateText"] where row[field] != nil {
                    guard row[field] is String || row[field] is NSNull else { throw invalid("Owner and deadline must be strings or null.") }
                }
                let item = AnalysisItem(text: text, evidenceSegmentIDs: evidence, owner: row["owner"] as? String, dueDateText: row["dueDateText"] as? String)
                if let index { ledger.items[index] = item }
                else {
                    guard ledger.nextID < Int.max else { throw invalid("Finding ID limit reached.") }
                    ledger.ids.append(ledger.nextID); ledger.items.append(item); ledger.nextID += 1
                }
            }
        }
        return ledger
    }
}

struct FindingLedger {
    var ids: [Int] = []
    var items: [AnalysisItem] = []
    var nextID = 1

    func compactJSON() throws -> String {
        struct Entry: Encodable { let id: Int; let finding: AnalysisItem }
        let entries = zip(ids, items).map { Entry(id: $0, finding: $1) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(entries), as: UTF8.self)
    }
}
