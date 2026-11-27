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
                             containingFontStyle: DocumentFontStyle? = nil, previews: DocumentPreviewCache? = nil,
                             bookDescriptionDisplayWidth: CGFloat? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "documentID": document.id,
            "title": document.title,
            "previewText": previewText(document, previews: previews)
        ]
        if let style = document.cardStyle {
            result["isBook"] = style.isBook
            let remote = style.backdrop == .photo ? style.remotePhoto : nil
            result["cardImage"] = png(PageCardView(document: document, style: style,
                photo: CardImageLoader.image(path: style.imagePath, store: attachmentStore), includeBackdrop: remote == nil,
                attachmentStore: attachmentStore, containingFontStyle: containingFontStyle, previews: previews,
                bookDescriptionDisplayWidth: bookDescriptionDisplayWidth).environment(\.colorScheme, colorScheme),
                scale: style.isBook ? 3 * min(2, max(1, (bookDescriptionDisplayWidth ?? style.renderSize.width) / style.renderSize.width)) : 3)
            result["cardWidth"] = style.renderSize.width
            result["cardHeight"] = style.renderSize.height
            result["cardFullWidth"] = style.renderFillsDocumentWidth
            if let remote, let url = remote.validImageURL {
                result["cardBackgroundURL"] = url.absoluteString
                result["photographer"] = remote.photographer
                result["photographerURL"] = remote.photographerURL
                result["sourceURL"] = remote.sourceURL
            }
        } else {
            result["thumbnail"] = png(NestedPageThumbnail(json: document.tipTapJSON, title: document.title, appearance: document.appearance.resolved(for: colorScheme),
                cover: document.cover, attachmentStore: attachmentStore, document: document, previews: previews).environment(\.colorScheme, colorScheme))
        }
        return result
    }

    static func bookDescriptionUpdate(_ payload: [String: Any], records: [DocumentRecord],
                                      attachmentStore: AttachmentStore?, colorScheme: ColorScheme,
                                      containingFontStyle: DocumentFontStyle?, previews: DocumentPreviewCache?) -> TipTapEditorCommand? {
        guard let id = payload["documentID"] as? String,
              let token = payload["token"] as? String, token.count <= 80,
              let width = payload["width"] as? NSNumber, width.doubleValue.isFinite,
              width.doubleValue > 196, width.doubleValue <= 2048,
              let record = records.first(where: { $0.id == id }), record.cardStyle?.isBook == true else { return nil }
        let result = bridgeObject(record, attachmentStore: attachmentStore, colorScheme: colorScheme,
            containingFontStyle: containingFontStyle, previews: previews, bookDescriptionDisplayWidth: CGFloat(width.doubleValue))
        guard let image = result["cardImage"] as? String, !image.isEmpty else { return nil }
        return TipTapEditorCommand("setBookDescriptionImage", args: ["documentID": id, "token": token, "image": image])
    }

    static func previewText(_ document: DocumentRecord, previews: DocumentPreviewCache?) -> String {
        if let text = document.previewText.trimmedNonEmpty, text != "No content yet" { return text }
        let ids = TipTapContentAnalyzer.pageReferenceIDs(in: document.tipTapJSON)
        if !ids.isEmpty {
            let titles = previews?.content(for: document).children.filter { ids.contains($0.id) }.map(\.title) ?? []
            return titles.isEmpty ? "\(ids.count) nested \(ids.count == 1 ? "page" : "pages")" : titles.joined(separator: ", ")
        }
        if !TipTapContentAnalyzer.collectionIDs(in: document.tipTapJSON).isEmpty { return "Collection" }
        if !EditorAttachment.paths(in: document.tipTapJSON).isEmpty { return "Attachments" }
        return "Empty page"
    }

    private static func png<V: View>(_ view: V, scale: CGFloat = 3) -> String {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
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
