import SwiftUI
import Combine
import WebKit
import ImageIO

@MainActor
final class DocumentPreviewCache: ObservableObject {
    private let documents: DocumentRepository
    private let attachments: AttachmentStore
    private let collections: CollectionRepository
    @Published private(set) var contentRevision = 0
    private var contents: [String: DocumentPreviewContent] = [:]
    private var observation: AnyCancellable?
    private let memory = NSCache<NSString, PreviewImageBox>()
    private var pending: [String: Task<CGImage?, Never>] = [:]
    private var tail: Task<Void, Never>?
    private let latestImages = NSCache<NSString, PreviewImageBox>()
    private let presentedImages = NSCache<NSString, PreviewImageBox>()
    private(set) var presentationEpoch = 0
    private var latestFiles: [String: URL] = [:]
    private let session = TipTapEditorSession()
    private lazy var renderer = TipTapEditorWebViewStore(session: session)
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VellixDocumentPreviewsStyles-v10-collections", isDirectory: true)

    init(documents: DocumentRepository, attachments: AttachmentStore, collections: CollectionRepository) {
        self.documents = documents
        self.attachments = attachments
        self.collections = collections
        session.attachmentStore = attachments
        session.attachmentResolver = { [weak documents] id, json in
            try documents?.editorAttachments(documentID: id, json: json, store: attachments) ?? []
        }
        session.preparesInteractivePresentation = false
        memory.totalCostLimit = 32 * 1024 * 1024
        latestImages.totalCostLimit = 16 * 1024 * 1024
        presentedImages.totalCostLimit = 24 * 1024 * 1024
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files.filter({ $0.pathExtension == "png" }).sorted(by: {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }) {
            // UUIDs are 36 characters; the rest of the name is a revision hash.
            latestFiles[String(url.lastPathComponent.prefix(36))] = url
        }
        observation = NotificationCenter.default.publisher(for: .pennedCollectionsChanged, object: collections.database)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshContents() }
    }

    func content(for document: DocumentRecord) -> DocumentPreviewContent {
        guard documents.spaceID == nil || documents.spaceID == document.spaceID else { return DocumentPreviewContent(document: document, children: [], collections: []) }
        if let cached = contents[document.id], cached.document.updatedAt >= document.updatedAt { return cached }
        guard let result = try? collections.previewContent(for: document, documents: documents) else {
            return contents[document.id] ?? DocumentPreviewContent(document: document, children: [], collections: [])
        }
        contents[document.id] = result
        return result
    }

    private func refreshContents() {
        var changed: [DocumentRecord] = []
        for id in Array(contents.keys) {
            guard let document = try? documents.requireDocument(id: id), !document.isTrashed,
                  let next = try? collections.previewContent(for: document, documents: documents) else {
                contents[id] = nil; latestImages.removeObject(forKey: id as NSString); latestFiles[id] = nil
                continue
            }
            if contents[id] != next {
                let visualChange = contents[id]?.cacheKey != next.cacheKey
                contents[id] = next
                if visualChange { latestImages.removeObject(forKey: id as NSString); changed.append(document) }
            }
        }
        if !changed.isEmpty { contentRevision += 1; prewarm(changed) }
    }

    func cachedImage(for document: DocumentRecord) -> CGImage? {
        let expected = content(for: document).cacheKey
        if latestFiles[document.id]?.deletingPathExtension().lastPathComponent == expected,
           let image = latestImages.object(forKey: document.id as NSString) { return image.image }
        let url = directory.appendingPathComponent(expected + ".png")
        guard let image = memory.object(forKey: expected as NSString)?.image ?? DocumentPreviewImageFile.read(url) else { return nil }
        remember(image, key: expected)
        latestFiles[document.id] = url
        latestImages.setObject(PreviewImageBox(image), forKey: document.id as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    func presentationImage(for document: DocumentRecord, fallback: () -> CGImage?) -> CGImage? {
        let key = content(for: document).cacheKey as NSString
        if let image = presentedImages.object(forKey: key) { return image.image }
        guard let image = cachedImage(for: document) ?? fallback() else { return nil }
        presentedImages.setObject(PreviewImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    func beginLibraryPresentation() {
        presentedImages.removeAllObjects()
        presentationEpoch += 1
    }

    func resetForSpaceChange() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll(); tail = nil; contents.removeAll()
        beginLibraryPresentation()
        contentRevision += 1
    }

    func remove(documentIDs: Set<String>) {
        for id in documentIDs {
            contents[id] = nil; latestFiles[id] = nil
            latestImages.removeObject(forKey: id as NSString)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where documentIDs.contains(String(file.lastPathComponent.prefix(36))) { try? FileManager.default.removeItem(at: file) }
        memory.removeAllObjects(); resetForSpaceChange()
    }

    func prewarm(_ records: [DocumentRecord]) {
        // Metadata is ready before Home draws; image rendering stays off its first-frame path.
        for record in records {
            guard documents.spaceID == nil || documents.spaceID == record.spaceID else { continue }
            _ = content(for: record)
            let cached = cachedImage(for: record)
            if cached == nil, record.appearance.displaysCover { _ = CardImageLoader.image(path: record.cover, store: attachments) }
        }
        Task { [weak self] in
            guard let self else { return }
            for record in records { _ = await image(for: record) }
        }
    }

    func image(for document: DocumentRecord) async -> CGImage? {
        guard documents.spaceID == nil || documents.spaceID == document.spaceID else { return nil }
        let content = content(for: document)
        let key = content.cacheKey
        if let cached = memory.object(forKey: key as NSString) { return cached.image }
        if let task = pending[key] { return await task.value }
        let url = directory.appendingPathComponent(key + ".png")
        if let image = DocumentPreviewImageFile.read(url) {
            remember(image, key: key)
            latestImages.setObject(PreviewImageBox(image), forKey: document.id as NSString, cost: image.bytesPerRow * image.height)
            latestFiles[document.id] = url
            return image
        }
        let prior = tail
        let task = Task { [weak self] () -> CGImage? in
            await prior?.value
            guard let self else { return nil }
            guard contents[document.id]?.cacheKey == key else { return nil }
            do {
                let image = try await render(content)
                guard contents[document.id]?.cacheKey == key else { return nil }
                remember(image, key: key)
                latestImages.setObject(PreviewImageBox(image), forKey: document.id as NSString, cost: image.bytesPerRow * image.height)
                latestFiles[document.id] = url
                try DocumentPreviewImageFile.write(image, to: url)
                // One persisted revision per document; these are disposable previews, not user data.
                let oldFiles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for old in oldFiles where old.lastPathComponent.hasPrefix(document.id + "-") && old != url {
                    try? FileManager.default.removeItem(at: old)
                }
                return image
            } catch {
                return nil
            }
        }
        pending[key] = task
        tail = Task { _ = await task.value }
        let image = await task.value
        pending[key] = nil
        return image
    }

    private func remember(_ image: CGImage, key: String) {
        memory.setObject(PreviewImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    static func cacheKey(_ document: DocumentRecord, children: [DocumentRecord], collections: [CollectionSnapshot] = []) -> String {
        DocumentPreviewContent.cacheKey(document, children: children, collections: collections)
    }

    private func render(_ content: DocumentPreviewContent) async throws -> CGImage {
        guard content.hasResolvedCollections else { throw PreviewError.renderUnavailable }
        let document = content.document
        let webView = renderer.webView
        webView.frame = CGRect(x: 0, y: 0, width: 320, height: 800)
        session.bridgeErrorMessage = nil
        session.setAppearance(document.appearance)
        session.setPageReferences(content.children)
        session.setCollections(content.payloads)
        session.load(documentID: document.id, canonicalJSON: document.tipTapJSON, force: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !session.isReady || session.isLoadingDocument {
            guard ContinuousClock.now < deadline else { throw PreviewError.renderUnavailable }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard session.bridgeErrorMessage == nil else { throw PreviewError.renderUnavailable }
        // Set metadata in the same renderer before measuring or capturing any collection atom.
        _ = try await webView.callAsyncJavaScript("return window.tiptapCommand('setCollections', {collections: collections});",
            arguments: ["collections": content.payloads], in: nil, contentWorld: .page)
        let nativeHosts = try await webView.callAsyncJavaScript("""
            return Array.from(document.querySelectorAll('[data-native-collection]')).map(host => ({
                blockID: host.dataset.nativeCollectionBlock, collectionID: host.dataset.nativeCollection,
                width: host.getBoundingClientRect().width
            }));
            """, arguments: [:], in: nil, contentWorld: .page) as? [[String: Any]] ?? []
        for host in nativeHosts {
            guard let id = host["collectionID"] as? String, let blockID = host["blockID"] as? String,
                  let snapshot = content.collections.first(where: { $0.record.id == id }),
                  let width = host["width"] as? NSNumber, width.doubleValue > 0 else { throw PreviewError.renderUnavailable }
            let native = ImageRenderer(content: CollectionSnapshotPreview(snapshot: snapshot, appearance: document.appearance, attachments: attachments)
                .frame(width: CGFloat(width.doubleValue)).environment(\.colorScheme, .dark))
            native.scale = 2
            guard let image = native.cgImage else { throw PreviewError.renderUnavailable }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { throw PreviewError.renderUnavailable }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw PreviewError.renderUnavailable }
            _ = try await webView.callAsyncJavaScript("""
                const host = Array.from(document.querySelectorAll('[data-native-collection-block]')).find(node => node.dataset.nativeCollectionBlock === blockID);
                if (!host) throw new Error('The preview collection moved.');
                const image = new Image(); image.src = source;
                image.style.cssText = 'display:block;width:100%;margin:0;border:0;max-width:none;';
                host.style.height = height + 'px'; host.replaceChildren(image);
                await image.decode();
                """, arguments: ["blockID": blockID, "source": "data:image/png;base64," + (png as Data).base64EncodedString(), "height": Double(image.height) / 2], in: nil, contentWorld: .page)
        }
        // Wait for the renderer's assets, not a guessed screenshot delay.
        let measurements = try await webView.callAsyncJavaScript(#"""
            window.tiptapCommand('setEditable', {editable: false});
            document.activeElement?.blur();
            await document.fonts.ready;
            const assets = getComputedStyle(document.documentElement);
            for (const callout of document.querySelectorAll('.vellix-callout')) {
                const icon = callout.querySelector('.vellix-callout-icon-image');
                if (!icon) continue;
                const name = callout.dataset.calloutIcon || 'sparkle';
                const source = assets.getPropertyValue('--vellix-asset-' + name)
                    || assets.getPropertyValue('--vellix-asset-sparkle');
                const match = source.match(/url\(["']?(.*?)["']?\)/);
                if (!match) continue;
                const glyph = new Image();
                glyph.src = match[1];
                await glyph.decode();
                const width = icon.getBoundingClientRect().width;
                const height = icon.getBoundingClientRect().height;
                if (width <= 0 || height <= 0) continue;
                const canvas = document.createElement('canvas');
                canvas.width = Math.max(1, Math.ceil(width * 3));
                canvas.height = Math.max(1, Math.ceil(height * 3));
                const context = canvas.getContext('2d');
                const scale = Math.min(canvas.width / glyph.naturalWidth, canvas.height / glyph.naturalHeight);
                const w = glyph.naturalWidth * scale, h = glyph.naturalHeight * scale;
                context.drawImage(glyph, (canvas.width - w) / 2, (canvas.height - h) / 2, w, h);
                context.globalCompositeOperation = 'source-in';
                context.fillStyle = callout.dataset.calloutColor || '#FFFFFF';
                context.globalAlpha = 1;
                context.fillRect(0, 0, canvas.width, canvas.height);
                const image = document.createElement('img');
                image.className = 'vellix-preview-callout-icon';
                image.src = canvas.toDataURL('image/png');
                image.style.cssText = 'position:absolute;inset:8px;object-fit:contain;margin:0;max-width:none;border:0;';
                image.style.width = width + 'px';
                image.style.height = height + 'px';
                icon.replaceWith(image);
                await image.decode();
            }
            await Promise.race([
                Promise.all(Array.from(document.images).map(image => image.decode().catch(() => {}))),
                new Promise(resolve => setTimeout(resolve, 4000))
            ]);
            // Measuring forces layout even when this read-only renderer is offscreen.
            const root = document.querySelector('.tiptap-editor, .ProseMirror');
            const bounds = root.getBoundingClientRect();
            const breaks = Array.from(root.children)
                .filter(node => node.matches('[data-vellix-page-break], [data-type="pageBreak"], [data-page-break]'))
                .map(node => { const rect = node.getBoundingClientRect(); return {y: rect.top - bounds.top, height: rect.height}; });
            return {height: Math.max(24, bounds.height), breaks};
            """#, arguments: [:], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
        let bodyHeight = min(CGFloat(570), max(24, CGFloat((measurements["height"] as? NSNumber)?.doubleValue ?? 24)))
        let pageBreaks = (measurements["breaks"] as? [[String: Any]] ?? []).compactMap { entry -> PreviewPageBreak? in
            guard let y = entry["y"] as? NSNumber, let height = entry["height"] as? NSNumber else { return nil }
            return PreviewPageBreak(y: CGFloat(y.doubleValue), height: CGFloat(height.doubleValue))
        }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: 320, height: bodyHeight)
        configuration.allowTransparentBackground = true
        let data = try await webView.pdf(configuration: configuration)
        guard let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1),
              let context = CGContext(data: nil, width: 640, height: Int(ceil(bodyHeight * 2)),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PreviewError.renderUnavailable }
        context.scaleBy(x: 2, y: 2)
        context.concatenate(page.getDrawingTransform(.mediaBox,
            rect: CGRect(x: 0, y: 0, width: 320, height: bodyHeight), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let body = context.makeImage() else { throw PreviewError.renderUnavailable }
        let headerRenderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 10) {
            LibrarySnapshotHeader(document: document, cover: CardImageLoader.image(path: document.cover, store: attachments))
            if let (collection, entry) = content.entryContext {
                CollectionFieldsSnapshotPreview(snapshot: collection, entry: entry, appearance: document.appearance)
            }
        }.frame(width: 320))
        headerRenderer.scale = 2
        guard let header = headerRenderer.cgImage else { throw PreviewError.renderUnavailable }
        let headerHeight = CGFloat(header.height) / 2
        let height = min(740, max(480, bodyHeight + headerHeight + 58 + (document.isThemed ? 16 : 0)))
        let pageView = LibrarySnapshotPage(document: document, headerImage: header, headerHeight: headerHeight,
            bodyImage: body, bodyHeight: bodyHeight, pageBreaks: pageBreaks,
            outerImage: CardImageLoader.image(path: document.appearance.editorBackground.imagePath, store: attachments),
            innerImage: CardImageLoader.image(path: document.appearance.innerPageBackground.imagePath, store: attachments))
            .frame(width: document.isThemed ? 376 : 360, height: height, alignment: .topLeading)
        let imageRenderer = ImageRenderer(content: pageView)
        imageRenderer.scale = 2
        guard let image = imageRenderer.cgImage else { throw PreviewError.renderUnavailable }
        return image
    }

    private enum PreviewError: Error { case renderUnavailable }
}

private final class PreviewImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private struct LibrarySnapshotPage: View {
    let document: DocumentRecord
    let headerImage: CGImage
    let headerHeight: CGFloat
    let bodyImage: CGImage
    let bodyHeight: CGFloat
    let pageBreaks: [PreviewPageBreak]
    let outerImage: CGImage?
    let innerImage: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                LibrarySnapshotSurface(
                    style: document.isThemed ? document.appearance.editorBackground : DocumentAppearance.plain.editorBackground,
                    photo: document.isThemed ? outerImage : nil)
                if let theme = document.appearance.editorBackground.patternTheme(for: document.appearance.themeID) {
                    ThemePatternOverlay(theme: theme)
                        .opacity(document.appearance.editorBackground.effect == .faded ? 0.35 : 1)
                }
                let inset: CGFloat = document.isThemed ? 8 : 0
                let height = geometry.size.height - inset * 2
                let segments = PreviewPageBreak.segments(pageBreaks, bodyY: 20 + headerHeight + 18, totalHeight: height)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Group {
                            if document.isThemed {
                                LibrarySnapshotSurface(style: document.appearance.innerPageBackground, photo: innerImage)
                            } else {
                                // Match the editor's plain sheets, including documents with legacy black backgrounds.
                                ZStack {
                                    LibrarySnapshotSurface(style: DocumentAppearance.plain.editorBackground, photo: nil)
                                    Color.black.opacity(0.30)
                                }
                            }
                        }
                            .frame(width: 360, height: segment.height)
                            .clipShape(RoundedRectangle(cornerRadius: pageBreaks.isEmpty ? 15 : 22))
                            .overlay {
                                RoundedRectangle(cornerRadius: pageBreaks.isEmpty ? 15 : 22)
                                    .stroke(.white.opacity(pageBreaks.isEmpty ? 0 : 0.10), lineWidth: 1)
                            }
                            .offset(y: segment.y)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        Image(decorative: headerImage, scale: 2).resizable().frame(width: 320, height: headerHeight)
                        Image(decorative: bodyImage, scale: 2).resizable().frame(width: 320, height: bodyHeight)
                    }
                    .padding(20)
                    .frame(width: 360, height: height, alignment: .topLeading)
                }
                .padding(inset)
            }
        }
        .clipped()
    }
}

nonisolated struct PreviewPageBreak: Equatable {
    let y: CGFloat
    let height: CGFloat

    static func segments(_ breaks: [Self], bodyY: CGFloat, totalHeight: CGFloat) -> [Self] {
        var result: [Self] = []
        var start: CGFloat = 0
        for boundary in breaks.filter({ $0.y >= 0 && $0.height > 0 }).sorted(by: { $0.y < $1.y }) {
            let end = min(totalHeight, bodyY + boundary.y)
            if end > start { result.append(Self(y: start, height: end - start)) }
            start = max(start, min(totalHeight, bodyY + boundary.y + boundary.height))
        }
        if start < totalHeight { result.append(Self(y: start, height: totalHeight - start)) }
        return result
    }
}

struct LibrarySnapshotHeader: View {
    let document: DocumentRecord
    let cover: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if document.appearance.displaysCover {
                Group {
                    if let cover { Image(decorative: cover, scale: 1).resizable().scaledToFill() }
                    else { ThemeCoverArt(theme: document.appearance.resolvedCoverTheme) }
                }
                .frame(width: 320, height: 180).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: 8) {
                if document.dailyNoteDate != nil { LibraryIcon(name: "mooncal", size: 20) }
                Text(document.title)
            }
                .font(.system(size: 26, weight: .black, design: document.appearance.fontStyle.design))
                .foregroundStyle(Color(vellixHex: document.appearance.textColorHex))
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color(vellixHex: document.appearance.textColorHex).opacity(0.13)).frame(height: 1)
        }
    }
}

struct LibrarySnapshotSurface: View {
    let style: DocumentBackgroundStyle
    let photo: CGImage?
    var body: some View {
        DocumentBackgroundFill(style: style, photo: photo)
    }
}
