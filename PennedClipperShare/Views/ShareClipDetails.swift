import SwiftUI

/// Editable title and source details for a shared webpage.
struct ShareClipDetails: View {
    @Binding var draft: ShareClipDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Article Details")
                .font(.headline)

            VStack(alignment: .leading, spacing: 7) {
                Text("Title")
                    .font(.subheadline.weight(.medium))
                TextField("Article title", text: $draft.title, axis: .vertical)
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .accessibilityLabel("Article title")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Author")
                    .font(.subheadline.weight(.medium))
                TextField("Author name", text: $draft.author)
                    .textContentType(.name)
                    .accessibilityLabel("Article author")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Website")
                    .font(.subheadline.weight(.medium))
                TextField("Website name", text: $draft.siteName)
                    .accessibilityLabel("Website name")
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
