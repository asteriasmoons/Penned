import Foundation
import GRDB

/// Captures the exact saved editor records instead of using the public web
/// publication projection, which can strip private blocks and collections.
final class TemplateGalleryNativeExporter {
    private let documents: DocumentRepository
    private let database: AppDatabase
    private let attachmentStore: AttachmentStore
    private let collections: CollectionRepository

    init(database: AppDatabase, attachmentStore: AttachmentStore? = nil) {
        self.database = database
        self.attachmentStore = attachmentStore ?? ((try? AttachmentStore.liveStore()) ?? AttachmentStore.previewStore())
        documents = DocumentRepository(database: database)
        collections = CollectionRepository(database: database, documents: documents)
    }

    func capture(documentID: String) throws -> TemplateGalleryNativeSnapshot {
        let root = try documents.requireDocument(id: documentID)
        guard !root.isTrashed, !root.isArchived else {
            throw PublishingFailure.invalidContent("An archived or trashed document cannot become a gallery template.")
        }

        let available = try documents.editorDocuments()
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        var collected: [DocumentRecord] = []
        var visited = Set<String>()

        func appendSubtree(_ document: DocumentRecord) throws {
            guard visited.insert(document.id).inserted else { return }
            guard document.spaceID == root.spaceID,
                  document.templateID == root.templateID,
                  !document.isTrashed, !document.isArchived else {
                throw PublishingFailure.invalidContent("A nested template page is unavailable.")
            }
            collected.append(document)
            for child in available where child.parentDocumentID == document.id {
                try appendSubtree(child)
            }
            for id in TipTapContentAnalyzer.pageReferenceIDs(in: document.tipTapJSON) {
                guard let linked = byID[id], linked.spaceID == root.spaceID else {
                    throw PublishingFailure.invalidContent("A referenced template page is unavailable.")
                }
                if linked.parentDocumentID == document.id {
                    try appendSubtree(linked)
                }
            }
        }

        try appendSubtree(root)
        // Include collection entry pages, which may not be nested under the root.
        var capturedCollections: [CollectionSnapshot] = []
        var capturedIDs = Set<String>()
        var index = 0
        while index < collected.count {
            let page = collected[index]
            index += 1
            for collectionID in try collections.collectionIDs(forDocument: page.id) {
                guard capturedIDs.insert(collectionID).inserted else { continue }
                let collection = try collections.snapshot(id: collectionID)
                capturedCollections.append(collection)
                for entry in collection.entries {
                    guard let entryDocument = byID[entry.id] else {
                        throw PublishingFailure.invalidContent("A collection entry document is missing.")
                    }
                    try appendSubtree(entryDocument)
                }
            }
        }

        let ids = Set(collected.map(\.id))
        let attachments = try database.read { db in
            try AttachmentRecord.fetchAll(db).filter { ids.contains($0.documentID) }
        }
        var files: [String: Data] = [:]
        for attachment in attachments {
            for path in [attachment.relativePath, attachment.thumbnailRelativePath].compactMap({ $0 }) {
                if files[path] == nil {
                    files[path] = try Data(contentsOf: attachmentStore.validatedFileURL(relativePath: path))
                }
            }
        }
        // Covers and background images may be referenced outside attachment rows.
        for page in collected {
            var paths = EditorAttachment.paths(in: page.tipTapJSON)
            if let cover = page.cover { paths.insert(cover) }
            if let background = page.appearance.editorBackground.imagePath { paths.insert(background) }
            if let background = page.appearance.innerPageBackground.imagePath { paths.insert(background) }
            for path in paths where files[path] == nil {
                files[path] = try Data(contentsOf: attachmentStore.validatedFileURL(relativePath: path))
            }
        }
        let snapshot = TemplateGalleryNativeSnapshot(
            rootDocumentID: root.id, documents: collected,
            attachments: attachments, attachmentFiles: files,
            collections: capturedCollections
        )
        try snapshot.validate()
        return snapshot
    }
}
