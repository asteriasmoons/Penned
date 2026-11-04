import SwiftUI

/// Read-only source information shown alongside the editable article details.
struct ShareClipMetadata: View {
    let sourceURL: String
    let thumbnailURL: String?

    private var sourceHost: String {
        URL(string: sourceURL)?.host ?? "Unknown website"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text(sourceHost)
                        .font(.subheadline.weight(.medium))
                    Text(sourceURL.isEmpty ? "No webpage URL available" : sourceURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }

            if let thumbnailURL,
               let url = URL(string: thumbnailURL),
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .overlay { ProgressView() }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Article thumbnail")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
