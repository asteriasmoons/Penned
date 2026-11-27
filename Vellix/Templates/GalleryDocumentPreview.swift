import SwiftUI

// The saved document is available immediately, even before a first WebKit snapshot exists.
struct GalleryDocumentPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    let document: DocumentRecord
    private var appearance: DocumentAppearance { document.appearance.resolved(for: colorScheme) }
    private var savedContent: DocumentPreviewContent { environment.documentPreviews.content(for: document) }
    private var blockSpacing: CGFloat {
        #if os(iOS)
        10
        #else
        18
        #endif
    }

    private var sheets: [[[String: Any]]] {
        var result: [[[String: Any]]] = [[]]
        for node in TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)["content"] as? [[String: Any]] ?? [] {
            if node["type"] as? String == "pageBreak" { result.append([]) }
            else { result[result.count - 1].append(node) }
        }
        return result
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LibrarySnapshotSurface(style: appearance.editorBackground,
                photo: document.isThemed ? CardImageLoader.image(path: document.appearance.editorBackground.imagePath, store: environment.attachmentStore) : nil)
            if let theme = document.appearance.editorBackground.patternTheme(for: document.appearance.themeID) {
                ThemePatternOverlay(theme: theme)
                    .opacity(document.appearance.editorBackground.effect == .faded ? 0.35 : 1)
            }
            VStack(spacing: 14) {
                ForEach(Array(sheets.enumerated()), id: \.offset) { index, nodes in
                    VStack(alignment: .leading, spacing: 18) {
                        if index == 0 {
                            LibrarySnapshotHeader(document: document,
                                cover: CardImageLoader.image(path: document.cover, store: environment.attachmentStore),
                                appearance: appearance, titleLineLimit: nil)
                            if let (collection, entry) = savedContent.entryContext {
                                CollectionFieldsSnapshotPreview(snapshot: collection, entry: entry, appearance: appearance)
                            }
                        }
                        ImmediatePreviewBlocks(nodes: nodes, appearance: appearance, depth: 0,
                            collections: savedContent.collections, referencedDocuments: savedContent.children, spacing: blockSpacing, maximumBlocks: .max)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
                    .background {
                        if document.isThemed {
                            LibrarySnapshotSurface(style: appearance.innerPageBackground,
                                photo: CardImageLoader.image(path: document.appearance.innerPageBackground.imagePath, store: environment.attachmentStore))
                        } else {
                            Color(vellixHex: appearance.editorBackground.colorHex)
                                .overlay { if appearance.presentationColorScheme == .dark { Color.black.opacity(0.30) } }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                }
            }
            .padding(document.isThemed ? 8 : 0)
        }
        .foregroundStyle(Color(vellixHex: appearance.textColorHex))
        .environment(\.colorScheme, appearance.presentationColorScheme)
        .allowsHitTesting(false)
        .clipped()
    }
}

struct GalleryDocumentBodyPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    let document: DocumentRecord
    var body: some View {
        let saved = environment.documentPreviews.content(for: document)
        let appearance = document.appearance.resolved(for: colorScheme)
        let nodes = TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)["content"] as? [[String: Any]] ?? []
        ImmediatePreviewBlocks(nodes: nodes, appearance: appearance, depth: 0,
            collections: saved.collections, referencedDocuments: saved.children, spacing: 8, maximumBlocks: .max)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .foregroundStyle(Color(vellixHex: appearance.textColorHex))
            .environment(\.colorScheme, appearance.presentationColorScheme)
            .allowsHitTesting(false)
    }
}
