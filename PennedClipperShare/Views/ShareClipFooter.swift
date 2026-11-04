import SwiftUI

/// Primary save action and completion feedback for the Share Extension.
struct ShareClipFooter: View {
    let canSave: Bool
    let isSaving: Bool
    let isSaved: Bool
    let onSave: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if isSaved {
                Label("Clip queued for Penned", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)

                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            } else {
                Button(action: onSave) {
                    HStack(spacing: 10) {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text(isSaving ? "Saving Clip…" : "Save Clip")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isSaving)
                .accessibilityLabel(isSaving ? "Saving clip" : "Save clip to Penned")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}
