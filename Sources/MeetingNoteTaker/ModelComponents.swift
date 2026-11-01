import SwiftUI

/// Shared presentation for transcription and analysis model selection.
struct ModelProviderCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let active: Bool
    let accessibilityTitle: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(title).font(.headline)
                    Spacer(minLength: 0)
                    if active { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).frame(height: 82)
                .background(selected ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel(accessibilityTitle)
            .accessibilityValue(selected ? "Selected" : "")
    }
}

struct ModelBadge: View {
    enum Kind { case active, inactive, recommended }
    let text: String
    var kind: Kind = .active
    private var color: Color {
        switch kind { case .active: return .green; case .inactive: return .secondary; case .recommended: return .accentColor }
    }
    private var icon: String {
        switch kind { case .active: return "checkmark.circle.fill"; case .inactive: return "circle.dashed"; case .recommended: return "sparkles" }
    }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text).lineLimit(1).truncationMode(.middle)
        }.font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.11), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct ModelRow<Actions: View>: View {
    let title: String
    let detail: String
    var recommended = false
    var sourceURL: URL? = nil
    var sourceLabel = "Source"
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.headline).lineLimit(2)
                    if recommended { ModelBadge(text: "Balanced", kind: .recommended) }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                if let sourceURL { Link(sourceLabel, destination: sourceURL).font(.caption).foregroundStyle(Color.accentColor) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            actions().buttonStyle(.bordered)
        }.padding(.horizontal, 16).padding(.vertical, 14)
    }
}

struct ModelRemoveButton: View {
    let name: String
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "trash").frame(width: 24, height: 24) }
            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(disabled)
            .help("Remove \(name)").accessibilityLabel("Remove \(name)")
    }
}
