// Mac calendar row adapter using the existing nested-page preview renderer.
import SwiftUI

struct CalendarDocumentPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    let document: DocumentRecord
    var showsExcerpt = false
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                NestedPageThumbnail(json: document.tipTapJSON, title: document.title, appearance: document.appearance,
                    size: CGSize(width: 37, height: 48), cover: document.cover, attachmentStore: environment.attachmentStore)
                    .equatable()
                    .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(document.appearance.fontStyle.font(.subheadline, weight: .bold))
                        .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    if showsExcerpt, !document.plainText.isEmpty {
                        Text(document.previewText).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(document.title)")
        .accessibilityIdentifier("calendar-document-\(document.id)")
    }
}

