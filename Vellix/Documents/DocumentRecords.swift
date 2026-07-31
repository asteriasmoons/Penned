//
//  DocumentRecords.swift
//  Vellix
//

import Foundation
import GRDB

struct SpaceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "spaces"

    var id: String
    var title: String
    var spaceDescription: String?
    var icon: String?
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Double

    init(
        id: String = UUID().uuidString,
        title: String,
        spaceDescription: String? = nil,
        icon: String? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sortOrder: Double = 0
    ) {
        self.id = id
        self.title = title
        self.spaceDescription = spaceDescription
        self.icon = icon
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }
}

struct FolderRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "folders"

    var id: String
    var spaceID: String?
    var parentFolderID: String?
    var title: String
    var icon: String?
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Double

    init(
        id: String = UUID().uuidString,
        spaceID: String? = nil,
        parentFolderID: String? = nil,
        title: String,
        icon: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sortOrder: Double = 0
    ) {
        self.id = id
        self.spaceID = spaceID
        self.parentFolderID = parentFolderID
        self.title = title
        self.icon = icon
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }
}

struct DocumentRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "documents"

    var id: String
    var title: String
    var subtitle: String?
    var icon: String?
    var cover: String?
    var appearanceJSON: String?
    var blockNoteJSON: String
    var plainText: String
    var previewText: String
    var spaceID: String?
    var folderID: String?
    var parentDocumentID: String?
    var isFavorite: Bool
    var isArchived: Bool
    var isTrashed: Bool
    var trashedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?
    var revision: Int
    var documentSchemaVersion: Int
    var wordCount: Int
    var characterCount: Int
    var estimatedReadingMinutes: Int
    var sortOrder: Double
    var templateOriginID: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        icon: String? = "doc.text",
        cover: String? = nil,
        appearanceJSON: String? = nil,
        blockNoteJSON: String = BlockNoteContentAnalyzer.emptyDocumentJSON,
        plainText: String = "",
        previewText: String = "No content yet",
        spaceID: String? = nil,
        folderID: String? = nil,
        parentDocumentID: String? = nil,
        isFavorite: Bool = false,
        isArchived: Bool = false,
        isTrashed: Bool = false,
        trashedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        revision: Int = 1,
        documentSchemaVersion: Int = 1,
        wordCount: Int = 0,
        characterCount: Int = 0,
        estimatedReadingMinutes: Int = 0,
        sortOrder: Double = 0,
        templateOriginID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.cover = cover
        self.appearanceJSON = appearanceJSON
        self.blockNoteJSON = blockNoteJSON
        self.plainText = plainText
        self.previewText = previewText
        self.spaceID = spaceID
        self.folderID = folderID
        self.parentDocumentID = parentDocumentID
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.isTrashed = isTrashed
        self.trashedAt = trashedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.revision = revision
        self.documentSchemaVersion = documentSchemaVersion
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.estimatedReadingMinutes = estimatedReadingMinutes
        self.sortOrder = sortOrder
        self.templateOriginID = templateOriginID
    }
}

enum SnapshotReason: String, Codable, CaseIterable {
    case automatic
    case manual
    case beforeDestructiveReplacement
    case beforeMigration
    case recovery
}

struct DocumentSnapshotRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "documentSnapshots"

    var id: String
    var documentID: String
    var blockNoteJSON: String
    var createdAt: Date
    var revision: Int
    var reason: String
    var isAutomatic: Bool

    init(
        id: String = UUID().uuidString,
        documentID: String,
        blockNoteJSON: String,
        createdAt: Date = Date(),
        revision: Int,
        reason: SnapshotReason,
        isAutomatic: Bool
    ) {
        self.id = id
        self.documentID = documentID
        self.blockNoteJSON = blockNoteJSON
        self.createdAt = createdAt
        self.revision = revision
        self.reason = reason.rawValue
        self.isAutomatic = isAutomatic
    }
}

struct TemplateRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "templates"

    var id: String
    var title: String
    var templateDescription: String
    var icon: String?
    var blockNoteJSON: String
    var category: String
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        templateDescription: String,
        icon: String? = "doc.text",
        blockNoteJSON: String,
        category: String,
        isBuiltIn: Bool,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.templateDescription = templateDescription
        self.icon = icon
        self.blockNoteJSON = blockNoteJSON
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct AttachmentRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "attachments"

    var id: String
    var documentID: String
    var originalFileName: String
    var storedFileName: String
    var relativePath: String
    var mimeType: String?
    var uti: String?
    var fileSize: Int64
    var thumbnailRelativePath: String?
    var createdAt: Date
}

struct DocumentLocation: Hashable {
    var space: SpaceRecord?
    var folder: FolderRecord?
    var parents: [DocumentRecord]

    var pathDescription: String {
        let names = [space?.title, folder?.title] + parents.map(\.title)
        let joined = names.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        return joined.isEmpty ? "Library" : joined
    }
}

struct LibraryOverview {
    var recent: [DocumentRecord] = []
    var favorites: [DocumentRecord] = []
    var all: [DocumentRecord] = []
    var trashed: [DocumentRecord] = []
    var spaces: [SpaceRecord] = []
    var folders: [FolderRecord] = []
    var templates: [TemplateRecord] = []
}
