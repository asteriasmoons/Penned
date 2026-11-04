import SwiftUI

/// Gallery-only previews. Home-page thumbnail views remain unchanged.
struct TemplateGalleryThumbnail: View {
    let document: DocumentRecord

    var body: some View {
        LibraryDocumentPreview(document: document, fixedAspectRatio: 0.9,
                               showsStar: false, cornerRadius: 8)
            .allowsHitTesting(false)
            .accessibilityLabel("Preview of \(document.title)")
    }
}

/// Read-only, vertically scrollable preview. The source document is never edited.
struct TemplateFullPreview: View {
    let title: String
    let document: DocumentRecord
    let useTemplate: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                GalleryDocumentPreview(document: document)
                    .frame(maxWidth: 560, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
                    .padding(VellixSpacing.lg)
            }
            .background(VellixSurface.appBackground)

            Button(action: useTemplate) {
                Text("Use Template")
                    .font(.system(.headline, design: .rounded).weight(.black))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(PennedSheetStyle.accent)
            .padding(VellixSpacing.lg)
            .background(VellixSurface.paper)
        }
        .background(VellixBackground())
        .pennedSheet(title: title, close: close)
    }
}
