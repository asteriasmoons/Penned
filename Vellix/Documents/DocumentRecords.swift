//
//  DocumentRecords.swift
//  Vellix
//

import Foundation
import GRDB

struct SpaceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "spaces"

    var id: String
    var title: String
    var spaceDescription: String?
    var icon: String?
    var iconImageData: Data?
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Double
    var libraryID: String = LibraryRecord.localID

    init(
        id: String = UUID().uuidString,
        title: String,
        spaceDescription: String? = nil,
        icon: String? = nil,
        iconImageData: Data? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sortOrder: Double = 0
    ) {
        self.id = id
        self.title = title
        self.spaceDescription = spaceDescription
        self.icon = icon
        self.iconImageData = iconImageData
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }
}

struct FolderRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "folders"

    var id: String
    var spaceID: String?
    var parentFolderID: String?
    var title: String
    var icon: String?
    var iconColorHex: String?
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Double

    init(
        id: String = UUID().uuidString,
        spaceID: String? = nil,
        parentFolderID: String? = nil,
        title: String,
        icon: String? = nil,
        iconColorHex: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sortOrder: Double = 0
    ) {
        self.id = id
        self.spaceID = spaceID
        self.parentFolderID = parentFolderID
        self.title = title
        self.icon = icon
        self.iconColorHex = iconColorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }
}

struct DocumentRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "documents"

    var id: String
    var title: String
    var subtitle: String?
    var icon: String?
    var cover: String?
    var appearanceJSON: String?
    var cardStyleJSON: String?
    var tipTapJSON: String
    var plainText: String
    var previewText: String
    var spaceID: String?
    var folderID: String?
    var parentDocumentID: String?
    var isFavorite: Bool
    var isArchived: Bool
    var isTrashed: Bool
    var trashedAt: Date?
    var trashBatchID: String?
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
    var templateID: String?
    var dailyNoteDate: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        icon: String? = "doc.text",
        cover: String? = nil,
        appearanceJSON: String? = nil,
        cardStyleJSON: String? = nil,
        tipTapJSON: String = TipTapContentAnalyzer.emptyDocumentJSON,
        plainText: String = "",
        previewText: String = "No content yet",
        spaceID: String? = nil,
        folderID: String? = nil,
        parentDocumentID: String? = nil,
        isFavorite: Bool = false,
        isArchived: Bool = false,
        isTrashed: Bool = false,
        trashedAt: Date? = nil,
        trashBatchID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        revision: Int = 1,
        documentSchemaVersion: Int = 1,
        wordCount: Int = 0,
        characterCount: Int = 0,
        estimatedReadingMinutes: Int = 0,
        sortOrder: Double = 0,
        templateOriginID: String? = nil,
        templateID: String? = nil,
        dailyNoteDate: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.cover = cover
        self.appearanceJSON = appearanceJSON
        self.cardStyleJSON = cardStyleJSON
        self.tipTapJSON = tipTapJSON
        self.plainText = plainText
        self.previewText = previewText
        self.spaceID = spaceID
        self.folderID = folderID
        self.parentDocumentID = parentDocumentID
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.isTrashed = isTrashed
        self.trashedAt = trashedAt
        self.trashBatchID = trashBatchID
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
        self.templateID = templateID
        self.dailyNoteDate = dailyNoteDate
    }
}

// A lightweight projection of a document for library browsing. It carries every
// column the gallery, cards, navigation and preview-key generation need, and
// deliberately EXCLUDES the heavy `tipTapJSON` and `plainText` columns so a page
// of the library can be loaded without pulling document bodies into memory. The
// full `DocumentRecord` is fetched by id only when a body is genuinely required
// (opening a document, or rendering a fallback preview for an uncached cell).
nonisolated struct DocumentSummary: Codable, FetchableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "documents"

    // Keep this list and the property set below in lockstep; `summaryColumns`
    // drives every SELECT that decodes into a DocumentSummary.
    static let columns = "id, title, subtitle, icon, cover, appearanceJSON, cardStyleJSON, previewText, spaceID, folderID, parentDocumentID, isFavorite, isArchived, isTrashed, trashedAt, createdAt, updatedAt, lastOpenedAt, wordCount, sortOrder, templateID, dailyNoteDate"

    // The same column list qualified with a table alias, for queries that join or
    // self-reference the documents table (e.g. the trash query's `documents d`).
    static func columns(alias: String) -> String {
        columns.split(separator: ",").map { "\(alias).\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", ")
    }

    var id: String
    var title: String
    var subtitle: String?
    var icon: String?
    var cover: String?
    var appearanceJSON: String?
    var cardStyleJSON: String?
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
    var wordCount: Int
    var sortOrder: Double
    var templateID: String?
    var dailyNoteDate: String?

    // Mirror DocumentRecord's derived presentation accessors exactly; each depends
    // only on columns carried by the summary.
    var appearance: DocumentAppearance { DocumentAppearance.decode(appearanceJSON) }
    var isThemed: Bool { appearance.themeID != nil }
    var cardStyle: PageCardStyle? { PageCardStyle.decode(cardStyleJSON) }

    // Project a full record down to a summary, for the bounded sections that already
    // have records in hand (so no extra query is needed).
    init(_ record: DocumentRecord) {
        id = record.id
        title = record.title
        subtitle = record.subtitle
        icon = record.icon
        cover = record.cover
        appearanceJSON = record.appearanceJSON
        cardStyleJSON = record.cardStyleJSON
        previewText = record.previewText
        spaceID = record.spaceID
        folderID = record.folderID
        parentDocumentID = record.parentDocumentID
        isFavorite = record.isFavorite
        isArchived = record.isArchived
        isTrashed = record.isTrashed
        trashedAt = record.trashedAt
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        lastOpenedAt = record.lastOpenedAt
        wordCount = record.wordCount
        sortOrder = record.sortOrder
        templateID = record.templateID
        dailyNoteDate = record.dailyNoteDate
    }
}

// The library sort orders, each reproduced exactly at the database level (the
// title order uses the LOCALIZED_STANDARD collation so it matches the gallery's
// historical `localizedStandardCompare`). Keyset pagination depends on the ORDER
// BY and cursor comparison agreeing, so both are derived from this one value.
nonisolated enum DocumentSummarySort: Sendable {
    case updated
    case created
    case title
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
    var tipTapJSON: String
    var createdAt: Date
    var revision: Int
    var reason: String
    var isAutomatic: Bool

    init(
        id: String = UUID().uuidString,
        documentID: String,
        tipTapJSON: String,
        createdAt: Date = Date(),
        revision: Int,
        reason: SnapshotReason,
        isAutomatic: Bool
    ) {
        self.id = id
        self.documentID = documentID
        self.tipTapJSON = tipTapJSON
        self.createdAt = createdAt
        self.revision = revision
        self.reason = reason.rawValue
        self.isAutomatic = isAutomatic
    }
}

struct TemplateRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "templates"

    var id: String
    var title: String
    var templateDescription: String
    var icon: String?
    var tipTapJSON: String
    var category: String
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date
    var rootDocumentID: String?
    var spaceID: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        templateDescription: String,
        icon: String? = "doc.text",
        tipTapJSON: String,
        category: String,
        isBuiltIn: Bool,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        rootDocumentID: String? = nil,
        spaceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.templateDescription = templateDescription
        self.icon = icon
        self.tipTapJSON = tipTapJSON
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rootDocumentID = rootDocumentID
        self.spaceID = spaceID
    }
}

nonisolated struct AttachmentRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
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

struct LibraryOverview: Sendable {
    // Bounded sections, carried as body-free summaries. The unbounded "All Docs"
    // surface is no longer materialized here; it is paged from the database by
    // LibraryBrowseStore. `documentCount` is the top-level count for badges that
    // previously read `all.count`.
    var recent: [DocumentSummary] = []
    var favorites: [DocumentSummary] = []
    var dailyNotes: [DocumentSummary] = []
    var trashed: [DocumentSummary] = []
    var documentCount: Int = 0
    var documentCountsByFolder: [String?: Int] = [:]
    var spaces: [SpaceRecord] = []
    var folders: [FolderRecord] = []
    var templates: [TemplateRecord] = []
    var templateDocuments: [String: DocumentRecord] = [:]
}
