import Foundation
import UIKit
import UniformTypeIdentifiers

/// Content supplied to Penned through the iOS Share Sheet.
struct SharedClipContent {
    let url: URL
    let sharedText: String?
}

/// Reads URL and text attachments without relying on Safari-specific page scripts.
struct SharedContentReceiver {
    func receive(from items: [NSExtensionItem]) async throws -> SharedClipContent {
        let providers = items.flatMap { $0.attachments ?? [] }
        var sharedText: String?

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let value = try? await loadItem(from: provider, type: UTType.url.identifier),
               let url = url(from: value),
               ClipperShared.webURL(url.absoluteString) != nil {
                return SharedClipContent(url: url, sharedText: sharedText)
            }
        }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            guard let value = try? await loadItem(from: provider, type: UTType.plainText.identifier),
                  let text = text(from: value)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }

            if let url = firstWebURL(in: text) {
                return SharedClipContent(url: url, sharedText: text)
            }
            if sharedText == nil { sharedText = text }
        }

        for item in items {
            if let text = item.attributedContentText?.string,
               let url = firstWebURL(in: text) {
                return SharedClipContent(url: url, sharedText: text)
            }
        }

        if providers.isEmpty && items.isEmpty { throw ShareClipError.noSharedContent }
        throw ShareClipError.unsupportedContent
    }

    private func loadItem(from provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: item) }
            }
        }
    }

    private func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    private func text(from item: NSSecureCoding?) -> String? {
        if let string = item as? String { return string }
        if let attributed = item as? NSAttributedString { return attributed.string }
        return nil
    }

    private func firstWebURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector?.matches(in: text, range: range)
            .compactMap(\.url)
            .first { ClipperShared.webURL($0.absoluteString) != nil }
    }
}
