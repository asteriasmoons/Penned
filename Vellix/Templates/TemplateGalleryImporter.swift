import Foundation
import GRDB

/// Imports native gallery snapshots as independent, editable document trees.
/// Collection restoration is handled separately; never silently discard collections.
final class TemplateGalleryImporter {
    private let database: AppDatabase
    private let attachmentStore: AttachmentStore

    init(database: AppDatabase, attachmentStore: AttachmentStore) {
        self.database = database
        self.attachmentStore = attachmentStore
    }

    func importPackage(_ package: TemplateGalleryPackage, intoSpace spaceID: String?) throws -> DocumentRecord {
        try importPackage(package, intoSpace: spaceID, personalTemplate: nil)
    }

    func saveTemplate(_ package: TemplateGalleryPackage, intoSpace spaceID: String,
                      description: String = "") throws -> TemplateRecord {
        guard let snapshot = package.nativeSnapshot,
              let source = snapshot.documents.first(where: { $0.id == snapshot.rootDocumentID }) else {
            throw PublishingFailure.invalidContent("This template does not contain editable Penned documents.")
        }
        var template = TemplateRecord(title: package.title, templateDescription: description,
            icon: source.icon, tipTapJSON: source.tipTapJSON, category: TemplateRepository.myTemplatesCategory,
            isBuiltIn: false, spaceID: spaceID)
        let root = try importPackage(package, intoSpace: spaceID, personalTemplate: template)
        template.rootDocumentID = root.id
        template.tipTapJSON = root.tipTapJSON
        return template
    }

    private func importPackage(_ package: TemplateGalleryPackage, intoSpace spaceID: String?,
                               personalTemplate: TemplateRecord?) throws -> DocumentRecord {
        try package.validateForImport()
        guard let snapshot = package.nativeSnapshot else {
            throw PublishingFailure.invalidContent("This template does not contain editable Penned documents.")
        }
        try snapshot.validate()
        guard snapshot.attachments.allSatisfy({ snapshot.attachmentFiles[$0.relativePath] != nil }) else {
            throw PublishingFailure.invalidContent("An attachment is missing from this template.")
        }

        var importedFiles: [String] = []
        do {
            let root = try database.write { db -> DocumentRecord in
                if let personalTemplate {
                    try LibraryAccess.requireSpace(personalTemplate.spaceID, in: db)
                    try personalTemplate.insert(db)
                }
                let idMap = Dictionary(uniqueKeysWithValues: snapshot.documents.map { ($0.id, UUID().uuidString) })
                var pathMap: [String: String] = [:]
                var importedAttachments: [AttachmentRecord] = []
                for source in snapshot.attachments {
                    guard let bytes = snapshot.attachmentFiles[source.relativePath],
                          let newOwner = idMap[source.documentID] else {
                        throw PublishingFailure.invalidContent("An attachment owner or file is missing.")
                    }
                    var imported = try attachmentStore.importData(bytes,
                        originalFileName: source.originalFileName,
                        mimeType: source.mimeType, documentID: newOwner)
                    importedFiles.append(imported.relativePath)
                    pathMap[source.relativePath] = imported.relativePath
                    pathMap[source.id] = imported.id
                    if let thumbnailPath = source.thumbnailRelativePath,
                       let thumbnailBytes = snapshot.attachmentFiles[thumbnailPath] {
                        let thumbnail = try attachmentStore.importData(thumbnailBytes,
                            originalFileName: URL(fileURLWithPath: thumbnailPath).lastPathComponent,
                            mimeType: nil, documentID: newOwner)
                        importedFiles.append(thumbnail.relativePath)
                        imported.thumbnailRelativePath = thumbnail.relativePath
                        pathMap[thumbnailPath] = thumbnail.relativePath
                    }
                    importedAttachments.append(imported)
                }

                // Restore media referenced by covers or content even when no
                // attachment row owns that path in the source snapshot.
                for (path, bytes) in snapshot.attachmentFiles where pathMap[path] == nil {
                    let owner = idMap[snapshot.rootDocumentID]!
                    let imported = try attachmentStore.importData(bytes,
                        originalFileName: URL(fileURLWithPath: path).lastPathComponent,
                        mimeType: nil, documentID: owner)
                    importedFiles.append(imported.relativePath)
                    pathMap[path] = imported.relativePath
                    importedAttachments.append(imported)
                }

                var remaining = snapshot.documents
                while !remaining.isEmpty {
                    guard let index = remaining.firstIndex(where: {
                        $0.id == snapshot.rootDocumentID ||
                        ($0.parentDocumentID.map { parent in
                            !remaining.contains(where: { $0.id == parent })
                        } ?? false)
                    }) else {
                        throw PublishingFailure.invalidContent("The template page hierarchy cannot be imported.")
                    }
                    let source = remaining.remove(at: index)
                    var copy = source
                    copy.id = idMap[source.id]!
                    copy.parentDocumentID = source.parentDocumentID.flatMap { idMap[$0] }
                    copy.spaceID = spaceID
                    copy.folderID = nil
                    copy.templateID = personalTemplate?.id
                    copy.templateOriginID = nil
                    copy.dailyNoteDate = nil
                    copy.isTrashed = false
                    copy.isArchived = false
                    copy.isFavorite = false
                    copy.trashedAt = nil
                    copy.trashBatchID = nil
                    copy.lastOpenedAt = nil
                    copy.createdAt = Date()
                    copy.updatedAt = Date()
                    copy.revision = 1
                    if source.id == snapshot.rootDocumentID { copy.title = package.title }
                    copy.cover = copy.cover.map { pathMap[$0] ?? $0 }
                    copy.appearanceJSON = try StructuredTemplateContent.replacingPaths(copy.appearanceJSON, paths: pathMap)
                    copy.cardStyleJSON = try StructuredTemplateContent.replacingPaths(copy.cardStyleJSON, paths: pathMap)
                    let analysis = try TipTapContentAnalyzer.analyze(
                        StructuredTemplateContent.independent(copy.tipTapJSON, pages: idMap, paths: pathMap,
                            resetsComponentResponses: personalTemplate != nil))
                    copy.tipTapJSON = analysis.canonicalJSON
                    copy.plainText = analysis.plainText
                    copy.previewText = analysis.previewText
                    copy.wordCount = analysis.wordCount
                    copy.characterCount = analysis.characterCount
                    copy.estimatedReadingMinutes = analysis.estimatedReadingMinutes
                    try copy.insert(db)
                    try DocumentRepository.upsertSearchIndex(copy, in: db)
                }
                for attachment in importedAttachments { try attachment.insert(db) }

                // Rebuild collection ownership, fields, views, entry order,
                // and each entry's saved property values using fresh IDs.
                var collectionIDs: [String: String] = [:]
                for source in snapshot.collections {
                    var collection = source.record
                    collection.id = UUID().uuidString
                    collection.documentID = idMap[source.record.documentID]!
                    collection.createdAt = Date()
                    collectionIDs[source.record.id] = collection.id
                    let fieldIDs = Dictionary(uniqueKeysWithValues:
                        source.fields.map { ($0.id, UUID().uuidString) })
                    let viewIDs = Dictionary(uniqueKeysWithValues:
                        source.views.map { ($0.id, UUID().uuidString) })
                    collection.activeViewID = viewIDs[source.record.activeViewID] ??
                        viewIDs.values.first ?? UUID().uuidString
                    try collection.insert(db)
                    for original in source.fields {
                        var field = original
                        field.id = fieldIDs[original.id]!
                        field.collectionID = collection.id
                        try field.insert(db)
                    }
                    for original in source.views {
                        var view = original
                        view.id = viewIDs[original.id]!
                        view.collectionID = collection.id
                        var config = original.configuration
                        config.visibleFieldIDs = config.visibleFieldIDs.compactMap { fieldIDs[$0] }
                        for i in config.filters.indices {
                            config.filters[i].fieldID = fieldIDs[config.filters[i].fieldID] ?? config.filters[i].fieldID
                        }
                        for i in config.sorts.indices {
                            config.sorts[i].fieldID = fieldIDs[config.sorts[i].fieldID] ?? config.sorts[i].fieldID
                        }
                        config.kanbanAssignments = Dictionary(uniqueKeysWithValues:
                            config.kanbanAssignments.compactMap { key, value in
                                idMap[key].map { ($0, value) }
                            })
                        config.kanbanEntryOrder = config.kanbanEntryOrder.mapValues {
                            $0.compactMap { idMap[$0] }
                        }
                        view.configuration = config
                        try view.insert(db)
                    }
                    for (position, entry) in source.entries.enumerated() {
                        guard let entryID = idMap[entry.id] else {
                            throw PublishingFailure.invalidContent("A collection entry is missing from the document snapshot.")
                        }
                        try db.execute(sql: "INSERT INTO collectionEntries (documentID, collectionID, position) VALUES (?, ?, ?)",
                            arguments: [entryID, collection.id, position])
                        for (oldFieldID, value) in entry.values {
                            guard let fieldID = fieldIDs[oldFieldID] else { continue }
                            let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                            try db.execute(sql: "INSERT INTO collectionValues (documentID, fieldID, valueJSON) VALUES (?, ?, ?)",
                                arguments: [entryID, fieldID, json])
                        }
                    }
                }
                try CollectionRepository.remapCollectionReferences(
                    documentIDs: idMap, collectionIDs: collectionIDs, in: db)

                guard let rootID = idMap[snapshot.rootDocumentID],
                      let root = try DocumentRecord.fetchOne(db, key: rootID) else {
                    throw PublishingFailure.invalidContent("The imported template root was not saved.")
                }
                if var personalTemplate {
                    personalTemplate.rootDocumentID = root.id
                    personalTemplate.tipTapJSON = root.tipTapJSON
                    try personalTemplate.update(db)
                }
                return root
            }
            return root
        } catch {
            for path in importedFiles { try? attachmentStore.removeFile(relativePath: path) }
            throw error
        }
    }
}
