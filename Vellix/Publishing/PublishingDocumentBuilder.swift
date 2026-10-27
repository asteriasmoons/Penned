import Foundation
import CryptoKit
import GRDB
import ImageIO

nonisolated struct PreparedPublication: Sendable {
    var sourceLibraryID: String
    var sourceDocumentID: String
    var document: PublishingDocument
    var files: [String: Data]
    var containsPrivateReferences: Bool
    var containsPrivateCollections: Bool
}

final class PublishingDocumentBuilder {
    private let database: AppDatabase
    private let store: AttachmentStore

    init(database: AppDatabase, attachmentStore: AttachmentStore) {
        self.database = database
        self.store = attachmentStore
    }

    func prepare(documentID: String, owner: AccountIdentity, authorAvatarData: Data? = nil, includeLinkedPages: Bool = false) throws -> PreparedPublication {
        var result = try prepareSingle(documentID: documentID, owner: owner, authorAvatarData: authorAvatarData)
        guard includeLinkedPages else { return result }
        let repository = DocumentRepository(database: database)
        var prepared = [documentID: result], records = [documentID: try repository.requireDocument(id: documentID)]
        var pending = [documentID], index = 0
        func descendant(_ record: DocumentRecord) throws -> Bool {
            var parent = record.parentDocumentID, visited = Set<String>()
            while let id = parent, visited.insert(id).inserted {
                if id == documentID { return true }
                guard let ancestor = try repository.document(id: id), !ancestor.isTrashed, !ancestor.isArchived else { return false }
                parent = ancestor.parentDocumentID
            }
            return false
        }
        while index < pending.count {
            let id = pending[index]; index += 1
            for target in Self.linkedDocumentIDs(prepared[id]!.document.content).sorted() where prepared[target] == nil {
                let record = try repository.requireDocument(id: target)
                guard try descendant(record) else { continue }
                guard pending.count < 1001 else { throw PublishingFailure.invalidContent("A publication supports up to 1,000 linked child pages.") }
                prepared[target] = try prepareSingle(documentID: target, owner: owner, onlyVisibleEntryFields: true)
                records[target] = record; pending.append(target)
            }
        }
        let keys = Dictionary(uniqueKeysWithValues: pending.map { id in
            (id, id == documentID ? "root" : "page-" + SHA256.hash(data: Data((documentID + "|" + id).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined())
        })
        result.document.content = Self.linkTargets(result.document.content, keys: keys)
        var assets = Dictionary(uniqueKeysWithValues: result.document.media.map { ($0.id, $0) })
        result.document.linkedPages = pending.dropFirst().sorted().map { id in
            let child = prepared[id]!
            var document = child.document
            document.content = Self.linkTargets(document.content, keys: keys)
            for asset in document.media { assets[asset.id] = asset }
            result.files.merge(child.files) { existing, _ in existing }
            return PublishingLinkedPage(key: keys[id]!, parentKey: records[id]!.parentDocumentID.flatMap { keys[$0] } ?? "root", document: document)
        }
        result.document.media = assets.values.sorted { $0.id < $1.id }
        guard assets.count <= 200, result.files.values.reduce(0, { $0 + $1.count }) <= 64 * 1024 * 1024 else {
            throw PublishingFailure.invalidContent("The published document and its child pages exceed the publication's media limit.")
        }
        guard try JSONEncoder().encode(result.document).count <= 15 * 1024 * 1024 else {
            throw PublishingFailure.invalidContent("The published document and its child pages exceed the 15 MB content limit.")
        }
        return result
    }

    private static func linkedDocumentIDs(_ content: PublishingJSON) -> Set<String> {
        switch content {
        case .object(let values):
            var result = Set<String>()
            if case .string(let id) = values["targetDocumentID"] { result.insert(id) }
            for value in values.values { result.formUnion(linkedDocumentIDs(value)) }
            return result
        case .array(let values): return values.reduce(into: Set<String>()) { $0.formUnion(linkedDocumentIDs($1)) }
        default: return []
        }
    }

    private static func linkTargets(_ value: PublishingJSON, keys: [String: String]) -> PublishingJSON {
        switch value {
        case .object(let values):
            var result = values.mapValues { linkTargets($0, keys: keys) }
            if case .string(let id) = result["targetDocumentID"], let key = keys[id] {
                result.removeValue(forKey: "targetDocumentID"); result["targetPage"] = .string(key)
            }
            return .object(result)
        case .array(let values): return .array(values.map { linkTargets($0, keys: keys) })
        default: return value
        }
    }

    private func prepareSingle(documentID: String, owner: AccountIdentity, authorAvatarData: Data? = nil, onlyVisibleEntryFields: Bool = false) throws -> PreparedPublication {
        guard database.libraryID != "*", let library = try LibraryRepository(database: database).library(id: database.libraryID),
              library.ownerKey == owner.libraryOwnerKey || (library.id == LibraryRecord.localID && library.ownerKey == nil) else { throw LibraryError.wrongOwner }
        let repository = DocumentRepository(database: database)
        let record = try repository.requireDocument(id: documentID)
        guard !record.isTrashed, !record.isArchived, record.templateID == nil else { throw PublishingFailure.invalidContent("Open an active document to publish it.") }
        guard record.tipTapJSON.utf8.count <= 2 * 1024 * 1024 else { throw PublishingFailure.invalidContent("The document exceeds the 2 MB publication limit.") }
        guard let root = try JSONSerialization.jsonObject(with: Data(record.tipTapJSON.utf8)) as? [String: Any], root["type"] as? String == "doc" else {
            throw PublishingFailure.invalidContent("Invalid document content.")
        }
        let visible = try PublishingVisibleContent.prepare(root, document: record, repository: repository,
            collections: CollectionRepository(database: database, documents: repository), onlyVisibleEntryFields: onlyVisibleEntryFields)
        let appearance = try repository.effectiveAppearance(for: record)
        guard var appearanceObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(appearance)) as? [String: Any] else { throw PublishingFailure.invalidContent("Invalid document appearance.") }
        appearanceObject.removeValue(forKey: "customizedFields")
        var paths = PublishingProjection.paths(in: root)
        // Only these two public atom payloads may contribute preview assets.
        func visiblePaths(_ node: [String: Any]) -> Set<String> {
            if ["publishedPage", "publishedCollection"].contains(node["type"] as? String ?? "") { return PublishingVisibleContent.paths(node["attrs"] ?? [:]) }
            return (node["content"] as? [[String: Any]] ?? []).reduce(into: Set<String>()) { $0.formUnion(visiblePaths($1)) }
        }
        paths.formUnion(visiblePaths(visible))
        if let path = record.cover { paths.insert(path) }
        for key in ["editorBackground", "innerPageBackground"] {
            if let background = appearanceObject[key] as? [String: Any], let path = background["imagePath"] as? String { paths.insert(path) }
        }
        guard paths.count <= 200 else { throw PublishingFailure.invalidContent("A publication supports up to 200 media files.") }
        var mediaByPath: [String: PublishingMedia] = [:], files: [String: Data] = [:]
        for path in paths.sorted() {
            let attachment = try database.read { db in
                try AttachmentRecord.fetchOne(db, sql: "SELECT a.* FROM attachments a JOIN documents d ON d.id=a.documentID JOIN spaces s ON s.id=d.spaceID WHERE s.libraryID=? AND (a.relativePath=? OR a.thumbnailRelativePath=?)", arguments: [database.libraryID, path, path])
            }
            guard let attachment else { throw PublishingFailure.invalidContent("Referenced media does not belong to this library.") }
            let url = try store.validatedFileURL(relativePath: path)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size <= 16 * 1024 * 1024 else { throw PublishingFailure.invalidContent("Each published media file must be between 1 byte and 16 MB.") }
            let bytes = try Data(contentsOf: url)
            guard bytes.count == size else { throw PublishingFailure.invalidContent("A media file changed while preparing this publication. Try again.") }
            guard files.values.reduce(0, { $0 + $1.count }) + bytes.count <= 64 * 1024 * 1024 else { throw PublishingFailure.invalidContent("A publication supports up to 64 MB of referenced media.") }
            let inspected = AttachmentMedia.inspect(url: url, mimeType: path == attachment.relativePath ? attachment.mimeType : nil)
            let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let name = path == attachment.relativePath ? attachment.originalFileName : url.lastPathComponent
            let identifier = SHA256.hash(data: Data((database.libraryID + "|" + record.id + "|" + path + "|" + sha256 + "|" + name + "|" + inspected.mimeType).utf8)).map { String(format: "%02x", $0) }.joined()
            let segments = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in String(identifier.dropFirst(range.lowerBound).prefix(range.count)) }
            let asset = PublishingMedia(id: segments.joined(separator: "-"), name: path == attachment.relativePath ? attachment.originalFileName : url.lastPathComponent,
                mimeType: inspected.mimeType, size: bytes.count, sha256: sha256)
            mediaByPath[path] = asset
            files[asset.id] = bytes
        }
        for key in ["editorBackground", "innerPageBackground"] {
            if var background = appearanceObject[key] as? [String: Any], let path = background.removeValue(forKey: "imagePath") as? String {
                background["mediaID"] = mediaByPath[path]?.id
                appearanceObject[key] = background
            }
        }
        let projected = try PublishingProjection.content(visible, media: mediaByPath)
        let content = try PublishingJSON.decode(projected)
        var document = PublishingDocument(title: record.title, subtitle: record.subtitle, icon: record.icon,
            cover: record.cover.flatMap { mediaByPath[$0] }.map { .object(["mediaID": .string($0.id)]) },
            appearance: try .decode(appearanceObject), content: content, media: mediaByPath.values.sorted { $0.id < $1.id })
        if let authorAvatarData {
            let bytes = try Self.avatarImage(authorAvatarData)
            guard document.media.count < 200, files.values.reduce(0, { $0 + $1.count }) + bytes.count <= 64 * 1024 * 1024 else {
                throw PublishingFailure.invalidContent("The author image exceeds this publication's media limit.")
            }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let identifier = SHA256.hash(data: Data((owner.libraryOwnerKey + "|" + database.libraryID + "|" + record.id + "|author-avatar|" + digest).utf8)).map { String(format: "%02x", $0) }.joined()
            let id = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(identifier.dropFirst($0.lowerBound).prefix($0.count)) }.joined(separator: "-")
            document.authorAvatar = .object(["mediaID": .string(id)])
            document.media.append(PublishingMedia(id: id, name: "author-avatar.png", mimeType: "image/png", size: bytes.count, sha256: digest))
            document.media.sort { $0.id < $1.id }; files[id] = bytes
        }
        let encoded = try JSONEncoder().encode(content)
        return PreparedPublication(sourceLibraryID: database.libraryID, sourceDocumentID: record.id, document: document, files: files,
            containsPrivateReferences: encoded.range(of: Data("privateReference".utf8)) != nil,
            containsPrivateCollections: encoded.range(of: Data("privateCollection".utf8)) != nil)
    }

    private static func avatarImage(_ data: Data) throws -> Data {
        guard data.count <= 5 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) else {
            throw PublishingFailure.invalidContent("The author image could not be prepared.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw PublishingFailure.invalidContent("The author image could not be prepared.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PublishingFailure.invalidContent("The author image could not be prepared.") }
        return output as Data
    }
}
