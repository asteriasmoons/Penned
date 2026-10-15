import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

final class CollectionCoverSchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: () -> AttachmentStore?
    private let cache = NSCache<NSString, NSData>()
    init(store: @escaping () -> AttachmentStore?) {
        self.store = store
        super.init()
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let key = url.absoluteString as NSString
        var data = cache.object(forKey: key).map { $0 as Data }
        if data == nil {
            var image: CGImage?
            if let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
               !path.isEmpty, path == (path as NSString).lastPathComponent, path != ".", path != "..", let store = store(),
               let source = CGImageSourceCreateWithURL(store.fileURL(relativePath: path) as CFURL, nil) {
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary)
            } else if let raw = components.queryItems?.first(where: { $0.name == "theme" })?.value, let theme = DocumentThemeID(rawValue: raw) {
                image = NestedPageThemeCovers.image(for: theme)
            }
            if let image {
                let buffer = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                    if CGImageDestinationFinalize(destination) { data = buffer as Data }
                }
            }
            if let data { cache.setObject(data as NSData, forKey: key, cost: data.count) }
        }
        guard let data else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/jpeg", expectedContentLength: data.count, textEncodingName: nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
