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
    var cardFallbackRenderer: ((DocumentRecord, ColorScheme, Bool) -> CGImage?)?
    var openPageFallbackRenderer: ((DocumentRecord, ColorScheme) -> OpenPageSnapshots?)?
    private static let stickySnapshotSuffix = "-sticky-content-no-title-v2"
    private static let pagesSnapshotSuffix = "-pages-no-title-v1"
    private static let openPageSnapshotSuffix = "-open-page-flow-no-title-v2"
    private let cardImages = NSCache<NSString, PreviewImageBox>()
    private let openPageImages = NSCache<NSString, OpenPageSnapshotBox>()
    private var failedOpenPages = Set<String>()
    private var renderingCards = Set<String>()
    private var cardKeys: [String: (document: DocumentRecord, scheme: ColorScheme, key: String)] = [:]
    private var observation: AnyCancellable?
    private var activeEditors: Set<String> = []
    private var deferredRecords: [String: DocumentRecord] = [:]
    private var needsContentRefresh = false
    private var refreshTask: Task<Void, Never>?
    private let memory = NSCache<NSString, PreviewImageBox>()
    private var pending: [String: Task<CGImage?, Never>] = [:]
    var isCapturingPreview: Bool { !pending.isEmpty }
    private var tail: Task<Void, Never>?
    private var renderGeneration = 0
    private let presentedImages = NSCache<NSString, PreviewImageBox>()
    private(set) var presentationEpoch = 0

    // === TEMP STARTUP PROBE (remove after diagnosing launch perf) ===
    // Counts and times the synchronous, main-thread preview lookups that happen
    // inside SwiftUI cell bodies during first render.
    var probeCalls = 0, probeKeyMs = 0.0, probeMemHits = 0
    var probeDiskReads = 0, probeDiskMs = 0.0, probeOrphanHits = 0, probeOrphanMs = 0.0
    var probeRecordCalls = 0, probeRecordKeyMs = 0.0
    func dumpStartupProbe(_ tag: String) {
        print("⏱️ THUMB-RENDER [\(tag)] summaryCalls=\(probeCalls) keyMs=\(Int(probeKeyMs)) memHit=\(probeMemHits) diskRead=\(probeDiskReads) diskMs=\(Int(probeDiskMs)) orphanHit=\(probeOrphanHits) orphanMs=\(Int(probeOrphanMs)) | recordCalls=\(probeRecordCalls) recordKeyMs=\(Int(probeRecordKeyMs))")
    }
    // === END TEMP ===
    // Key-independent lookup of a document's existing preview file by its
    // "<documentID>-" filename prefix. A render keeps exactly one preview file per
    // document (it prunes the rest), so this locates that document's current preview
    // even when a cache-key change leaves it orphaned from the computed key. The
    // directory is scanned once; per-id results (hit or miss) and decoded images are
    // memoized so repeated cell renders do no further disk work.
    private var orphanDirectoryScan: [URL]?
    private var orphanURLByID: [String: URL?] = [:]
    private var orphanImageByID: [String: CGImage] = [:]
    private let loadEditor: ((WKWebView, Coordinator) -> Void)?
    private var renderer: TipTapEditorWebViewStore?
    private static let previewDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VellixDocumentPreviewsStyles-v10-collections", isDirectory: true)
    private let directory = DocumentPreviewCache.previewDirectory

    // TEMP: targeted Code Den preview diagnostics. Remove after investigation.
    private func traceCodeDen(_ document: DocumentRecord, _ event: String) {
        guard document.title.localizedCaseInsensitiveContains("Code Den") || document.title == "Untitled" else { return }
        print("🟡 CODE-DEN-PREVIEW [cache] \(event) id=\(document.id.prefix(8)) activeEditors=\(activeEditors.count) pending=\(pending.count) generation=\(renderGeneration)")
    }

    struct PrimedPreviews: Sendable {
        var files: [URL]
        var images: [String: (url: URL, image: CGImage)]
    }

    static func readInitialPreviews(_ ids: [String]) async -> PrimedPreviews? {
        guard !ids.isEmpty else { return nil }
        let directory = previewDirectory
        return await Task.detached(priority: .userInitiated) { () -> PrimedPreviews? in
            // === TEMP STARTUP DIAGNOSTICS: thumbnail prefetch breakdown ===
            func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
            func ms(_ a: TimeInterval, _ b: TimeInterval) -> Int { Int((b - a) * 1000) }
            let t0 = now()
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                print("⏱️ THUMB-PREFETCH enumerate FAILED")
                return nil
            }
            let tEnum = now()
            let pngCount = files.reduce(0) { $0 + ($1.pathExtension == "png" ? 1 : 0) }
            var images: [String: (url: URL, image: CGImage)] = [:]
            var decodedBytes = 0
            var subLocate = 0, subRead = 0, subDecode = 0, subBlank = 0
            var perID: [String] = []
            // This is only the near-viewport set, not an attempt to decode
            // every PNG in the directory. Other cells retain their disk hit.
            for id in ids where images[id] == nil {
                guard decodedBytes < 20 * 1024 * 1024 else { break }
                let a = now()
                guard let url = files.first(where: { $0.pathExtension == "png" && $0.lastPathComponent.hasPrefix(id + "-") }) else {
                    subLocate += ms(a, now()); perID.append("\(id.prefix(6)):notfound"); continue
                }
                let b = now(); subLocate += ms(a, b)
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    subRead += ms(b, now()); perID.append("\(id.prefix(6)):readfail"); continue
                }
                let c = now(); subRead += ms(b, c)
                guard data.count <= 20_000_000,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: DocumentPreviewImageFile.galleryMaxPixelSize,
                      ] as CFDictionary) else {
                    subDecode += ms(c, now()); perID.append("\(id.prefix(6)):decodefail"); continue
                }
                let d = now(); subDecode += ms(c, d)
                let blank = DocumentPreviewImageFile.isBlank(image)
                let e = now(); subBlank += ms(d, e)
                if blank { perID.append("\(id.prefix(6)):blank"); continue }
                images[id] = (url, image)
                decodedBytes += image.bytesPerRow * image.height
                perID.append("\(id.prefix(6)) loc=\(ms(a,b)) read=\(ms(b,c)) dec=\(ms(c,d)) blank=\(ms(d,e)) bytes=\(data.count) px=\(image.width)x\(image.height)")
            }
            let tEnd = now()
            let total = ms(t0, tEnd)
            let accounted = ms(t0, tEnum) + subLocate + subRead + subDecode + subBlank
            print("⏱️ THUMB-PREFETCH total=\(total)ms enumerate=\(ms(t0,tEnum))ms(files=\(files.count),png=\(pngCount)) locate=\(subLocate)ms read=\(subRead)ms decode=\(subDecode)ms blankchk=\(subBlank)ms unaccounted_scheduling=\(total - accounted)ms requested=\(ids.count) loaded=\(images.count) || \(perID.joined(separator: " | "))")
            // === END TEMP ===
            return PrimedPreviews(files: files, images: images)
        }.value
    }

    func installInitialPreviews(_ previews: PrimedPreviews) {
        orphanDirectoryScan = previews.files
        for (id, preview) in previews.images {
            let key = preview.url.deletingPathExtension().lastPathComponent
            remember(preview.image, key: key)
            orphanURLByID[id] = preview.url
            orphanImageByID[id] = preview.image
        }
    }

    init(documents: DocumentRepository, attachments: AttachmentStore, collections: CollectionRepository,
         loadEditor: ((WKWebView, Coordinator) -> Void)? = nil) {
        self.documents = documents
        self.attachments = attachments
        self.collections = collections
        self.loadEditor = loadEditor
        cardImages.totalCostLimit = 24 * 1024 * 1024
        openPageImages.totalCostLimit = 16 * 1024 * 1024
        openPageImages.countLimit = 24
        memory.totalCostLimit = 32 * 1024 * 1024
        presentedImages.totalCostLimit = 24 * 1024 * 1024
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        observation = NotificationCenter.default.publisher(for: .pennedCollectionsChanged, object: collections.database)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleContentRefresh() }
    }

    func setEditorActive(_ documentID: String, active: Bool) {
        if active { activeEditors.insert(documentID); refreshTask?.cancel() }
        else {
            activeEditors.remove(documentID)
            if activeEditors.isEmpty { scheduleContentRefresh() }
        }
    }

    private func scheduleContentRefresh() {
        needsContentRefresh = true
        refreshTask?.cancel()
        guard activeEditors.isEmpty else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.activeEditors.isEmpty else { return }
            if self.needsContentRefresh { self.needsContentRefresh = false; self.refreshContents() }
            let pending = self.deferredRecords.values.compactMap { record in try? self.documents.requireDocument(id: record.id) }
                .filter { !$0.isTrashed }
            self.deferredRecords.removeAll()
            self.prewarm(pending)
        }
    }

    func content(for document: DocumentRecord) -> DocumentPreviewContent {
        guard documents.spaceID == nil || documents.spaceID == document.spaceID else { return DocumentPreviewContent(document: document, children: [], collections: []) }
        if let cached = contents[document.id], cached.document == document { return cached }
        guard let result = try? collections.previewContent(for: document, documents: documents) else {
            return contents[document.id] ?? DocumentPreviewContent(document: document, children: [], collections: [])
        }
        contents[document.id] = result
        return result
    }

    // Memoized base preview key. The hash + repeated document-JSON scans in
    // `cacheKey(for:)` are expensive, and the library grid recomputes the key
    // several times per view update per cell. `cardKeys` caches it keyed by the
    // document record + scheme and is already invalidated wherever content can
    // change: `documentDidSave` (local edits and affected parents),
    // `refreshContents` (child/collection changes), and `resetForSpaceChange`
    // (which sync import triggers via reloadAfterLibraryImport). So a memo hit is
    // valid exactly when the recomputed key would be identical — no stale keys.
    func presentationCacheKey(for document: DocumentRecord, colorScheme: ColorScheme) -> String {
        if let cached = cardKeys[document.id], cached.document == document, cached.scheme == colorScheme {
            return cached.key
        }
        let key = content(for: document).cacheKey(for: colorScheme)
        cardKeys[document.id] = (document, colorScheme, key)
        return key
    }

    func cardPresentationKey(for document: DocumentRecord, colorScheme: ColorScheme) -> String {
        let key = presentationCacheKey(for: document, colorScheme: colorScheme)
        let previewStyle = Self.cardPreviewStyle(for: document)
        let snapshotKey = key + Self.snapshotSuffix(for: previewStyle)
        let hasSnapshot = hasCardSnapshot(key: snapshotKey, style: previewStyle)
        return snapshotKey + (hasSnapshot ? ":snapshot" : ":native")
    }

    private static func snapshotSuffix(for style: PageCardPreviewStyle) -> String {
        switch style {
        case .pages: return pagesSnapshotSuffix
        case .stickyNote: return stickySnapshotSuffix
        case .openPage: return openPageSnapshotSuffix
        }
    }

    private static func cardPreviewStyle(for document: DocumentRecord) -> PageCardPreviewStyle {
        document.cardStyle?.isBook == true ? .pages : (document.cardStyle?.previewStyle ?? .pages)
    }

    private static func showsCardPreview(for document: DocumentRecord) -> Bool {
        document.cardStyle.map { $0.isBook || $0.showsPages } ?? false
    }

    private func hasCardSnapshot(key: String, style: PageCardPreviewStyle) -> Bool {
        if style == .openPage { return openPageImages.object(forKey: key as NSString)?.isFinal == true }
        return memory.object(forKey: key as NSString) != nil
    }

    func openPageSnapshots(for requested: DocumentRecord, colorScheme: ColorScheme) -> OpenPageSnapshots? {
        guard documents.spaceID == nil || documents.spaceID == requested.spaceID else { return nil }
        let content = content(for: requested)
        let document = content.document
        let key = content.cacheKey(for: colorScheme) + Self.openPageSnapshotSuffix
        if let cached = openPageImages.object(forKey: key as NSString) { return cached.snapshots }
        if !failedOpenPages.contains(key) {
            deferredRecords[document.id] = document
            if activeEditors.isEmpty { scheduleContentRefresh() }
        }
        guard renderingCards.count < 3, renderingCards.insert(document.id).inserted else { return nil }
        defer { renderingCards.remove(document.id) }
        guard let spread = openPageFallbackRenderer?(document, colorScheme) else { return nil }
        openPageImages.setObject(OpenPageSnapshotBox(spread, isFinal: false), forKey: key as NSString, cost: spread.cost)
        return spread
    }

    func cardSnapshot(for requested: DocumentRecord, colorScheme: ColorScheme, hidesPageSurfaces: Bool = false,
                      allowsNativeFallback: Bool = true) -> CGImage? {
        let content = content(for: requested)
        let document = content.document
        let base = content.cacheKey(for: colorScheme)
        let key = (base + (hidesPageSurfaces ? Self.stickySnapshotSuffix : Self.pagesSnapshotSuffix)) as NSString
        if let cached = memory.object(forKey: key) { return cached.image }
        if let cached = cardImages.object(forKey: key) { return cached.image }
        if !allowsNativeFallback {
            if deferredRecords[document.id] != document {
                deferredRecords[document.id] = document
                if activeEditors.isEmpty { scheduleContentRefresh() }
            }
            return nil
        }
        guard renderingCards.count < 3, renderingCards.insert(document.id).inserted else { return nil }
        defer { renderingCards.remove(document.id) }
        guard let image = cardFallbackRenderer?(document, colorScheme, hidesPageSurfaces) else { return nil }
        cardImages.setObject(PreviewImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        deferredRecords[document.id] = document
        if activeEditors.isEmpty { scheduleContentRefresh() }
        return image
    }

    func documentDidSave(_ document: DocumentRecord) {
        var affected: Set<String> = [document.id]
        if let parent = document.parentDocumentID { affected.insert(parent) }
        var count = 0
        repeat {
            count = affected.count
            for (id, content) in contents where content.children.contains(where: { affected.contains($0.id) }) { affected.insert(id) }
        } while affected.count != count
        for id in affected {
            contents[id] = nil; cardKeys[id] = nil
            failedOpenPages = failedOpenPages.filter { !$0.hasPrefix(id + "-") }
        }
        clearOrphanCache(ids: affected)
        contentRevision += 1
        prewarm([document])
    }

    private func refreshContents() {
        var changed: [DocumentRecord] = []
        for id in Array(contents.keys) {
            guard let document = try? documents.requireDocument(id: id), !document.isTrashed,
                  let next = try? collections.previewContent(for: document, documents: documents) else {
                contents[id] = nil; cardKeys[id] = nil
                continue
            }
            if contents[id] != next {
                cardKeys[id] = nil
                let visualChange = contents[id]?.cacheKey != next.cacheKey
                contents[id] = next
                if visualChange { changed.append(document) }
            }
        }
        if !changed.isEmpty { clearOrphanCache(ids: Set(changed.map(\.id))); contentRevision += 1; prewarm(changed) }
    }

    func cachedImage(for document: DocumentRecord, colorScheme: ColorScheme = .dark) -> CGImage? {
        let expected = presentationCacheKey(for: document, colorScheme: colorScheme)
        if let image = memory.object(forKey: expected as NSString) { return image.image }
        let url = directory.appendingPathComponent(expected + ".png")
        guard let image = DocumentPreviewImageFile.readVisiblePreview(url) else { return nil }
        remember(image, key: expected)
        return image
    }

    func cachedPresentationImage(for document: DocumentRecord, colorScheme: ColorScheme = .dark) -> CGImage? {
        probeRecordCalls += 1                                                           // TEMP PROBE
        let probeKeyStart = ProcessInfo.processInfo.systemUptime                        // TEMP PROBE
        let key = presentationCacheKey(for: document, colorScheme: colorScheme) as NSString
        probeRecordKeyMs += (ProcessInfo.processInfo.systemUptime - probeKeyStart) * 1000 // TEMP PROBE
        return presentedImages.object(forKey: key)?.image ?? memory.object(forKey: key)?.image
    }

    // Display-only fallback, never an exact-key cache hit. Keeping freshness
    // lookups separate lets a visible card retain its PNG AND request regeneration.
    func retainedPresentationImage(documentID: String, spaceID: String?) -> CGImage? {
        guard documents.spaceID == nil || documents.spaceID == spaceID else { return nil }
        return orphanedPreviewImage(forDocumentID: documentID)
    }

    func loadPresentationImage(for document: DocumentRecord, colorScheme: ColorScheme = .dark) async -> CGImage? {
        let key = presentationCacheKey(for: document, colorScheme: colorScheme)
        if let image = cachedPresentationImage(for: document, colorScheme: colorScheme) { return image }
        let url = directory.appendingPathComponent(key + ".png")
        let image = await Task.detached(priority: .utility) {
            DocumentPreviewImageFile.readVisiblePreview(url)
        }.value
        guard !Task.isCancelled, let image,
              content(for: document).cacheKey(for: colorScheme) == key else { return nil }
        remember(image, key: key)
        presentedImages.setObject(PreviewImageBox(image), forKey: key as NSString,
                                  cost: image.bytesPerRow * image.height)
        return image
    }

    // MARK: Body-free presentation lookups for the paginated gallery
    //
    // These resolve the identical preview key from a document's stored descriptor —
    // no document body is loaded — so a cached cell never reads its tipTapJSON. A
    // nil key means the descriptor isn't available yet; the caller then loads the
    // full record and uses the record path, which is always correct.

    func presentationCacheKey(for summary: DocumentSummary, colorScheme: ColorScheme = .dark) -> String? {
        guard documents.spaceID == nil || documents.spaceID == summary.spaceID else { return nil }
        return try? collections.presentationCacheKey(forSummary: summary, documents: documents, colorScheme: colorScheme)
    }

    func cachedPresentationImage(for summary: DocumentSummary, colorScheme: ColorScheme = .dark) -> CGImage? {
        probeCalls += 1                                                                 // TEMP PROBE
        let probeKeyStart = ProcessInfo.processInfo.systemUptime                        // TEMP PROBE
        let probedKey = presentationCacheKey(for: summary, colorScheme: colorScheme)    // TEMP PROBE
        probeKeyMs += (ProcessInfo.processInfo.systemUptime - probeKeyStart) * 1000     // TEMP PROBE
        let trace = summary.title == "Untitled" || summary.title.localizedCaseInsensitiveContains("Code Den")
        if trace { print("🟡 CODE-DEN-PREVIEW [lookup] key=\(probedKey?.prefix(32) ?? "NIL")") }
        if let key = probedKey {
            if let image = presentedImages.object(forKey: key as NSString)?.image ?? memory.object(forKey: key as NSString)?.image {
                if trace { print("🟡 CODE-DEN-PREVIEW [lookup] SOURCE=MEMORY size=\(image.width)x\(image.height) blank=\(DocumentPreviewImageFile.isBlank(image))") }
                probeMemHits += 1                                                       // TEMP PROBE
                return image
            }
            // A preview persisted on a previous launch is read synchronously here so
            // the card paints it on its first frame rather than after an async read.
            let url = directory.appendingPathComponent(key + ".png")
            let probeDiskStart = ProcessInfo.processInfo.systemUptime                   // TEMP PROBE
            let probedImage = DocumentPreviewImageFile.readVisiblePreview(url)          // TEMP PROBE
            probeDiskMs += (ProcessInfo.processInfo.systemUptime - probeDiskStart) * 1000 // TEMP PROBE
            if let image = probedImage {
                if trace { print("🟡 CODE-DEN-PREVIEW [lookup] SOURCE=EXACT-DISK file=\(url.lastPathComponent) size=\(image.width)x\(image.height) blank=\(DocumentPreviewImageFile.isBlank(image))") }
                probeDiskReads += 1                                                     // TEMP PROBE
                remember(image, key: key)
                presentedImages.setObject(PreviewImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
                return image
            }
        }
        // An ID-matched PNG with a different cache key may belong to an older
        // revision of this document. Do not treat it as a valid cache hit: let
        // the gallery load the document and generate its current preview.
        if trace { print("🟡 CODE-DEN-PREVIEW [lookup] CURRENT KEY MISS; allowing regeneration") }
        return nil
    }

    // Locates a document's single persisted preview file by its "<id>-" filename
    // prefix, independent of the cache-key hash, and returns the decoded image.
    // Scans the preview directory once and memoizes per-id results and images.
    private func orphanedPreviewImage(forDocumentID id: String) -> CGImage? {
        if let image = orphanImageByID[id] { return image }
        let url: URL?
        if let cached = orphanURLByID[id] {
            url = cached
        } else {
            let files = orphanDirectoryScan ?? {
                let scanned = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                orphanDirectoryScan = scanned
                return scanned
            }()
            let prefix = id + "-"
            url = files.first { $0.pathExtension == "png" && $0.lastPathComponent.hasPrefix(prefix) }
            orphanURLByID[id] = url
        }
        guard let url, let image = DocumentPreviewImageFile.readVisiblePreview(url) else { return nil }
        orphanImageByID[id] = image
        return image
    }

    // Drops memoized orphan lookups for documents whose previews just changed, so a
    // later lookup re-evaluates freshness (and the newly written/pruned files) rather
    // than returning a stale reused preview.
    private func clearOrphanCache(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        orphanDirectoryScan = nil
        for id in ids { orphanURLByID[id] = nil; orphanImageByID[id] = nil }
    }

    func loadPresentationImage(for summary: DocumentSummary, colorScheme: ColorScheme = .dark) async -> CGImage? {
        guard let key = presentationCacheKey(for: summary, colorScheme: colorScheme) else { return nil }
        if let image = presentedImages.object(forKey: key as NSString)?.image ?? memory.object(forKey: key as NSString)?.image { return image }
        let url = directory.appendingPathComponent(key + ".png")
        let image = await Task.detached(priority: .utility) { DocumentPreviewImageFile.readVisiblePreview(url) }.value
        guard !Task.isCancelled, let image else { return nil }
        remember(image, key: key)
        presentedImages.setObject(PreviewImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    func presentationImage(for document: DocumentRecord, colorScheme: ColorScheme = .dark, fallback: () -> CGImage?) -> CGImage? {
        let key = content(for: document).cacheKey(for: colorScheme) as NSString
        if let image = presentedImages.object(forKey: key) { return image.image }
        guard let image = cachedImage(for: document, colorScheme: colorScheme) ?? fallback(),
              !DocumentPreviewImageFile.isBlank(image) else { return nil }
        presentedImages.setObject(PreviewImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    func beginLibraryPresentation() {
        presentedImages.removeAllObjects()
        presentationEpoch += 1
    }

    func resetForSpaceChange() {
        refreshTask?.cancel(); refreshTask = nil
        activeEditors.removeAll(); deferredRecords.removeAll(); needsContentRefresh = false
        renderGeneration += 1
        pending.values.forEach { $0.cancel() }
        // Cancelled WebKit calls can still finish. Keep their queue barrier so
        // a new document cannot replace the DOM while a capture is unwinding.
        pending.removeAll(); contents.removeAll()
        cardImages.removeAllObjects()
        openPageImages.removeAllObjects()
        failedOpenPages.removeAll()
        cardKeys.removeAll()
        beginLibraryPresentation()
        contentRevision += 1
    }

    func remove(documentIDs: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where documentIDs.contains(String(file.lastPathComponent.prefix(36))) { try? FileManager.default.removeItem(at: file) }
        clearOrphanCache(ids: documentIDs)
        memory.removeAllObjects(); resetForSpaceChange()
    }

    func prewarm(_ records: [DocumentRecord]) {
        guard activeEditors.isEmpty else {
            for record in records { deferredRecords[record.id] = record }
            return
        }
        // Metadata is ready before Home draws; image rendering stays off its first-frame path.
        var imagePaths: [String] = []
        for record in records {
            guard documents.spaceID == nil || documents.spaceID == record.spaceID else { continue }
            _ = content(for: record)
            // Avoid decoding persisted PNGs on the main actor during library prewarming.
            // Visible cards load saved images asynchronously instead.
            // Collect the card's background/cover image paths so they can be
            // decoded off the main actor below; otherwise the immediate
            // (pre-snapshot) card render decodes them synchronously on screen.
            if let cover = record.cover { imagePaths.append(cover) }
            if record.isThemed {
                let appearance = record.appearance
                if let background = appearance.editorBackground.imagePath { imagePaths.append(background) }
                if let inner = appearance.innerPageBackground.imagePath { imagePaths.append(inner) }
            }
        }
        if !imagePaths.isEmpty {
            // CardImageLoader caches by path and is thread-safe; AttachmentStore
            // access is nonisolated. Warm the decode cache off the main actor so
            // the first card render finds these already decoded.
            let paths = imagePaths, store = attachments
            Task.detached(priority: .utility) {
                for path in paths { _ = CardImageLoader.image(path: path, store: store) }
            }
        }
        // Avoid starting WebKit capture work during library loading: the same
        // rendering resources are needed when a document is opened.
        // Visible cards load existing PNGs asynchronously and use native fallbacks.
    }

    func image(for document: DocumentRecord, colorScheme: ColorScheme = .dark, ignoringActiveEditors: Bool = false) async -> CGImage? {
        await image(for: document, colorScheme: colorScheme, ancestors: [], ignoringActiveEditors: ignoringActiveEditors)
    }

    private func image(for requested: DocumentRecord, colorScheme: ColorScheme, ancestors: Set<String>, ignoringActiveEditors: Bool = false) async -> CGImage? {
        let generation = renderGeneration
        guard documents.spaceID == nil || documents.spaceID == requested.spaceID else { return nil }
        guard ancestors.count < 3, !ancestors.contains(requested.id) else { return cachedImage(for: requested, colorScheme: colorScheme) }
        guard ignoringActiveEditors || activeEditors.isEmpty else {
            traceCodeDen(requested, "deferred: active editor")
            deferredRecords[requested.id] = requested
            return cachedImage(for: requested, colorScheme: colorScheme)
        }
        let content = content(for: requested)
        let document = content.document
        let key = content.cacheKey(for: colorScheme)
        traceCodeDen(document, "image requested; cacheKey=\(key.prefix(24)) resolvedCollections=\(content.hasResolvedCollections)")
        let previewStyle = Self.cardPreviewStyle(for: document)
        let miniatureKey = key + Self.snapshotSuffix(for: previewStyle)
        let needsCardCapture = Self.showsCardPreview(for: document) && !failedOpenPages.contains(miniatureKey)
            && !hasCardSnapshot(key: miniatureKey, style: previewStyle)
        if !needsCardCapture, let cached = memory.object(forKey: key as NSString) { return cached.image }
        if let task = pending[key] { return await task.value }
        let url = directory.appendingPathComponent(key + ".png")
        if !needsCardCapture {
            // Disk I/O and PNG decoding must not block the main actor.
            let image = await Task.detached(priority: .utility) {
                DocumentPreviewImageFile.readVisiblePreview(url)
            }.value
            guard !Task.isCancelled, renderGeneration == generation else { return nil }
            if let image {
                remember(image, key: key)
                return image
            }
        }
        // Resolve card miniatures before entering the single WebView queue; never wait on that queue from inside a render.
        for child in content.children where Self.showsCardPreview(for: child) && !ancestors.contains(child.id) && child.id != document.id {
            _ = await image(for: child, colorScheme: colorScheme, ancestors: ancestors.union([document.id]), ignoringActiveEditors: ignoringActiveEditors)
            guard !Task.isCancelled, renderGeneration == generation else { return nil }
        }
        if let task = pending[key] { return await task.value }
        guard !Task.isCancelled, renderGeneration == generation,
              contents[document.id]?.cacheKey(for: colorScheme) == key else { return nil }
        guard ignoringActiveEditors || activeEditors.isEmpty else { deferredRecords[document.id] = document; return nil }
        let prior = tail
        let task = Task { [weak self] () -> CGImage? in
            await prior?.value
            guard let self else { return nil }
            guard !Task.isCancelled, renderGeneration == generation else { return nil }
            guard ignoringActiveEditors || self.activeEditors.isEmpty else {
                self.deferredRecords[document.id] = document
                return nil
            }
            guard contents[document.id]?.cacheKey(for: colorScheme) == key else { return nil }
            do {
                traceCodeDen(document, "WebKit render starting")
                let image = try await render(content, colorScheme: colorScheme)
                let sameGeneration = renderGeneration == generation
                let sameKey = contents[document.id]?.cacheKey(for: colorScheme) == key
                let blank = DocumentPreviewImageFile.isBlank(image)
                traceCodeDen(document, "render finished size=\(image.width)x\(image.height) cancelled=\(Task.isCancelled) sameGeneration=\(sameGeneration) sameKey=\(sameKey) blank=\(blank)")
                guard !Task.isCancelled, sameGeneration, sameKey, !blank else { return nil }
                try await Task.detached(priority: .utility) {
                    try DocumentPreviewImageFile.write(image, to: url)
                }.value
                guard !Task.isCancelled, renderGeneration == generation,
                      contents[document.id]?.cacheKey(for: colorScheme) == key else { return nil }
                remember(image, key: key)
                traceCodeDen(document, "PNG SAVED path=\(url.lastPathComponent) exists=\(FileManager.default.fileExists(atPath: url.path))")
                PennedPreviewDiagnostics.recordRegenerated()
                // One persisted revision per document; these are disposable previews, not user data.
                // Compare by file name: contentsOfDirectory can return /private-prefixed
                // URLs that are != the write URL for the SAME file, which previously
                // deleted the freshly written preview.
                let oldFiles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for old in oldFiles where old.lastPathComponent.hasPrefix(document.id + "-") && old.lastPathComponent != url.lastPathComponent {
                    try? FileManager.default.removeItem(at: old)
                }
                clearOrphanCache(ids: [document.id])
                contentRevision += 1
                return image
            } catch {
                traceCodeDen(document, "RENDER FAILED: \(error.localizedDescription)")
                PennedPreviewDiagnostics.recordFailure(error.localizedDescription)
                if previewStyle == .openPage, !Task.isCancelled, renderGeneration == generation {
                    failedOpenPages.insert(miniatureKey)
                }
                return nil
            }
        }
        pending[key] = task
        tail = Task { _ = await task.value }
        let image = await task.value
        if renderGeneration == generation { pending[key] = nil }
        return image
    }

    private func remember(_ image: CGImage, key: String) {
        memory.setObject(PreviewImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    static func cacheKey(_ document: DocumentRecord, children: [DocumentRecord], collections: [CollectionSnapshot] = []) -> String {
        DocumentPreviewContent.cacheKey(document, children: children, collections: collections)
    }

    private func captureRenderer() -> TipTapEditorWebViewStore {
        if let renderer { return renderer }
        let session = TipTapEditorSession()
        session.attachmentStore = attachments
        session.attachmentResolver = { [weak documents = self.documents, attachments = self.attachments] id, json in
            try documents?.editorAttachments(documentID: id, json: json, store: attachments) ?? []
        }
        session.preparesInteractivePresentation = false
        session.documentPreviewCache = self
        let renderer = TipTapEditorWebViewStore(session: session, loadEditor: loadEditor)
        self.renderer = renderer
        return renderer
    }

    private func discardRenderer() {
        guard let renderer else { return }
        self.renderer = nil
        renderer.coordinator.cleanUp(renderer.webView)
        renderer.webView.stopLoading()
    }

    private func render(_ content: DocumentPreviewContent, colorScheme: ColorScheme) async throws -> CGImage {
        guard content.hasResolvedCollections else { throw PreviewError.renderUnavailable }
        let document = content.document
        let proof = try DocumentPreviewCaptureIdentity(json: document.tipTapJSON)
        let appearance = document.appearance.resolved(for: colorScheme)
        let documentScheme = appearance.presentationColorScheme
        let renderer = captureRenderer()
        var completed = false
        defer { if !completed { discardRenderer() } }
        let session = renderer.coordinator.session
        let webView = renderer.webView
        webView.frame = CGRect(x: 0, y: 0, width: 320, height: 800)
        session.bridgeErrorMessage = nil
        session.setApplicationColorScheme(colorScheme)
        session.setAppearance(document.appearance)
        session.setPageReferences(content.children)
        session.setCollections(content.payloads)
        session.load(documentID: document.id, canonicalJSON: proof.json, force: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !session.isReady || session.isLoadingDocument {
            guard ContinuousClock.now < deadline else { throw PreviewError.renderUnavailable }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        guard session.hasLoadedDocument(document.id) else { throw PreviewError.renderUnavailable }
        try await verifyCapture(proof, in: webView, prepare: true)
        var requiredSelectors: [String] = []
        if TipTapContentAnalyzer.hasClipSources(in: document.tipTapJSON) { requiredSelectors.append(".penned-clip-source") }
        if TipTapContentAnalyzer.hasListGrids(in: document.tipTapJSON) {
            requiredSelectors.append("[data-list-grid] [data-list-grid-row][data-lg-row-style]")
        }
        if !requiredSelectors.isEmpty {
            // Keep the native fallback if the loaded bundle cannot render the saved block.
            let isComplete = try await webView.callAsyncJavaScript("return selectors.every(selector => !!document.querySelector(selector));",
                arguments: ["selectors": requiredSelectors], in: nil, contentWorld: .page) as? Bool ?? false
            guard isComplete else { throw PreviewError.renderUnavailable }
        }
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
            let native = ImageRenderer(content: CollectionSnapshotPreview(snapshot: snapshot, appearance: appearance, attachments: attachments)
                .frame(width: CGFloat(width.doubleValue)).environment(\.colorScheme, documentScheme))
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
            if (needsFontLoad) {
                window.tiptapCommand('setAppearance', appearance);
                const editor = document.querySelector('.tiptap-editor, .ProseMirror');
                editor.getBoundingClientRect();
                const sample = editor.textContent || 'Hachi Maru Pop';
                await Promise.all(['normal 400', 'normal 700', 'italic 400', 'italic 700'].map(face =>
                    document.fonts.load(`${face} 16px "HachiMaruPop"`, sample)));
            }
            await document.fonts.ready;
            const assets = getComputedStyle(document.documentElement);
            async function rasterizedIcon(source, width, height, color) {
                const match = source.match(/url\(["']?(.*?)["']?\)/);
                if (!match || width <= 0 || height <= 0) return null;
                const glyph = new Image();
                glyph.src = match[1];
                await glyph.decode();
                const canvas = document.createElement('canvas');
                canvas.width = Math.max(1, Math.ceil(width * 3));
                canvas.height = Math.max(1, Math.ceil(height * 3));
                const context = canvas.getContext('2d');
                const scale = Math.min(canvas.width / glyph.naturalWidth, canvas.height / glyph.naturalHeight);
                const w = glyph.naturalWidth * scale, h = glyph.naturalHeight * scale;
                context.drawImage(glyph, (canvas.width - w) / 2, (canvas.height - h) / 2, w, h);
                context.globalCompositeOperation = 'source-in';
                context.fillStyle = color;
                context.globalAlpha = 1;
                context.fillRect(0, 0, canvas.width, canvas.height);
                return canvas.toDataURL('image/png');
            }
            for (const callout of document.querySelectorAll('.vellix-callout')) {
                const icon = callout.querySelector('.vellix-callout-icon-image');
                if (!icon) continue;
                const name = callout.dataset.calloutIcon || 'sparkle';
                const source = assets.getPropertyValue('--vellix-asset-' + name)
                    || assets.getPropertyValue('--vellix-asset-sparkle');
                const {width, height} = icon.getBoundingClientRect();
                const png = await rasterizedIcon(source, width, height, callout.dataset.calloutColor || '#FFFFFF');
                if (!png) continue;
                const image = document.createElement('img');
                image.className = 'vellix-preview-callout-icon';
                image.src = png;
                const inset = callout.matches('.penned-grid-card') ? 0 : 8;
                image.style.cssText = `position:absolute;inset:${inset}px;object-fit:contain;margin:0;max-width:none;border:0;`;
                image.style.width = width + 'px';
                image.style.height = height + 'px';
                icon.replaceWith(image);
                await image.decode();
            }
            for (const icon of document.querySelectorAll('.penned-clip-saved .vellix-property-calendar, .penned-label-icon')) {
                const style = getComputedStyle(icon);
                const {width, height} = icon.getBoundingClientRect();
                const tint = icon.classList.contains('penned-label-icon') ? style.backgroundColor : style.color;
                const png = await rasterizedIcon(style.webkitMaskImage || style.maskImage, width, height, tint);
                if (!png) continue;
                const image = document.createElement('img');
                image.src = png;
                image.style.cssText = `display:inline-block;flex:0 0 ${width}px;width:${width}px;height:${height}px;margin:0;border:0;max-width:none;object-fit:contain;`;
                icon.replaceWith(image);
                await image.decode();
            }
            // Collection controls and callout disclosure chevrons use CSS alpha
            // masks that WebKit's PDF export can paint as solid rectangles.
            // Rasterize only the snapshot copy; the live editor stays untouched.
            for (const icon of document.querySelectorAll('.penned-collection-icon, .penned-icon-callout-disclosure > span')) {
                const style = getComputedStyle(icon);
                const mask = style.webkitMaskImage || style.maskImage;
                if (!mask || mask === 'none') continue;
                const {width, height} = icon.getBoundingClientRect();
                const png = await rasterizedIcon(mask, width, height, style.backgroundColor).catch(() => null);
                if (!png) continue;
                const image = document.createElement('img');
                image.src = png;
                image.setAttribute('aria-hidden', 'true');
                image.style.cssText = `display:inline-block;flex:0 0 ${width}px;width:${width}px;height:${height}px;margin:0;padding:0;border:0;max-width:none;object-fit:contain;`;
                icon.replaceWith(image);
                await image.decode();
            }
            // Flatten the alpha mask into a tinted tile for WebKit's PDF compositor.
            const grainTiles = new Map();
            for (const grain of document.querySelectorAll('.penned-label-grain')) {
                const style = getComputedStyle(grain);
                const source = style.webkitMaskImage || style.maskImage;
                const tint = style.backgroundColor;
                if (!grainTiles.has(tint)) {
                    grainTiles.set(tint, await rasterizedIcon(source, 128, 128, tint).catch(() => null));
                }
                const tile = grainTiles.get(tint);
                if (!tile) { grain.remove(); continue; }
                grain.style.background = `url("${tile}") 0 0 / 192px 192px repeat`;
                grain.style.setProperty('-webkit-mask', 'none');
                grain.style.setProperty('mask', 'none');
            }
            // WebKit's PDF compositor paints masked pseudo-elements as opaque squares.
            // Flatten only the snapshot's mask, preserving the live editor and icon geometry.
            document.getElementById('penned-preview-toggle-style')?.remove();
            const toggleStyle = document.createElement('style');
            toggleStyle.id = 'penned-preview-toggle-style';
            toggleStyle.textContent = `
                .vellix-toggle-button[data-penned-preview-icon]::before {
                    background-image: var(--penned-preview-toggle-icon) !important;
                    background-color: transparent !important;
                    mask-image: none !important;
                    -webkit-mask-image: none !important;
                }`;
            document.head.appendChild(toggleStyle);
            for (const button of document.querySelectorAll('.vellix-toggle-button')) {
                button.removeAttribute('data-penned-preview-icon');
                button.style.removeProperty('--penned-preview-toggle-icon');
                const icon = getComputedStyle(button, '::before');
                const mask = icon.webkitMaskImage || icon.maskImage;
                if (!mask || mask === 'none') continue;
                const png = await rasterizedIcon(mask, parseFloat(icon.width), parseFloat(icon.height), icon.backgroundColor);
                if (!png) continue;
                const image = new Image(); image.src = png;
                await image.decode();
                button.style.setProperty('--penned-preview-toggle-icon', `url("${png}")`);
                button.dataset.pennedPreviewIcon = '';
            }
            await Promise.race([
                Promise.all(Array.from(document.images).map(image => image.decode().catch(() => {}))),
                new Promise(resolve => setTimeout(resolve, 4000))
            ]);
            // Measuring forces layout even when this read-only renderer is offscreen.
            const root = document.querySelector('.tiptap-editor, .ProseMirror');
            window.pennedRepaintScallopedLabels?.(root);
            const bounds = root.getBoundingClientRect();
            const breaks = Array.from(root.children)
                .filter(node => node.matches('[data-vellix-page-break], [data-type="pageBreak"], [data-page-break]'))
                .map(node => { const rect = node.getBoundingClientRect(); return {y: rect.top - bounds.top, height: rect.height}; });
            return {height: Math.max(24, bounds.height), breaks};
            """#, arguments: ["needsFontLoad": appearance.fontStyle == .hachiMaruPop,
                              "appearance": TipTapEditorCommand.setAppearance(appearance, interfaceScheme: colorScheme).args],
            in: nil, contentWorld: .page) as? [String: Any] ?? [:]
        let bodyHeight = min(CGFloat(570), max(24, CGFloat((measurements["height"] as? NSNumber)?.doubleValue ?? 24)))
        let pageBreaks = (measurements["breaks"] as? [[String: Any]] ?? []).compactMap { entry -> PreviewPageBreak? in
            guard let y = entry["y"] as? NSNumber, let height = entry["height"] as? NSNumber else { return nil }
            return PreviewPageBreak(y: CGFloat(y.doubleValue), height: CGFloat(height.doubleValue))
        }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: 320, height: bodyHeight)
        configuration.allowTransparentBackground = true
        try await verifyCapture(proof, in: webView)
        let data = try await webView.pdf(configuration: configuration)
        try Task.checkCancellation()
        try await verifyCapture(proof, in: webView)
        guard session.hasLoadedDocument(document.id),
              let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1),
              let context = CGContext(data: nil, width: 640, height: Int(ceil(bodyHeight * 2)),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PreviewError.renderUnavailable }
        context.clear(CGRect(x: 0, y: 0, width: 640, height: ceil(bodyHeight * 2)))
        context.scaleBy(x: 2, y: 2)
        context.concatenate(page.getDrawingTransform(.mediaBox,
            rect: CGRect(x: 0, y: 0, width: 320, height: bodyHeight), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let body = context.makeImage() else { throw PreviewError.renderUnavailable }
        func captureHeader(showsTitle: Bool, includesHeader: Bool = true) throws -> (image: CGImage, height: CGFloat) {
            let headerRenderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 10) {
                if includesHeader {
                    if showsTitle || document.appearance.displaysCover {
                        LibrarySnapshotHeader(document: document, cover: CardImageLoader.image(path: document.cover, store: attachments),
                            appearance: appearance, showsTitle: showsTitle)
                    }
                    if let (collection, entry) = content.entryContext {
                        CollectionFieldsSnapshotPreview(snapshot: collection, entry: entry, appearance: appearance)
                    }
                }
            }.frame(width: 320).frame(minHeight: 1).environment(\.colorScheme, documentScheme))
            headerRenderer.scale = 2
            guard let image = headerRenderer.cgImage else { throw PreviewError.renderUnavailable }
            let hasHeader = includesHeader && (showsTitle || document.appearance.displaysCover || content.entryContext != nil)
            return (image, hasHeader ? CGFloat(image.height) / 2 : 0)
        }
        let header = try captureHeader(showsTitle: true)
        let headerHeight = header.height
        let height = min(740, max(480, bodyHeight + headerHeight + 58 + (document.isThemed ? 16 : 0)))
        let snapshotPage = LibrarySnapshotPage(document: document, appearance: appearance, headerImage: header.image, headerHeight: headerHeight,
            bodyImage: body, bodyHeight: bodyHeight, pageBreaks: pageBreaks,
            outerImage: CardImageLoader.image(path: document.appearance.editorBackground.imagePath, store: attachments),
            innerImage: CardImageLoader.image(path: document.appearance.innerPageBackground.imagePath, store: attachments))
        func capture(_ page: LibrarySnapshotPage, height: CGFloat, scale: CGFloat = 2) throws -> CGImage {
            let view = page.frame(width: document.isThemed ? 376 : 360, height: height, alignment: .topLeading)
                .environment(\.colorScheme, documentScheme)
            let imageRenderer = ImageRenderer(content: view)
            imageRenderer.scale = scale
            imageRenderer.isOpaque = false
            guard let image = imageRenderer.cgImage else { throw PreviewError.renderUnavailable }
            return image
        }
        let image = try capture(snapshotPage, height: height)
        if Self.showsCardPreview(for: document) {
            let cardHeader = try captureHeader(showsTitle: false, includesHeader: document.cardStyle?.isBook != true)
            let previewStyle = Self.cardPreviewStyle(for: document)
            if previewStyle == .openPage {
                let key = content.cacheKey(for: colorScheme) + Self.openPageSnapshotSuffix
                failedOpenPages.insert(key)
                if let bodies = try? await OpenPageSnapshotRenderer.capture(in: webView, header: cardHeader.image, headerHeight: cardHeader.height) {
                    try Task.checkCancellation()
                    try await verifyCapture(proof, in: webView)
                    guard session.hasLoadedDocument(document.id) else { throw PreviewError.renderUnavailable }
                    let pageHeight = OpenPageSnapshotRenderer.contentHeight + 40 + (document.isThemed ? 16 : 0)
                    func openSheet(_ body: CGImage) throws -> CGImage {
                        let sheet = LibrarySnapshotPage(document: document, appearance: appearance, headerImage: cardHeader.image,
                            headerHeight: 0, bodyImage: body, bodyHeight: OpenPageSnapshotRenderer.contentHeight, pageBreaks: [],
                            outerImage: snapshotPage.outerImage, innerImage: snapshotPage.innerImage)
                        return try capture(sheet, height: pageHeight, scale: 1)
                    }
                    if let spread = try? OpenPageSnapshots(left: openSheet(bodies.left), right: openSheet(bodies.right)) {
                        openPageImages.setObject(OpenPageSnapshotBox(spread), forKey: key as NSString, cost: spread.cost)
                        failedOpenPages.remove(key)
                    }
                }
            } else {
                let contentOnly = previewStyle == .stickyNote
                let cardPage = LibrarySnapshotPage(document: document, appearance: appearance, headerImage: cardHeader.image,
                    headerHeight: cardHeader.height, bodyImage: body, bodyHeight: bodyHeight, pageBreaks: pageBreaks,
                    outerImage: snapshotPage.outerImage, innerImage: snapshotPage.innerImage, showsPageSurfaces: !contentOnly)
                let cardHeight = min(740, max(480, bodyHeight + cardHeader.height + 40 + (cardHeader.height > 0 ? 18 : 0) + (document.isThemed ? 16 : 0)))
                let cardImage = try capture(cardPage, height: cardHeight)
                remember(cardImage, key: content.cacheKey(for: colorScheme) + Self.snapshotSuffix(for: previewStyle))
            }
        }
        completed = true
        return image
    }

    private func verifyCapture(_ proof: DocumentPreviewCaptureIdentity, in webView: WKWebView, prepare: Bool = false) async throws {
        let matched = try await webView.callAsyncJavaScript("""
            const root = document.querySelector('#editor-root .tiptap-editor, #editor-root .ProseMirror');
            const selector = `[data-vellix-block-id="${proofID}"]`;
            if (!root?.querySelector(selector)) return false;
            if (prepare) {
                document.getElementById('penned-preview-identity-style')?.remove();
                if (hideProbe) {
                    const style = document.createElement('style');
                    style.id = 'penned-preview-identity-style';
                    style.textContent = `${selector} { display:none !important; }`;
                    document.head.appendChild(style);
                }
            }
            return true;
            """, arguments: ["proofID": proof.id, "prepare": prepare, "hideProbe": proof.hasSyntheticBlock],
            in: nil, contentWorld: .page) as? Bool
        try Task.checkCancellation()
        guard matched == true else { throw PreviewError.renderUnavailable }
    }

    private enum PreviewError: Error { case renderUnavailable }
}

private final class PreviewImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private final class OpenPageSnapshotBox {
    let snapshots: OpenPageSnapshots
    let isFinal: Bool
    init(_ snapshots: OpenPageSnapshots, isFinal: Bool = true) { self.snapshots = snapshots; self.isFinal = isFinal }
}

struct LibrarySnapshotPage: View {
    let document: DocumentRecord
    let appearance: DocumentAppearance
    let headerImage: CGImage
    let headerHeight: CGFloat
    let bodyImage: CGImage
    let bodyHeight: CGFloat
    let pageBreaks: [PreviewPageBreak]
    let outerImage: CGImage?
    let innerImage: CGImage?
    var showsPageSurfaces = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if showsPageSurfaces {
                    LibrarySnapshotSurface(
                        style: appearance.editorBackground,
                        photo: document.isThemed ? outerImage : nil)
                    if let theme = document.appearance.editorBackground.patternTheme(for: document.appearance.themeID) {
                        ThemePatternOverlay(theme: theme)
                            .opacity(document.appearance.editorBackground.effect == .faded ? 0.35 : 1)
                    }
                }
                let inset: CGFloat = document.isThemed ? 8 : 0
                let height = geometry.size.height - inset * 2
                let segments = PreviewPageBreak.segments(pageBreaks, bodyY: 20 + headerHeight + (headerHeight > 0 ? 18 : 0), totalHeight: height)
                ZStack(alignment: .topLeading) {
                    if showsPageSurfaces {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            Group {
                                if document.isThemed {
                                    LibrarySnapshotSurface(style: appearance.innerPageBackground, photo: innerImage)
                                } else {
                                    // Match the editor's plain sheets, including documents with legacy black backgrounds.
                                    ZStack {
                                        LibrarySnapshotSurface(style: appearance.editorBackground, photo: nil)
                                        if appearance.presentationColorScheme == .dark { Color.black.opacity(0.30) }
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
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        if headerHeight > 0 {
                            Image(decorative: headerImage, scale: 2).resizable().frame(width: 320, height: headerHeight)
                        }
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
    var appearance: DocumentAppearance? = nil
    var titleLineLimit: Int? = 2
    var showsTitle = true

    var body: some View {
        let appearance = appearance ?? document.appearance
        VStack(alignment: .leading, spacing: 18) {
            if document.appearance.displaysCover {
                Group {
                    if let cover { Image(decorative: cover, scale: 1).resizable().scaledToFill() }
                    else { ThemeCoverArt(theme: document.appearance.resolvedCoverTheme) }
                }
                .frame(width: 320, height: 180).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
            }
            if showsTitle {
                HStack(spacing: 8) {
                    if document.dailyNoteDate != nil { LibraryIcon(name: "mooncal", size: 20) }
                    Text(document.title)
                }
                    .font(appearance.fontStyle.font(size: 24, weight: .black))
                    .foregroundStyle(Color(vellixHex: appearance.textColorHex))
                    .lineLimit(titleLineLimit).fixedSize(horizontal: false, vertical: titleLineLimit == nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Color(vellixHex: appearance.textColorHex).opacity(0.13)).frame(height: 1)
            }
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
