import SwiftUI
import MeetingCore

extension AppModel {
    var defaultMeetingProfile: MeetingProfile? { profileCatalog?.profiles.first { $0.id == profileCatalog?.defaultID } }
    var profileDirty: Bool { guard let draft = profileDraft else { return false }; return draft != profileCatalog?.profiles.first { $0.id == draft.id } || definitions != draft.definitions || promptDrafts.contains { kind, text in text != definitions.first(where: { $0.kind == kind })?.current.text } }
    func loadProfile(_ id: UUID) {
        guard let p = profileCatalog?.profiles.first(where: { $0.id == id }) else { return }
        profileDraft = p; definitions = p.definitions; promptDrafts = [:]
    }
    @discardableResult func saveProfile() -> Bool {
        guard var catalog = profileCatalog, var draft = profileDraft, let index = catalog.profiles.firstIndex(where: { $0.id == draft.id }) else { return false }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines); draft.tags = MeetingProfile.cleanTags(draft.tags); draft.definitions = definitions
        for i in draft.definitions.indices {
            if let text = promptDrafts[draft.definitions[i].kind], text != draft.definitions[i].current.text { draft.definitions[i].revisions.append(.init(text: text)) }
        }
        if draft != catalog.profiles[index] { draft.revision = catalog.profiles[index].revision + 1 }
        catalog.profiles[index] = draft
        do { try MeetingProfileStore(root: persistence.root).save(catalog); profileCatalog = catalog; profileDraft = draft; definitions = draft.definitions; promptDrafts = [:]; error = nil; progress = "Profile saved · \(draft.name)"; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func createProfile(duplicate: Bool) {
        guard var catalog = profileCatalog else { return }
        var p = MeetingProfile(language: defaultMeetingProfile?.language ?? "English")
        if duplicate { guard let original = catalog.profiles.first(where: { $0.id == profileDraft?.id }) else { return }; p = original }
        p.id = UUID(); p.revision = 1
        let base = duplicate ? p.name + " copy" : "New profile"
        p.name = base; var suffix = 2
        while catalog.profiles.contains(where: { $0.name.lowercased() == p.name.lowercased() }) { p.name = "\(base) \(suffix)"; suffix += 1 }
        catalog.profiles.append(p)
        do { try MeetingProfileStore(root: persistence.root).save(catalog); profileCatalog = catalog; loadProfile(p.id) }
        catch { self.error = error.localizedDescription }
    }
    func renameProfile(_ name: String) {
        guard var catalog = profileCatalog, let i = catalog.profiles.firstIndex(where: { $0.id == profileDraft?.id }) else { return }
        catalog.profiles[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        catalog.profiles[i].revision += 1
        do {
            try MeetingProfileStore(root: persistence.root).save(catalog); profileCatalog = catalog
            profileDraft?.name = catalog.profiles[i].name; profileDraft?.revision = catalog.profiles[i].revision
            error = nil; progress = "Profile renamed"
        } catch { self.error = error.localizedDescription }
    }
    func deleteProfile() {
        guard var catalog = profileCatalog, let id = profileDraft?.id, id != catalog.defaultID, catalog.profiles.count > 1 else { return }
        catalog.profiles.removeAll { $0.id == id }
        do { try MeetingProfileStore(root: persistence.root).save(catalog); profileCatalog = catalog; loadProfile(catalog.defaultID) }
        catch { self.error = error.localizedDescription }
    }
    func makeDefaultProfile() {
        guard saveProfile(), var catalog = profileCatalog, let id = profileDraft?.id else { return }
        catalog.defaultID = id
        do { try MeetingProfileStore(root: persistence.root).save(catalog); profileCatalog = catalog }
        catch { self.error = error.localizedDescription }
    }
    func resolveProfile(for session: MeetingSession? = nil, override: UUID? = nil, useSaved: Bool = false) throws -> MeetingProfileSnapshot {
        guard let catalog = profileCatalog else { throw MeetingError.message("Meeting profiles could not be loaded. Repair meeting-profiles.json before starting new work.") }
        return try catalog.resolve(assigned: override, saved: session?.profileSnapshot, useSaved: useSaved)
    }
}

struct ProfileControls: View {
    @EnvironmentObject var model: AppModel
    @State private var pending: Action?
    @State private var showUnsaved = false
    @State private var showDelete = false
    @State private var showRename = false
    @State private var renamed = ""
    enum Action { case select(UUID), new, duplicate }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let catalog = model.profileCatalog, let draft = model.profileDraft {
                Picker("Editing profile", selection: Binding(get: { draft.id }, set: { request(.select($0)) })) {
                    ForEach(catalog.profiles) { p in Text(p.name + (p.id == catalog.defaultID ? " · Default" : "")).tag(p.id) }
                }
                HStack {
                    Button("New") { request(.new) }
                    Button("Duplicate") { request(.duplicate) }
                    Button("Rename") { renamed = draft.name; showRename = true }
                    Button("Delete", role: .destructive) { showDelete = true }.disabled(draft.id == catalog.defaultID || catalog.profiles.count == 1)
                    Spacer()
                    Button("Make Default", action: model.makeDefaultProfile).disabled(draft.id == catalog.defaultID)
                }
                Text("Default for quick starts: \(model.defaultMeetingProfile?.name ?? "Unavailable"). Editing a profile does not change the recording default.").font(.caption).foregroundStyle(.secondary)
            } else { Text("Profiles unavailable. Your existing files have been preserved.").foregroundStyle(.red) }
        }.padding(.horizontal)
        .alert("Rename profile", isPresented: $showRename) {
            TextField("Profile name", text: $renamed)
            Button("Save") { model.renameProfile(renamed) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Save changes to this profile?", isPresented: $showUnsaved, titleVisibility: .visible) {
            Button("Save") { if model.saveProfile() { performPending() } }
            Button("Discard changes", role: .destructive) { if let id = model.profileDraft?.id { model.loadProfile(id) }; performPending() }
            Button("Cancel", role: .cancel) { pending = nil }
        }
        .confirmationDialog("Delete this profile? Saved meetings and their snapshots will remain available.", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete profile", role: .destructive, action: model.deleteProfile)
            Button("Cancel", role: .cancel) {}
        }
    }
    private func request(_ action: Action) { pending = action; if model.profileDirty { showUnsaved = true } else { performPending() } }
    private func performPending() {
        guard let action = pending else { return }; pending = nil
        switch action { case .select(let id): model.loadProfile(id); case .new: model.createProfile(duplicate: false); case .duplicate: model.createProfile(duplicate: true) }
    }
}
