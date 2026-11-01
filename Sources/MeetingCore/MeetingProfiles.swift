import Foundation

public enum MeetingProfileTemplate: String, Codable, CaseIterable, Sendable {
    case general, technicalReview, clientCall, personalJournal
    public var name: String { switch self { case .general: return "General"; case .technicalReview: return "Technical review"; case .clientCall: return "Client call"; case .personalJournal: return "Personal journal" } }
    public var tags: [String] { switch self { case .general: return []; case .technicalReview: return ["technical-review"]; case .clientCall: return ["client-call"]; case .personalJournal: return ["personal-journal"] } }
    public func prompt(_ kind: AnalysisKind) -> String {
        let focus: String
        switch self {
        case .general: return DefaultPrompts.text(for: kind)
        case .technicalReview: focus = "Prioritize explicitly discussed technical requirements, architectural tradeoffs, risks, and dependencies relevant to this analysis type."
        case .clientCall: focus = "Prioritize the client's explicitly stated needs, requests, agreed outcomes, and commitments relevant to this analysis type. Do not infer who represents the client from audio source labels."
        case .personalJournal: focus = "Prioritize stated personal reflections, priorities, and concrete commitments relevant to this analysis type. Do not turn aspirations or reflections into commitments or invent advice."
        }
        return DefaultPrompts.text(for: kind) + "\n\n" + focus
    }
}
public struct MeetingProfile: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var revision = 1
    public var template: MeetingProfileTemplate
    public var language: String
    public var tags: [String]
    public var definitions: [AnalysisDefinition]
    public init(template: MeetingProfileTemplate = .general, language: String = "English") {
        self.template = template; self.language = language; name = template.name; tags = template.tags
        definitions = AnalysisKind.allCases.map { kind in
            var d = AnalysisDefinition(kind: kind); d.revisions = [.init(text: template.prompt(kind))]
            if template == .personalJournal { d.enabled = [.summary, .keyPoints, .actionItems].contains(kind) }
            return d
        }
    }
    public var snapshot: MeetingProfileSnapshot { .init(id: id, name: name, revision: revision, language: language, tags: tags, definitions: definitions.map { d in var copy = d; copy.revisions = [d.current]; return copy }) }
    public static func cleanTags(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            var tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.hasPrefix("#") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            return !tag.isEmpty && seen.insert(tag.lowercased()).inserted ? tag : nil
        }
    }
}
public struct MeetingProfileSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var revision: Int
    public var language: String
    public var tags: [String]
    public var definitions: [AnalysisDefinition]
    public func configuring(_ model: AnalysisSettings) -> AnalysisSettings { var result = model; result.language = language; return result }
}
public struct MeetingProfileCatalog: Codable, Sendable {
    public var profiles: [MeetingProfile]
    public var defaultID: UUID
    public func resolve(assigned: UUID? = nil, saved: MeetingProfileSnapshot? = nil, useSaved: Bool = false) throws -> MeetingProfileSnapshot {
        if useSaved, let saved { return saved }
        let id = assigned ?? saved?.id ?? defaultID
        guard let profile = profiles.first(where: { $0.id == id }) else { throw MeetingError.message("This meeting's profile was deleted. Choose another profile or use its saved profile settings.") }
        return profile.snapshot
    }
}
public final class MeetingProfileStore {
    public let url: URL
    public init(root: URL) { url = root.appendingPathComponent("meeting-profiles.json") }
    public func loadOrMigrate(settings: AppSettings, definitions: [AnalysisDefinition]) throws -> MeetingProfileCatalog {
        if FileManager.default.fileExists(atPath: url.path) {
            do { let catalog = try meetingDecoder.decode(MeetingProfileCatalog.self, from: Data(contentsOf: url)); try validate(catalog); return catalog }
            catch { throw MeetingError.message("Cannot load meeting-profiles.json. Your profiles were preserved; repair or restore this file. \(error.localizedDescription)") }
        }
        var general = MeetingProfile(language: settings.analysis.language); general.definitions = definitions
        let catalog = MeetingProfileCatalog(profiles: [general] + MeetingProfileTemplate.allCases.filter { $0 != .general }.map { MeetingProfile(template: $0, language: settings.analysis.language) }, defaultID: general.id)
        try save(catalog); return catalog
    }
    public func save(_ catalog: MeetingProfileCatalog) throws {
        try validate(catalog)
        try meetingEncoder.encode(catalog).write(to: url, options: .atomic)
    }
    private func validate(_ catalog: MeetingProfileCatalog) throws {
        guard !catalog.profiles.isEmpty, catalog.profiles.contains(where: { $0.id == catalog.defaultID }), Set(catalog.profiles.map(\.id)).count == catalog.profiles.count else { throw MeetingError.message("A valid default profile and unique profile IDs are required.") }
        var names = Set<String>()
        for p in catalog.profiles {
            let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("\n"), names.insert(name.lowercased()).inserted, p.revision > 0,
                  ["English", "French", "Spanish"].contains(p.language), Set(p.definitions.map(\.kind)) == Set(AnalysisKind.allCases), p.definitions.count == AnalysisKind.allCases.count,
                  p.definitions.allSatisfy({ !$0.revisions.isEmpty && $0.revisions.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }) else { throw MeetingError.message("Profiles require unique nonempty names, a supported language, and valid prompts for all five analysis types.") }
        }
    }
}
