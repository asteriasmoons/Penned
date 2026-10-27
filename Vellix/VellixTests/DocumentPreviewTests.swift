import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Vellix

@MainActor
struct DocumentPreviewTests {
    @Test func editsAndOwnThemeInvalidateTheSnapshot() {
        let original = DocumentRecord(title: "Notes")
        let key = DocumentPreviewCache.cacheKey(original, children: [])
        var edited = original
        edited.title = "Renamed"
        #expect(key != DocumentPreviewCache.cacheKey(edited, children: []))
        edited = original
        edited.tipTapJSON = TipTapContentAnalyzer.starterDocument(title: "Notes", lines: ["New content"])
        #expect(key != DocumentPreviewCache.cacheKey(edited, children: []))
        edited = original
        edited.appearanceJSON = DocumentAppearance.defaultForTheme(.neonCode).encodedJSON()
        #expect(key != DocumentPreviewCache.cacheKey(edited, children: []))
        edited = original
        edited.cover = "covers/new.png"
        #expect(key != DocumentPreviewCache.cacheKey(edited, children: []))
    }

    @Test func openingOrStarringDoesNotRerenderTheDocument() {
        let original = DocumentRecord(title: "Notes")
        var opened = original
        opened.lastOpenedAt = .now
        opened.isFavorite = true
        #expect(DocumentPreviewCache.cacheKey(original, children: []) == DocumentPreviewCache.cacheKey(opened, children: []))
    }

    @Test func childEditsInvalidateTheParentButChildOrderDoesNot() {
        let parent = DocumentRecord(title: "Parent")
        let child = DocumentRecord(title: "Child", parentDocumentID: parent.id)
        let second = DocumentRecord(title: "Second", parentDocumentID: parent.id)
        let key = DocumentPreviewCache.cacheKey(parent, children: [child, second])
        #expect(key == DocumentPreviewCache.cacheKey(parent, children: [second, child]))
        var changed = child
        changed.tipTapJSON = TipTapContentAnalyzer.starterDocument(title: "Child", lines: ["Changed"])
        #expect(key != DocumentPreviewCache.cacheKey(parent, children: [changed, second]))
    }

    @Test func pageBreaksSplitNativeSurfacesWithoutCoveringTheGap() {
        let result = PreviewPageBreak.segments([PreviewPageBreak(y: 50, height: 14)], bodyY: 80, totalHeight: 400)
        #expect(result == [PreviewPageBreak(y: 0, height: 130), PreviewPageBreak(y: 144, height: 256)])
    }

    @Test func pageBreaksOutsideThePreviewDoNotCreateExtraSurfaces() {
        let result = PreviewPageBreak.segments([PreviewPageBreak(y: 900, height: 14)], bodyY: 80, totalHeight: 400)
        #expect(result == [PreviewPageBreak(y: 0, height: 400)])
        #expect(PreviewPageBreak.segments([], bodyY: 80, totalHeight: 400) == result)
    }

    @Test func toggleCacheRevisionRecognizesNestedNodesButNotPlainText() {
        let paragraph = TipTapContentAnalyzer.starterDocument(title: "", lines: ["toggleItem"])
        #expect(!TipTapContentAnalyzer.hasToggles(in: paragraph))
        let nested = #"{"type":"doc","content":[{"type":"blockquote","content":[{"type":"toggleItem","content":[{"type":"paragraph"}]}]}]}"#
        #expect(TipTapContentAnalyzer.hasToggles(in: nested))
    }

    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func togglePreviewKeepsTheAssetSilhouette(scheme: ColorScheme, open: Bool) async throws {
        let database = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: database)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AttachmentStore(rootURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let collections = CollectionRepository(database: database, documents: documents)
        let assets = try #require(ProcessInfo.processInfo.environment["PENNED_EDITOR_ASSET_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "VellixEditor", withExtension: "bundle"))
        let html = try TipTapEditorAssetCache.document(in: assets)
        var renderer: WKWebView?
        var loads = 0
        let previews = DocumentPreviewCache(documents: documents, attachments: store, collections: collections,
            loadEditor: { webView, _ in
                loads += 1
                renderer = webView
                webView.loadHTMLString(html.html, baseURL: assets)
            })
        let json = """
        {"type":"doc","content":[{"type":"toggleItem","attrs":{"open":\(open)},"content":[
        {"type":"paragraph","content":[{"type":"text","text":"Here is my toggle block"}]},
        {"type":"paragraph","content":[{"type":"text","text":"Here is some text inside of my toggle"}]}]}]}
        """
        let document = try documents.create(DocumentDraft(title: "Untitled", tipTapJSON: json))
        let saved = try documents.requireDocument(id: document.id)
        defer { previews.remove(documentIDs: [document.id]) }
        _ = try #require(await previews.image(for: document, colorScheme: scheme == .light ? .dark : .light))
        let image = try #require(await previews.image(for: document, colorScheme: scheme))
        let name = "\(scheme == .light ? "light" : "dark")-\(open ? "open" : "closed")"
        try DocumentPreviewImageFile.write(image, to: FileManager.default.temporaryDirectory
            .appendingPathComponent("penned-toggle-preview-\(name).png"))
        let webView = try #require(renderer)
        let bounds = try #require(try await webView.evaluateJavaScript("""
            (() => {
                const button = document.querySelector('.vellix-toggle-button');
                const rect = button.getBoundingClientRect();
                return {x: rect.x + (rect.width - 20) / 2, y: rect.y + (rect.height - 20) / 2};
            })()
            """) as? [String: Double])
        let headerRenderer = ImageRenderer(content: LibrarySnapshotHeader(document: document, cover: nil,
            appearance: document.appearance.resolved(for: scheme)).frame(width: 320).environment(\.colorScheme, scheme))
        headerRenderer.scale = 2
        let header = try #require(headerRenderer.cgImage)
        let x = try #require(bounds["x"]), y = try #require(bounds["y"])
        // Use the actual composited preview, not a second, differently clipped PDF export.
        let glyph = try #require(image.cropping(to: CGRect(x: (20 + x) * 2 - 2,
            y: 76 + Double(header.height) + y * 2, width: 42, height: 40)))
        let pixels = try #require(CGContext(data: nil, width: 42, height: 40, bitsPerComponent: 8,
            bytesPerRow: 168, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.draw(glyph, in: CGRect(x: 0, y: 0, width: 42, height: 40))
        let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        func differenceFromPaper(_ index: Int) -> Int {
            (0..<3).map { abs(Int(bytes[index * 4 + $0]) - Int(bytes[$0])) }.max() ?? 0
        }
        let painted = (0..<(42 * 40)).filter { differenceFromPaper($0) > 20 }.count
        #expect(painted > 100, "The custom chevron must be visible: \(name)")
        for (x, y) in [(2, 0), (41, 0), (2, 39), (41, 39)] {
            #expect(differenceFromPaper(y * 42 + x) < 4, "No square mask background at \(x),\(y): \(name)")
        }
        #expect(loads == 1, "Preview theme changes must reuse the existing renderer")
        #expect(try documents.requireDocument(id: document.id) == saved)
    }
}
