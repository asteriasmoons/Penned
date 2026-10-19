import Foundation
import CryptoKit
import GRDB
import ImageIO
import UniformTypeIdentifiers

struct DocumentStyleDefinition: Codable, Equatable {
    var appearance: DocumentAppearance
    var cover: String?

    var imagePaths: [String] {
        Array(Set([cover, appearance.editorBackground.imagePath,
                   appearance.innerPageBackground.imagePath].compactMap { $0 }))
    }

    mutating func replaceImages(_ paths: [String: String]) {
        if let path = cover { cover = paths[path] ?? path }
        if let path = appearance.editorBackground.imagePath {
            appearance.editorBackground.imagePath = paths[path] ?? path
        }
        if let path = appearance.innerPageBackground.imagePath {
            appearance.innerPageBackground.imagePath = paths[path] ?? path
        }
    }
}

struct SavedDocumentStyle: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "documentStyles"
    var id: String
    var title: String
    var styleJSON: String
    var fingerprint: String
    var createdAt: Date
    var updatedAt: Date
    var libraryID: String = LibraryRecord.localID

    var isBuiltIn: Bool { id.hasPrefix("theme-") }
    func definition() throws -> DocumentStyleDefinition {
        try JSONDecoder().decode(DocumentStyleDefinition.self, from: Data(styleJSON.utf8))
    }
}

// Styles own immutable copies of their images, never document-owned attachment paths.
@MainActor
final class DocumentStyleRepository {
    private let database: AppDatabase
    private let store: AttachmentStore
    private var imageDigests: [String: (signature: String, digest: String)] = [:]

    init(database: AppDatabase, store: AttachmentStore) {
        self.database = database
        self.store = store
    }

    func all() throws -> [SavedDocumentStyle] {
        let saved = try database.read { db in
            try SavedDocumentStyle.fetchAll(db, sql: "SELECT * FROM documentStyles WHERE libraryID=penned_library() ORDER BY createdAt DESC, id")
        }
        let builtIn = try [DocumentThemeID.lunarClouds, .neonCode].map { theme in
            let definition = DocumentStyleDefinition(appearance: .defaultForTheme(theme))
            return SavedDocumentStyle(id: "theme-\(theme.rawValue)", title: theme.title,
                styleJSON: try encode(definition), fingerprint: try fingerprint(definition),
                createdAt: .distantPast, updatedAt: .distantPast)
        }
        return saved + builtIn
    }

    func matchingStyle(_ definition: DocumentStyleDefinition, in styles: [SavedDocumentStyle]) throws -> SavedDocumentStyle? {
        let value = try fingerprint(definition)
        return styles.first { $0.fingerprint == value }
    }

    func fingerprint(_ definition: DocumentStyleDefinition) throws -> String {
        var normalized = definition
        normalized.appearance.showsCover = definition.appearance.displaysCover
        normalized.appearance.coverThemeID = definition.appearance.displaysCover && definition.cover == nil
            ? definition.appearance.resolvedCoverTheme : nil
        for keyPath in [\DocumentAppearance.editorBackground, \DocumentAppearance.innerPageBackground] {
            normalized.appearance[keyPath: keyPath].gradientDirection =
                definition.appearance[keyPath: keyPath].gradientDirection ?? .diagonal
            normalized.appearance[keyPath: keyPath].blurImage = definition.appearance[keyPath: keyPath].blurImage ?? false
            normalized.appearance[keyPath: keyPath].effect = definition.appearance[keyPath: keyPath].effect ?? .immersive
        }
        var hashes: [String: String] = [:]
        for path in normalized.imagePaths {
            let url = store.fileURL(relativePath: path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let signature = "\(attributes[.size] ?? 0)-\(attributes[.modificationDate] ?? Date.distantPast)"
            if let cached = imageDigests[path], cached.signature == signature {
                hashes[path] = cached.digest
            } else {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                imageDigests[path] = (signature, digest)
                hashes[path] = digest
            }
        }
        normalized.replaceImages(hashes)
        let data = try Data(encode(normalized).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func save(title: String, definition: DocumentStyleDefinition) throws -> SavedDocumentStyle {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw VellixError.database("A style needs a name.") }
        let id = UUID().uuidString
        let signature = try fingerprint(definition)
        let (owned, files) = try copyImages(definition, ownerID: id)
        do {
            let now = Date()
            let record = SavedDocumentStyle(id: id, title: name, styleJSON: try encode(owned),
                fingerprint: signature, createdAt: now, updatedAt: now, libraryID: database.libraryID)
            try database.write { db in try record.insert(db) }
            return record
        } catch {
            for file in files { try? store.removeFile(relativePath: file.relativePath) }
            throw error
        }
    }

    func rename(_ style: SavedDocumentStyle, title: String) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isBuiltIn, !name.isEmpty else { return }
        try database.write { db in
            try db.execute(sql: "UPDATE documentStyles SET title = ?, updatedAt = ? WHERE id = ?",
                arguments: [name, Date(), style.id])
        }
    }

    func delete(_ style: SavedDocumentStyle) throws {
        guard !style.isBuiltIn else { return }
        guard style.libraryID == database.libraryID else { throw LibraryError.wrongOwner }
        let paths = try style.definition().imagePaths
        try database.write { db in
            for path in paths { try db.execute(sql: "INSERT OR IGNORE INTO attachmentCleanup(relativePath) VALUES (?)", arguments: [path]) }
            try db.execute(sql: "DELETE FROM documentStyles WHERE id = ?", arguments: [style.id])
        }
        try SpaceRepository(database: database).drainAttachmentCleanup(store: store)
    }

    func apply(_ style: SavedDocumentStyle, to documentID: String) throws -> DocumentStyleDefinition {
        guard style.isBuiltIn || style.libraryID == database.libraryID else { throw LibraryError.wrongOwner }
        let (definition, files) = try copyImages(style.definition(), ownerID: documentID)
        do {
            try database.write { db in
                _ = try SpaceOwnership.document(documentID, scope: nil, in: db)
                for file in files { try file.insert(db) }
            }
            return definition
        } catch {
            for file in files { try? store.removeFile(relativePath: file.relativePath) }
            throw error
        }
    }

    func importImage(_ data: Data, documentID: String) throws -> AttachmentRecord {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0, let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw VellixError.attachmentImport("Choose a supported image smaller than 20 MB.")
        }
        let record = try store.importData(data, originalFileName: "style-image.\(type.preferredFilenameExtension ?? "jpg")",
            mimeType: type.preferredMIMEType, documentID: documentID)
        do {
            try database.write { db in try record.insert(db) }
            return record
        } catch {
            try? store.removeFile(relativePath: record.relativePath)
            throw error
        }
    }

    private func copyImages(_ definition: DocumentStyleDefinition, ownerID: String) throws -> (DocumentStyleDefinition, [AttachmentRecord]) {
        var files: [AttachmentRecord] = []
        var paths: [String: String] = [:]
        do {
            for path in definition.imagePaths {
                let record = try store.importFile(at: store.fileURL(relativePath: path), documentID: ownerID)
                files.append(record)
                paths[path] = record.relativePath
            }
            var copy = definition
            copy.replaceImages(paths)
            return (copy, files)
        } catch {
            for file in files { try? store.removeFile(relativePath: file.relativePath) }
            throw error
        }
    }

    private func encode(_ definition: DocumentStyleDefinition) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(definition), as: UTF8.self)
    }
}
