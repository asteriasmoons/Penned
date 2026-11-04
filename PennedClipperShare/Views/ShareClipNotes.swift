import SwiftUI

/// Optional personal notes saved with the clipped article.
struct ShareClipNotes: View {
    @Binding var notes: String

    private let characterLimit = 50_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Personal Notes")
                .font(.headline)

            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Add your thoughts about this article…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $notes)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Personal notes")
            }
            .padding(8)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Text("Optional")
                Spacer()
                Text("\(notes.count.formatted()) / \(characterLimit.formatted())")
                    .foregroundStyle(notes.count > characterLimit ? Color.red : Color.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: notes) { _, newValue in
            if newValue.count > characterLimit {
                notes = String(newValue.prefix(characterLimit))
            }
        }
    }
}
