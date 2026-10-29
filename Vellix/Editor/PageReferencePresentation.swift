import SwiftUI
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
enum PageReferencePresentation {
    static func bridgeObject(_ document: DocumentRecord, attachmentStore: AttachmentStore? = nil, colorScheme: ColorScheme = .dark,
                             containingFontStyle: DocumentFontStyle? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "documentID": document.id,
            "title": document.title,
            "previewText": document.previewText == "No content yet" ? "Empty page" : document.previewText
        ]
        if let style = document.cardStyle {
            let remote = style.backdrop == .photo ? style.remotePhoto : nil
            result["cardImage"] = png(PageCardView(document: document, style: style,
                photo: CardImageLoader.image(path: style.imagePath, store: attachmentStore), includeBackdrop: remote == nil,
                attachmentStore: attachmentStore, containingFontStyle: containingFontStyle).environment(\.colorScheme, colorScheme))
            result["cardWidth"] = style.size.size.width
            result["cardHeight"] = style.size.size.height
            result["cardFullWidth"] = style.size.fillsDocumentWidth
            if let remote, let url = remote.validImageURL {
                result["cardBackgroundURL"] = url.absoluteString
                result["photographer"] = remote.photographer
                result["photographerURL"] = remote.photographerURL
                result["sourceURL"] = remote.sourceURL
            }
        } else {
            result["thumbnail"] = png(NestedPageThumbnail(json: document.tipTapJSON, title: document.title, appearance: document.appearance.resolved(for: colorScheme),
                cover: document.cover, attachmentStore: attachmentStore).environment(\.colorScheme, colorScheme))
        }
        return result
    }

    private static func png<V: View>(_ view: V) -> String {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        #if os(iOS)
        let data = renderer.uiImage?.pngData()
        #elseif os(macOS)
        let data = renderer.nsImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        #else
        let data: Data? = nil
        #endif
        return data.map { "data:image/png;base64,\($0.base64EncodedString())" } ?? ""
    }
}
