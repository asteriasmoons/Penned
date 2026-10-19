import Foundation
import CoreGraphics
import ImageIO
import Testing
import GRDB
@testable import Vellix

@MainActor
struct AttachmentTests {
    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 40, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let image = try #require(context.makeImage()), data = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil); #expect(CGImageDestinationFinalize(output))
        return data as Data
    }
    @MainActor private struct Fixture {
        let db: AppDatabase
        let documents: DocumentRepository
        let store: AttachmentStore
        let attachments: AttachmentRepository
        let root: URL
        let space: String
        init() throws {
            db = try .makeInMemory(); documents = DocumentRepository(database: db)
            space = try SpaceRepository(database: db).fallback(preferred: nil); documents.spaceID = space
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            store = AttachmentStore(rootURL: root); attachments = documents.attachmentRepository(store: store)
        }
    }
    private func json(_ record: AttachmentRecord, store: AttachmentStore, mode: String = "inline") throws -> String {
        let file = EditorAttachment(record: record, media: AttachmentMedia.inspect(url: store.fileURL(relativePath: record.relativePath)))
        return try TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "attachment", "attrs": ["id": "file-block", "file": file.object,
            "displayMode": mode, "widthPercent": 55, "textAlign": "right"]]])
    }

    @Test func actualImageBytesWinOverExtensionAndClaimedMIMEWithoutLosingAlpha() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let doc = try f.documents.create(DocumentDraft()), original = try png()
        let asset = try f.attachments.importData(original, originalFileName: "Divider.txt", mimeType: "text/plain", documentID: doc.id)
        #expect(asset.mimeType == "image/png")
        #expect(try Data(contentsOf: f.store.fileURL(relativePath: asset.relativePath)) == original)
        let metadata = AttachmentMedia.inspect(url: f.store.fileURL(relativePath: asset.relativePath))
        #expect(metadata.kind == .image && metadata.width == 40 && metadata.height == 10)
        #expect(metadata.typeLabel(fileName: "Divider.txt") == "PNG")
        let preview = try f.store.previewPNG(relativePath: asset.relativePath)
        let source = try #require(CGImageSourceCreateWithData(preview as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.alphaInfo != .none && image.alphaInfo != .noneSkipFirst && image.alphaInfo != .noneSkipLast)
        let pixels = try #require(CGContext(data: nil, width: 40, height: 10, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 10))
        let rgba = try #require(pixels.data?.assumingMemoryBound(to: UInt8.self))
        #expect(rgba[5 * 160 + 30 * 4 + 3] == 0)
        #expect(rgba[5 * 160 + 10 * 4 + 3] == 255)
        let fake = try f.attachments.importData(Data("not an image".utf8), originalFileName: "fake.png", mimeType: "image/png", documentID: doc.id)
        #expect(AttachmentMedia.inspect(url: f.store.fileURL(relativePath: fake.relativePath)).kind == .file)
    }

    @Test func safeSVGAndOriginalAnimatedGIFAreRecognizedAndPreserved() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let doc = try f.documents.create(DocumentDraft())
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="400" height="30"><circle cx="15" cy="15" r="10" fill="red"/></svg>"#.utf8)
        let safe = try f.attachments.importData(svg, originalFileName: "divider.svg", mimeType: nil, documentID: doc.id)
        #expect(safe.mimeType == "image/svg+xml")
        let unsafe = try f.attachments.importData(Data(#"<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"><script/></svg>"#.utf8), originalFileName: "unsafe.svg", mimeType: nil, documentID: doc.id)
        #expect(unsafe.mimeType == "application/octet-stream")
        let pngSource = try #require(CGImageSourceCreateWithData(png() as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(pngSource, 0, nil)), gif = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(gif, "com.compuserve.gif" as CFString, 2, nil))
        for _ in 0..<2 { CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary) }
        #expect(CGImageDestinationFinalize(destination))
        let animated = try f.attachments.importData(gif as Data, originalFileName: "animated.gif", mimeType: nil, documentID: doc.id)
        #expect(animated.mimeType == "image/gif")
        #expect(try Data(contentsOf: f.store.fileURL(relativePath: animated.relativePath)) == gif as Data)
        let source = try #require(CGImageSourceCreateWithURL(f.store.fileURL(relativePath: animated.relativePath) as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 2)
    }

    @Test func streamingRangesAndUnsafePathsAreHandledDeterministically() throws {
        #expect(try AttachmentByteRange.parse(nil, size: 100) == nil)
        #expect(try AttachmentByteRange.parse("bytes=0-1", size: 100) == AttachmentByteRange(start: 0, end: 1))
        #expect(try AttachmentByteRange.parse("bytes=50-", size: 100)?.count == 50)
        #expect(try AttachmentByteRange.parse("bytes=-10", size: 100) == AttachmentByteRange(start: 90, end: 99))
        #expect(try AttachmentByteRange.parse("bytes=90-200", size: 100)?.end == 99)
        for header in ["bytes=100-", "bytes=-0", "bytes=2-1", "bytes=0-1,5-6", "bytes=nope", "bytes=9223372036854775808-"] {
            #expect(throws: (any Error).self) { try AttachmentByteRange.parse(header, size: 100) }
        }
        for path in ["", ".", "..", "../secret", "/etc/passwd", "folder\\file", "bad\0file"] { #expect(!AttachmentStore.validRelativePath(path)) }
        #expect(AttachmentStore.validRelativePath("safe-file.png"))
    }

    @Test func renderingAttributesAndMetadataSurviveDatabaseReopeningAndIndependentDuplication() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let doc = try f.documents.create(DocumentDraft(title: "Original"))
        let child = try f.documents.create(DocumentDraft(title: "Child", parentDocumentID: doc.id))
        let asset = try f.attachments.importData(png(), originalFileName: "Divider.png", mimeType: nil, documentID: child.id)
        let content = try json(asset, store: f.store)
        #expect(try TipTapContentAnalyzer.analyze(content).previewText == "Divider.png")
        #expect(try !TipTapContentAnalyzer.analyze(content).isEffectivelyEmpty)
        _ = try f.documents.saveEditorJSON(id: child.id, canonicalJSON: content)
        let reopened = DocumentRepository(database: f.db); reopened.spaceID = f.space
        #expect(EditorAttachment.paths(in: try reopened.requireDocument(id: child.id).tipTapJSON) == [asset.relativePath])
        let copy = try f.documents.duplicate(id: doc.id, attachmentStore: f.store)
        let copiedChild = try #require(f.documents.children(of: copy.id).first)
        let files = try f.documents.editorAttachments(documentID: copiedChild.id, json: copiedChild.tipTapJSON, store: f.store)
        let copied = try #require(files.first)
        #expect(copied.record.id != asset.id && copied.record.relativePath != asset.relativePath)
        #expect(copied.record.originalFileName == "Divider.png")
        #expect(copiedChild.tipTapJSON.contains(copied.record.id) && !copiedChild.tipTapJSON.contains(asset.id))
        let attrs = try #require((TipTapContentAnalyzer.documentObject(from: copiedChild.tipTapJSON)["content"] as? [[String: Any]])?.first?["attrs"] as? [String: Any])
        #expect(attrs["widthPercent"] as? Int == 55 && attrs["textAlign"] as? String == "right")
        #expect(try Data(contentsOf: f.store.fileURL(relativePath: copied.record.relativePath)) == png())
        let violations = try f.db.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }
        #expect(violations.isEmpty)
    }

    @Test func spaceCopyMoveTrashAndPermanentDeletionKeepFilesIsolatedAndRecoverable() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let doc = try f.documents.create(DocumentDraft(title: "Original"))
        let asset = try f.attachments.importData(png(), originalFileName: "Divider.png", mimeType: nil, documentID: doc.id)
        _ = try f.documents.saveEditorJSON(id: doc.id, canonicalJSON: json(asset, store: f.store))
        let spaces = SpaceRepository(database: f.db), other = try spaces.create(title: "Other").id
        f.documents.spaceID = other
        let foreign = try f.documents.create(DocumentDraft(tipTapJSON: json(asset, store: f.store)))
        #expect(try f.documents.editorAttachments(documentID: foreign.id, json: foreign.tipTapJSON, store: f.store).isEmpty)
        #expect(try f.documents.attachmentRepository(store: f.store).editorAttachment(relativePath: asset.relativePath) == nil)
        try spaces.transfer(.document(doc.id), from: f.space, to: other, copy: true, store: f.store)
        let copy = try #require(f.documents.allDocuments().first { $0.id != foreign.id })
        let copied = try #require(f.documents.editorAttachments(documentID: copy.id, json: copy.tipTapJSON, store: f.store).first)
        #expect(copied.id != asset.id && copied.record.originalFileName == asset.originalFileName)
        _ = try f.documents.trash(id: copy.id)
        _ = try f.documents.restore(id: copy.id)
        #expect(try f.documents.requireDocument(id: copy.id).tipTapJSON.contains(copied.id))
        try f.documents.permanentlyDelete(id: copy.id, attachmentStore: f.store)
        #expect(!FileManager.default.fileExists(atPath: f.store.fileURL(relativePath: copied.record.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: f.store.fileURL(relativePath: asset.relativePath).path))
        try spaces.transfer(.document(doc.id), from: f.space, to: other, copy: false, store: f.store)
        #expect(try f.documents.editorAttachments(documentID: doc.id, json: f.documents.requireDocument(id: doc.id).tipTapJSON, store: f.store).first?.id == asset.id)
    }

    @Test func deletingTheOriginalPageRetainsAnAttachmentUsedByAnotherPage() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try f.documents.create(DocumentDraft()), survivor = try f.documents.create(DocumentDraft())
        let asset = try f.attachments.importData(png(), originalFileName: "Divider.png", mimeType: nil, documentID: original.id)
        let content = try json(asset, store: f.store)
        _ = try f.documents.saveEditorJSON(id: survivor.id, canonicalJSON: content)
        _ = try f.documents.trash(id: original.id)
        #expect(try f.documents.editorAttachments(documentID: survivor.id, json: content, store: f.store).first?.id == asset.id)
        try f.documents.permanentlyDelete(id: original.id, attachmentStore: f.store)
        let resolved = try #require(f.documents.editorAttachments(documentID: survivor.id, json: content, store: f.store).first)
        #expect(resolved.id == asset.id && resolved.record.documentID == survivor.id)
        #expect(FileManager.default.fileExists(atPath: f.store.fileURL(relativePath: asset.relativePath).path))
    }

    @Test func templateInstantiationAndDailyNotesCopyFilesAndLayoutIndependently() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let templates = TemplateRepository(database: f.db); templates.spaceID = f.space
        let root = try templates.create(title: "Daily Divider")
        let asset = try f.attachments.importData(png(), originalFileName: "Rainbow.png", mimeType: nil, documentID: root.id)
        _ = try f.documents.saveEditorJSON(id: root.id, canonicalJSON: json(asset, store: f.store))
        let id = try #require(root.templateID)
        let normal = try templates.instantiate(id: id, title: "Ordinary", spaceID: f.space, folderID: nil, parentID: nil, attachmentStore: f.store)
        let daily = DailyNoteRepository(database: f.db, templates: templates); daily.spaceID = f.space
        try daily.setDefaultTemplate(id)
        let one = try daily.createOrFind(day: #require(DailyNoteDay(key: "2026-10-16")), attachmentStore: f.store)
        let two = try daily.createOrFind(day: #require(DailyNoteDay(key: "2026-10-17")), attachmentStore: f.store)
        var paths = Set([asset.relativePath]), ids = Set([asset.id])
        for document in [normal, one, two] {
            let copy = try #require(f.documents.editorAttachments(documentID: document.id, json: document.tipTapJSON, store: f.store).first)
            paths.insert(copy.record.relativePath); ids.insert(copy.id)
            #expect(document.tipTapJSON.contains("widthPercent") && document.tipTapJSON.contains("right"))
        }
        #expect(paths.count == 4 && ids.count == 4)
        try templates.delete(id: id, attachmentStore: f.store)
        for document in [normal, one, two] {
            let copy = try #require(f.documents.editorAttachments(documentID: document.id, json: document.tipTapJSON, store: f.store).first)
            #expect(FileManager.default.fileExists(atPath: f.store.fileURL(relativePath: copy.record.relativePath).path))
        }
    }

    @Test func pdfPreviewIsDerivedAndBoundedWithoutChangingTheOriginal() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let data = NSMutableData(), consumer = try #require(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 1200, height: 1600)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 10, y: 20, width: 80, height: 40)); context.endPDFPage(); context.closePDF()
        let doc = try f.documents.create(DocumentDraft())
        let file = try f.attachments.importData(data as Data, originalFileName: "Instructions.bin", mimeType: "text/plain", documentID: doc.id)
        #expect(file.mimeType == "application/pdf")
        let png = try f.store.previewPNG(relativePath: file.relativePath, pdf: true)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width <= 800 && image.height <= 600)
        #expect(try Data(contentsOf: f.store.fileURL(relativePath: file.relativePath)) == data as Data)
    }

    @Test func derivedThumbnailsAreCopiedAndDeletedWithTheirOwnerWithoutTouchingTheOriginal() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try f.documents.create(DocumentDraft())
        var asset = try f.attachments.importData(png(), originalFileName: "Image.png", mimeType: nil, documentID: document.id)
        let thumbnail = try f.store.importData(png(), originalFileName: "Preview.png", mimeType: nil, documentID: document.id)
        asset.thumbnailRelativePath = thumbnail.relativePath
        try f.db.write { try asset.update($0) }
        _ = try f.documents.saveEditorJSON(id: document.id, canonicalJSON: json(asset, store: f.store))
        let copy = try f.documents.duplicate(id: document.id, attachmentStore: f.store)
        let copied = try #require(f.documents.editorAttachments(documentID: copy.id, json: copy.tipTapJSON, store: f.store).first)
        let path = try #require(copied.record.thumbnailRelativePath)
        #expect(path != thumbnail.relativePath && copy.tipTapJSON.contains(path))
        try f.documents.permanentlyDelete(id: copy.id, attachmentStore: f.store)
        #expect(!FileManager.default.fileExists(atPath: f.store.fileURL(relativePath: path).path))
        #expect(FileManager.default.fileExists(atPath: f.store.fileURL(relativePath: thumbnail.relativePath).path))
    }

    @Test func mediaHeadersWinOverMisleadingNames() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try f.documents.create(DocumentDraft())
        for (data, kind, mime) in [(Data("ID3music".utf8), AttachmentKind.audio, "audio/mpeg"),
            (Data([0, 0, 0, 24] + Array("ftypisom".utf8)), .video, "video/mp4"),
            (Data("RIFFxxxxWAVE".utf8), .audio, "audio/wav")] {
            let record = try f.attachments.importData(data, originalFileName: "unknown.txt", mimeType: "text/plain", documentID: document.id)
            #expect(record.mimeType == mime)
            #expect(AttachmentMedia.inspect(url: f.store.fileURL(relativePath: record.relativePath)).kind == kind)
        }
    }

    @Test func attachmentIdentityBytesAndLayoutSurviveClosingAndReopeningSQLite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(rootURL: root.appendingPathComponent("Files")), path = root.appendingPathComponent("Notes.sqlite").path
        let id: String, owner: String, assetID: String, filePath: String, savedJSON: String
        do {
            let db = try AppDatabase(DatabaseQueue(path: path)), documents = DocumentRepository(database: db)
            owner = try SpaceRepository(database: db).fallback(preferred: nil); documents.spaceID = owner
            let document = try documents.create(DocumentDraft(title: "Saved file")); id = document.id
            let file = try documents.attachmentRepository(store: store).importData(png(), originalFileName: "Divider.png", mimeType: nil, documentID: id)
            assetID = file.id; filePath = file.relativePath
            savedJSON = try documents.saveEditorJSON(id: id, canonicalJSON: json(file, store: store)).tipTapJSON
        }
        let reopened = try AppDatabase(DatabaseQueue(path: path)), documents = DocumentRepository(database: reopened); documents.spaceID = owner
        let document = try documents.requireDocument(id: id)
        #expect(document.tipTapJSON == savedJSON)
        let file = try #require(documents.editorAttachments(documentID: id, json: document.tipTapJSON, store: store).first)
        #expect(file.id == assetID && file.record.relativePath == filePath && file.media.kind == .image)
        #expect(try Data(contentsOf: store.fileURL(relativePath: filePath)) == png())
    }
}
