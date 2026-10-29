import CoreText
import Foundation
import WebKit

enum DocumentFontResources {
    static let scheme = "penned-font"
    private static let filenames = ["HachiMaruPop-Regular.ttf", "HachiMaruPop-SyntheticBold.ttf",
                                    "HachiMaruPop-SyntheticItalic.ttf", "HachiMaruPop-SyntheticBoldItalic.ttf"]

    private static let fontURLs: [String: URL] = Dictionary(uniqueKeysWithValues: filenames.compactMap { filename in
        let name = String(filename.dropLast(4))
        let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.main.url(forResource: name, withExtension: "ttf")
        return url.map { (filename, $0) }
    })
    private static let registration: Void = {
        for url in fontURLs.values {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func data(for filename: String) -> Data? {
        fontURLs[filename].flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
    }

    static func register() { _ = registration }
}

@MainActor
final class DocumentFontSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "document",
              url.path == "/" + url.lastPathComponent,
              let data = DocumentFontResources.data(for: url.lastPathComponent),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Type": "font/ttf", "Access-Control-Allow-Origin": "*",
                "Content-Length": String(data.count), "Cache-Control": "public, max-age=31536000, immutable"
              ]) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
