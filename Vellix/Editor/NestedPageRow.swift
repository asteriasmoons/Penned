import SwiftUI

struct NestedPageRow: View {
    @EnvironmentObject private var environment: AppEnvironment
    var document: DocumentRecord
    var appearance: DocumentAppearance
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                NestedPageThumbnail(json: document.tipTapJSON, title: document.title, appearance: document.appearance,
                    cover: document.cover, attachmentStore: environment.attachmentStore)
                    .equatable()
                    .shadow(color: .black.opacity(0.48), radius: 6, x: 0, y: 4)
                    .shadow(color: .black.opacity(0.30), radius: 1, x: 0, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title)
                        .font(.system(size: 18, weight: .black, design: appearance.fontStyle.design))
                        .lineLimit(1)
                    Text(document.previewText == "No content yet" ? "Empty page" : document.previewText)
                        .font(.system(size: 14, design: appearance.fontStyle.design))
                        .foregroundStyle(Color(vellixHex: appearance.textColorHex).opacity(0.48))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Color(vellixHex: appearance.textColorHex))
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityLabel("Open \(document.title)")
        .accessibilityIdentifier("nested-page-\(document.id)")
    }
}
