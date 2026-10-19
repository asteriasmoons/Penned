//
//  AttachmentStore.swift
//  Vellix
//

import Foundation
import UniformTypeIdentifiers
import GRDB

final class AttachmentStore: @unchecked Sendable {
    private let rootURL: URL
    nonisolated var syncDirectory: URL { rootURL.appendingPathComponent(".cloudkit-sync", isDirectory: true) }

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static func liveStore() throws -> AttachmentStore {
        let support = try AppDatabase.applicationSupportDirectory()
        let attachments = support.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: attachments,
            withIntermediateDirectories: true
        )
        return AttachmentStore(rootURL: attachments)
    }

    static func previewStore() -> AttachmentStore {
        AttachmentStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("VellixPreviewAttachments", isDirectory: true)
        )
    }

    nonisolated func importFile(at sourceURL: URL, documentID: String) throws -> AttachmentRecord {
        let fileManager = FileManager.default
        let sourceValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
            throw VellixError.attachmentImport("Select a regular file, not a folder or alias.")
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let originalName = sourceURL.lastPathComponent
        let safeName = Self.safeFileName(originalName)
        let storedName = "\(UUID().uuidString)-\(safeName)"
        let destination = rootURL.appendingPathComponent(storedName)
        var succeeded = false
        defer { if !succeeded { try? fileManager.removeItem(at: destination) } }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)

        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let media = AttachmentMedia.inspect(url: destination)
        succeeded = true
        return AttachmentRecord(
            id: UUID().uuidString,
            documentID: documentID,
            originalFileName: originalName,
            storedFileName: storedName,
            relativePath: storedName,
            mimeType: media.mimeType,
            uti: media.uti,
            fileSize: size,
            thumbnailRelativePath: nil,
            createdAt: Date()
        )
    }

    nonisolated func importData(
        _ data: Data,
        originalFileName: String,
        mimeType: String?,
        documentID: String
    ) throws -> AttachmentRecord {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let safeName = Self.safeFileName(originalFileName)
        let storedName = "\(UUID().uuidString)-\(safeName)"
        let destination = rootURL.appendingPathComponent(storedName)
        try data.write(to: destination, options: [.atomic])

        let media = AttachmentMedia.inspect(url: destination, mimeType: mimeType)
        return AttachmentRecord(
            id: UUID().uuidString,
            documentID: documentID,
            originalFileName: originalFileName,
            storedFileName: storedName,
            relativePath: storedName,
            mimeType: media.mimeType,
            uti: media.uti,
            fileSize: Int64(data.count),
            thumbnailRelativePath: nil,
            createdAt: Date()
        )
    }

    nonisolated func fileURL(relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    nonisolated func removeFile(relativePath: String) throws {
        let url = try validatedFileURL(relativePath: relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Attachment" : cleaned
    }
}

final class AttachmentRepository: @unchecked Sendable {
    private let database: AppDatabase
    var spaceID: String?
    private let store: AttachmentStore

    init(database: AppDatabase, store: AttachmentStore) {
        self.database = database
        self.store = store
    }

    func importFile(at sourceURL: URL, documentID: String) throws -> AttachmentRecord {
        _ = try database.read { try SpaceOwnership.document(documentID, scope: spaceID, in: $0) }
        let record = try store.importFile(at: sourceURL, documentID: documentID)
        do { try database.write { db in
            _ = try SpaceOwnership.document(documentID, scope: spaceID, in: db)
            try record.insert(db)
        } } catch { try? store.removeFile(relativePath: record.relativePath); throw error }
        return record
    }

    func importData(
        _ data: Data,
        originalFileName: String,
        mimeType: String?,
        documentID: String
    ) throws -> AttachmentRecord {
        _ = try database.read { try SpaceOwnership.document(documentID, scope: spaceID, in: $0) }
        let record = try store.importData(
            data,
            originalFileName: originalFileName,
            mimeType: mimeType,
            documentID: documentID
        )
        do { try database.write { db in
            _ = try SpaceOwnership.document(documentID, scope: spaceID, in: db)
            try record.insert(db)
        } } catch { try? store.removeFile(relativePath: record.relativePath); throw error }
        return record
    }

    func attachments(for documentID: String) throws -> [AttachmentRecord] {
        try database.read { db in
            _ = try SpaceOwnership.document(documentID, scope: spaceID, in: db)
            return try AttachmentRecord.fetchAll(
                db,
                sql: "SELECT * FROM attachments WHERE documentID = ? ORDER BY createdAt DESC",
                arguments: [documentID]
            )
        }
    }

    func registerImported(_ records: [AttachmentRecord], documentID: String) throws {
        try database.write { db in
            _ = try SpaceOwnership.document(documentID, scope: spaceID, in: db)
            for record in records {
                guard record.documentID == documentID else { throw VellixError.attachmentImport("The attachment owner changed.") }
                try record.insert(db)
            }
        }
    }

    func editorAttachment(relativePath: String) throws -> EditorAttachment? {
        guard let spaceID, AttachmentStore.validRelativePath(relativePath) else { return nil }
        guard let record = try database.read({ db in
            try AttachmentRecord.fetchOne(db, sql: "SELECT a.* FROM attachments a JOIN documents d ON d.id=a.documentID WHERE \(LibraryAccess.spaces("d.spaceID")) AND a.relativePath=? AND d.spaceID=?", arguments: [relativePath, spaceID])
        }) else { return nil }
        let url = try store.validatedFileURL(relativePath: record.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return EditorAttachment(record: record, media: AttachmentMedia.inspect(url: url, mimeType: record.mimeType))
    }

    func delete(id: String) throws {
        try database.write { db in
            guard let record = try AttachmentRecord.fetchOne(db, key: id) else {
                return
            }
            _ = try SpaceOwnership.document(record.documentID, scope: spaceID, in: db)
            for path in record.storedPaths { try db.execute(sql: "INSERT OR IGNORE INTO attachmentCleanup(relativePath) VALUES (?)", arguments: [path]) }
            try db.execute(sql: "DELETE FROM attachments WHERE id = ?", arguments: [id])
        }
        try? SpaceRepository(database: database).drainAttachmentCleanup(store: store)
    }

    static func prepareDocumentDeletion(_ ids: Set<String>, in db: Database) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            let assets = try AttachmentRecord.fetchAll(db, sql: "SELECT * FROM attachments WHERE documentID=?", arguments: [id])
            for var asset in assets {
                // Blocks can be copied/moved between pages without copying their original bytes.
                let candidates = try DocumentRecord.fetchAll(db, sql: """
                    SELECT d.* FROM documents d WHERE d.spaceID=(SELECT spaceID FROM documents WHERE id=?)
                    AND (instr(d.tipTapJSON,?)>0 OR EXISTS(SELECT 1 FROM documentSnapshots s WHERE s.documentID=d.id AND instr(s.tipTapJSON,?)>0))
                    ORDER BY d.createdAt,d.id
                    """, arguments: [id, asset.relativePath, asset.relativePath])
                if let survivor = candidates.first(where: { !ids.contains($0.id) }) {
                    asset.documentID = survivor.id
                    try asset.update(db)
                } else {
                    for path in [asset.relativePath, asset.thumbnailRelativePath].compactMap({ $0 }) {
                        try db.execute(sql: "INSERT OR IGNORE INTO attachmentCleanup(relativePath) VALUES (?)", arguments: [path])
                    }
                }
            }
        }
    }
}
