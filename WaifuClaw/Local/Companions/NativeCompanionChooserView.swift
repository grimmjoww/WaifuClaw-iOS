import SwiftUI

/// Picker for a purely visual companion preference. It makes no product,
/// entitlement, model, capability, or permission claim.
struct NativeCompanionChooserView: View {
    @AppStorage(CompanionID.selectionStorageKey)
    private var storedCompanionID = CompanionID.defaultSelection.rawValue

    private var selectedCompanion: CompanionID {
        CompanionID.selected(from: storedCompanionID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Visual companion")
                .font(.headline)

            Text("Choose the sprite that appears beside your agent activity. This changes visuals only—not the agent model or its permissions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(CompanionCatalog.all) { companion in
                companionButton(for: companion)
            }
        }
        .onAppear(perform: normalizeStoredSelection)
        .accessibilityElement(children: .contain)
    }

    private func companionButton(for companion: CompanionDefinition) -> some View {
        let isSelected = companion.id == selectedCompanion
        return Button {
            storedCompanionID = companion.id.rawValue
        } label: {
            HStack(spacing: 12) {
                CompanionSpriteView(mood: .idle, companion: companion.id)
                    .frame(width: 82, height: 82)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(companion.name)
                        .font(.headline)
                        .foregroundStyle(companion.palette.label.color)
                    Text(companion.visualPersonality)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(companion.palette.label.color.opacity(0.82))
                    if isSelected {
                        Text("Selected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(companion.palette.accent.color)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(companion.palette.accent.color)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .background(companion.palette.surface.color.opacity(isSelected ? 0.88 : 0.58))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        companion.palette.accent.color.opacity(isSelected ? 0.9 : 0.35),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(companion.name), \(companion.visualPersonality)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Changes the visual companion only. It does not change the agent model or permissions.")
    }

    private func normalizeStoredSelection() {
        let normalized = selectedCompanion.rawValue
        if storedCompanionID != normalized {
            storedCompanionID = normalized
        }
    }
}
