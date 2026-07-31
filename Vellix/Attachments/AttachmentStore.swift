//
//  AttachmentStore.swift
//  Vellix
//

import Foundation
import UniformTypeIdentifiers
import GRDB

final class AttachmentStore: @unchecked Sendable {
    private let rootURL: URL

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

    func importFile(at sourceURL: URL, documentID: String) throws -> AttachmentRecord {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let originalName = sourceURL.lastPathComponent
        let safeName = Self.safeFileName(originalName)
        let storedName = "\(UUID().uuidString)-\(safeName)"
        let destination = rootURL.appendingPathComponent(storedName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)

        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let type = UTType(filenameExtension: sourceURL.pathExtension)

        return AttachmentRecord(
            id: UUID().uuidString,
            documentID: documentID,
            originalFileName: originalName,
            storedFileName: storedName,
            relativePath: storedName,
            mimeType: type?.preferredMIMEType,
            uti: type?.identifier,
            fileSize: size,
            thumbnailRelativePath: nil,
            createdAt: Date()
        )
    }

    func importData(
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

        let type = UTType(filenameExtension: destination.pathExtension)
        return AttachmentRecord(
            id: UUID().uuidString,
            documentID: documentID,
            originalFileName: originalFileName,
            storedFileName: storedName,
            relativePath: storedName,
            mimeType: mimeType ?? type?.preferredMIMEType,
            uti: type?.identifier,
            fileSize: Int64(data.count),
            thumbnailRelativePath: nil,
            createdAt: Date()
        )
    }

    func fileURL(relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    func removeFile(relativePath: String) throws {
        let url = fileURL(relativePath: relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Attachment" : cleaned
    }
}

final class AttachmentRepository: @unchecked Sendable {
    private let database: AppDatabase
    private let store: AttachmentStore

    init(database: AppDatabase, store: AttachmentStore) {
        self.database = database
        self.store = store
    }

    func importFile(at sourceURL: URL, documentID: String) throws -> AttachmentRecord {
        let record = try store.importFile(at: sourceURL, documentID: documentID)
        try database.write { db in
            let copy = record
            try copy.insert(db)
        }
        return record
    }

    func importData(
        _ data: Data,
        originalFileName: String,
        mimeType: String?,
        documentID: String
    ) throws -> AttachmentRecord {
        let record = try store.importData(
            data,
            originalFileName: originalFileName,
            mimeType: mimeType,
            documentID: documentID
        )
        try database.write { db in
            let copy = record
            try copy.insert(db)
        }
        return record
    }

    func attachments(for documentID: String) throws -> [AttachmentRecord] {
        try database.read { db in
            try AttachmentRecord.fetchAll(
                db,
                sql: "SELECT * FROM attachments WHERE documentID = ? ORDER BY createdAt DESC",
                arguments: [documentID]
            )
        }
    }

    func delete(id: String) throws {
        try database.write { db in
            guard let record = try AttachmentRecord.fetchOne(db, key: id) else {
                return
            }
            try store.removeFile(relativePath: record.relativePath)
            try db.execute(sql: "DELETE FROM attachments WHERE id = ?", arguments: [id])
        }
    }
}
