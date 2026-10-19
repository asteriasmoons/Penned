import Foundation
import GRDB
import Testing
@testable import Vellix

@MainActor
struct SpaceTests {
    private func fixture() throws -> (AppDatabase, SpaceRepository, DocumentRepository, String, String, AttachmentStore) {
        let db = try AppDatabase.makeInMemory()
        let spaces = SpaceRepository(database: db)
        let a = try spaces.fallback(preferred: nil)
        let b = try spaces.create(title: "Development").id
        let documents = DocumentRepository(database: db); documents.spaceID = a
        let store = AttachmentStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return (db, spaces, documents, a, b, store)
    }

    @Test func migrationPreservesIdentitiesAndBackfillsCompleteTrees() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.vellixMigrator.migrate(queue, upTo: "v15_independent_collection_entry_styles")
        let existing = SpaceRecord(title: "Existing")
        let parent = DocumentRecord(title: "Unowned")
        let child = DocumentRecord(title: "Nested", parentDocumentID: parent.id)
        let owned = DocumentRecord(title: "Owned", spaceID: existing.id)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO spaces (id,title,isArchived,createdAt,updatedAt,sortOrder) VALUES (?,?,0,?,?,0)",
                arguments: [existing.id, existing.title, existing.createdAt, existing.updatedAt])
            try parent.insertBeforeDailyNotes(db); try child.insertBeforeDailyNotes(db); try owned.insertBeforeDailyNotes(db)
            try db.execute(sql: "INSERT INTO templates (id,title,templateDescription,tipTapJSON,category,isBuiltIn,createdAt,updatedAt) VALUES ('legacy','Legacy','',?,'Mine',0,?,?)", arguments: [TipTapContentAnalyzer.emptyDocumentJSON, Date(), Date()])
        }
        let db = try AppDatabase(queue)
        let documents = DocumentRepository(database: db)
        #expect(try documents.requireDocument(id: owned.id).spaceID == existing.id)
        #expect(try documents.requireDocument(id: parent.id).spaceID != nil)
        #expect(try documents.requireDocument(id: child.id).spaceID == documents.requireDocument(id: parent.id).spaceID)
        #expect(try TemplateRepository(database: db).all().first?.spaceID != nil)
        try db.read { try SpaceOwnership.validate(in: $0) }
    }

    @Test func newSpacesAreEmptyAndQueriesAreIsolated() throws {
        let (db, spaces, documents, a, b, _) = try fixture()
        let page = try documents.create(DocumentDraft(title: "Private Budget"))
        _ = try documents.setFavorite(id: page.id, isFavorite: true)
        let templates = TemplateRepository(database: db); templates.spaceID = a
        _ = try templates.create(title: "Private Template")
        let folders = FolderRepository(database: db); folders.spaceID = a
        _ = try folders.create(title: "Private Folder")
        let search = DocumentSearchService(database: db); search.spaceID = b
        documents.spaceID = b; templates.spaceID = b; folders.spaceID = b
        #expect(try documents.allDocuments().isEmpty)
        #expect(try documents.recent().isEmpty && documents.favorites().isEmpty && documents.trashed().isEmpty)
        #expect(try templates.all().isEmpty && folders.all().isEmpty)
        #expect(try search.search("Budget").isEmpty && search.searchableTemplates(matching: "Private").isEmpty)
        #expect(try documents.document(id: page.id) == nil)
        #expect(try spaces.contentCount(id: b) == 0)
        #expect(throws: VellixError.self) { try documents.updateTitle(id: page.id, title: "Leak") }
    }

    @Test func rawWritesCannotDetachOwnersOrCrossParents() throws {
        let (db, _, documents, a, b, _) = try fixture()
        let root = try documents.create(DocumentDraft(title: "Root"))
        let child = try documents.create(DocumentDraft(title: "Child", parentDocumentID: root.id))
        #expect(child.spaceID == a)
        #expect(throws: (any Error).self) { try db.write { try $0.execute(sql: "UPDATE documents SET spaceID=NULL WHERE id=?", arguments: [root.id]) } }
        #expect(throws: (any Error).self) { try db.write { try $0.execute(sql: "UPDATE documents SET spaceID=? WHERE id=?", arguments: [b, root.id]) } }
        #expect(try documents.requireDocument(id: child.id).spaceID == a)
        try db.read { try SpaceOwnership.validate(in: $0) }
    }

    @Test func movesKeepCollectionsValuesAttachmentsHistoryAndDocumentIdentity() throws {
        let (db, spaces, documents, a, b, store) = try fixture()
        let root = try documents.create(DocumentDraft(title: "Root"))
        let collections = CollectionRepository(database: db, documents: documents)
        let collection = try collections.create(ownerID: root.id, name: "Tasks", viewName: "Board", kind: .kanban)
        let entry = try collections.addEntry(collectionID: collection.record.id, title: "Entry")
        let field = CollectionField(collectionID: collection.record.id, name: "Status", kind: .text)
        try collections.saveField(field)
        try collections.saveValue(collectionID: collection.record.id, documentID: entry.id, fieldID: field.id, value: CollectionValue(text: "Ready"))
        let asset = try store.importData(Data("owned".utf8), originalFileName: "note.txt", mimeType: "text/plain", documentID: entry.id)
        try db.write { try asset.insert($0) }
        _ = try SnapshotRepository(database: db).create(document: entry, reason: .manual)
        try spaces.transfer(.document(root.id), from: a, to: b, copy: false, store: store)
        #expect(try documents.document(id: root.id) == nil)
        documents.spaceID = b
        #expect(try documents.requireDocument(id: entry.id).spaceID == b)
        let saved = try collections.snapshot(id: collection.record.id)
        #expect(saved.entries.first?.values[field.id]?.text == "Ready")
        #expect(try AttachmentRepository(database: db, store: store).attachments(for: entry.id).first?.id == asset.id)
        #expect(try SnapshotRepository(database: db).history(documentID: entry.id).count == 1)
        try db.read { try SpaceOwnership.validate(in: $0) }
    }

    @Test func copiesHaveIndependentPagesCollectionsFilesAndSnapshots() throws {
        let (db, spaces, documents, a, b, store) = try fixture()
        let root = try documents.create(DocumentDraft(title: "Root"))
        let repo = CollectionRepository(database: db, documents: documents)
        let collection = try repo.create(ownerID: root.id, name: "Tasks", viewName: "Main", kind: .gallery)
        _ = try documents.saveEditorJSON(id: root.id, canonicalJSON: CollectionRepository.blockJSON(collectionID: collection.record.id, documentID: root.id))
        let entry = try repo.addEntry(collectionID: collection.record.id, title: "Entry")
        let asset = try store.importData(Data("owned".utf8), originalFileName: "note.txt", mimeType: "text/plain", documentID: entry.id)
        try db.write { try asset.insert($0) }
        _ = try SnapshotRepository(database: db).create(document: entry, reason: .manual)
        try spaces.transfer(.document(root.id), from: a, to: b, copy: true, store: store)
        documents.spaceID = b
        let copy = try #require(documents.allDocuments().first)
        #expect(copy.id != root.id)
        let snapshot = try repo.snapshot(id: #require(repo.collectionIDs(forDocument: copy.id).first))
        let copiedEntry = try #require(snapshot.entries.first)
        #expect(copiedEntry.id != entry.id && snapshot.record.id != collection.record.id)
        let attachments = try AttachmentRepository(database: db, store: store).attachments(for: copiedEntry.id)
        #expect(attachments.first?.relativePath != asset.relativePath && attachments.count == 1)
        #expect(try SnapshotRepository(database: db).history(documentID: copiedEntry.id).count == 1)
        documents.spaceID = a
        #expect(try repo.snapshot(id: collection.record.id).entries.first?.id == entry.id)
        try db.read { try SpaceOwnership.validate(in: $0) }
    }

    @Test func folderAndTemplateTransfersRetainTheirTrees() throws {
        let (db, spaces, documents, a, b, store) = try fixture()
        let folders = FolderRepository(database: db); folders.spaceID = a
        let folder = try folders.create(title: "Parent")
        let child = try folders.create(title: "Child", parentFolderID: folder.id)
        _ = try documents.create(DocumentDraft(title: "Page", folderID: child.id))
        try spaces.transfer(.folder(folder.id), from: a, to: b, copy: true, store: store)
        folders.spaceID = b; documents.spaceID = b
        #expect(try folders.all().count == 2 && documents.allDocuments().count == 1)
        let templates = TemplateRepository(database: db); templates.spaceID = a
        let root = try templates.create(title: "Template")
        documents.spaceID = a
        _ = try documents.create(DocumentDraft(title: "Template Child", parentDocumentID: root.id))
        try spaces.transfer(.template(root.templateID!), from: a, to: b, copy: false, store: store)
        templates.spaceID = b
        #expect(try templates.all().first?.rootDocumentID == root.id)
        try db.read { try SpaceOwnership.validate(in: $0) }
    }

    @Test func deletionIncludesTrashAndPreservesOtherSpacesAndGlobalStyles() throws {
        let (db, spaces, documents, a, b, store) = try fixture()
        let root = try documents.create(DocumentDraft(title: "Delete"))
        let collection = try CollectionRepository(database: db, documents: documents).create(ownerID: root.id, name: "C", viewName: "T", kind: .table)
        _ = try CollectionRepository(database: db, documents: documents).addEntry(collectionID: collection.record.id, title: "Nested")
        let asset = try store.importData(Data("owned".utf8), originalFileName: "note.txt", mimeType: "text/plain", documentID: root.id)
        try db.write { try asset.insert($0) }
        _ = try documents.trash(id: root.id)
        let styles = DocumentStyleRepository(database: db, store: store)
        let style = try styles.save(title: "Global", definition: DocumentStyleDefinition(appearance: .plain, cover: asset.relativePath))
        let globalPath = try #require(style.definition().cover)
        documents.spaceID = b
        let survivor = try documents.create(DocumentDraft(title: "Keep"))
        let removed = try spaces.delete(id: a, store: store)
        #expect(removed.contains(root.id))
        #expect(try documents.requireDocument(id: survivor.id).title == "Keep")
        #expect(try styles.all().contains { $0.id == style.id })
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(relativePath: asset.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: store.fileURL(relativePath: globalPath).path))
        #expect(try spaces.space(id: a) == nil)
        try db.read { try SpaceOwnership.validate(in: $0) }
    }

    @Test func archiveExcludesBackgroundTasksWithoutDestroyingContentAndRestores() throws {
        let (db, spaces, documents, a, b, _) = try fixture()
        let root = try documents.create(DocumentDraft(title: "Reminder"))
        #expect(try spaces.owningSpace(documentID: root.id) == a)
        try spaces.archive(id: a)
        #expect(try spaces.owningSpace(documentID: root.id) == nil)
        #expect(try spaces.fallback(preferred: a) == b)
        #expect(try documents.requireDocument(id: root.id).id == root.id)
        #expect(try DocumentTaskRepository(database: db).all().isEmpty)
        try spaces.restore(id: a)
        #expect(try spaces.owningSpace(documentID: root.id) == a)
    }

    @Test func backgroundRemindersIncludeInactiveSpacesButNotArchivedSpaces() throws {
        let (db, spaces, documents, a, b, _) = try fixture()
        func taskJSON() throws -> String {
            let metadata = DocumentTaskMetadata(scheduledAt: Date().addingTimeInterval(3600).timeIntervalSince1970, reminderEnabled: true)
            return try TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "taskList", "content": [
                ["type": "taskItem", "attrs": ["id": UUID().uuidString, "checked": false, "trackedTask": metadata.object],
                 "content": [["type": "paragraph", "content": [["type": "text", "text": "Reminder"]]]]]
            ]]])
        }
        _ = try documents.create(DocumentDraft(title: "Personal reminder", tipTapJSON: taskJSON()))
        documents.spaceID = b
        _ = try documents.create(DocumentDraft(title: "Development reminder", tipTapJSON: taskJSON()))
        let foreground = DocumentTaskRepository(database: db); foreground.spaceID = b
        let background = DocumentTaskRepository(database: db)
        #expect(try foreground.all().count == 1)
        #expect(try background.reminders().count == 2)
        try spaces.archive(id: a)
        #expect(try background.reminders().count == 1)
        try spaces.restore(id: a)
        #expect(try background.reminders().count == 2)
    }

    @Test func eventNotesAreIndependentAndCollisionTransfersRollBack() throws {
        let (db, spaces, documents, a, b, store) = try fixture()
        let event = CalendarEvent(identity: CalendarEventIdentity(calendarID: "calendar", sourceID: "source", localID: "local", externalID: "server"),
            title: "Meeting", calendarTitle: "Calendar", colorRed: 0.5, colorGreen: 0.3, colorBlue: 0.8,
            start: Date(), end: Date().addingTimeInterval(3600), isAllDay: false)
        let notes = CalendarEventNoteRepository(database: db, documents: documents)
        let first = try notes.createOrFind(for: event)
        documents.spaceID = b
        #expect(try notes.notes(for: [event]).isEmpty)
        let second = try notes.createOrFind(for: event)
        #expect(first.id != second.id && second.spaceID == b)
        #expect(try notes.notes(for: [event])[event.id]?.id == second.id)
        #expect(throws: VellixError.self) { try spaces.transfer(.document(first.id), from: a, to: b, copy: false, store: store) }
        documents.spaceID = a
        #expect(try documents.requireDocument(id: first.id).spaceID == a)
        #expect(try notes.createOrFind(for: event).id == first.id)
        try db.read { try SpaceOwnership.validate(in: $0) }
    }

    @Test func foreignEmbeddedReferencesCannotExposeAnotherSpace() throws {
        let (db, _, documents, a, b, _) = try fixture()
        let secret = try documents.create(DocumentDraft(title: "Secret"))
        let collection = try CollectionRepository(database: db, documents: documents).create(ownerID: secret.id, name: "Private Collection", viewName: "Main", kind: .gallery)
        documents.spaceID = b
        let page = try documents.create(DocumentDraft(title: "Other", tipTapJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [
            ["type": "pageReference", "attrs": ["id": "foreign", "documentID": secret.id]],
            ["type": "collection", "attrs": ["id": "collection", "collectionID": collection.record.id, "documentID": secret.id]]
        ])))
        let repository = CollectionRepository(database: db, documents: documents)
        let content = try repository.previewContent(for: page, documents: documents)
        #expect(content.children.isEmpty && content.collections.isEmpty && content.payloads.isEmpty)
        #expect(throws: VellixError.self) { try repository.snapshot(id: collection.record.id) }
        #expect(throws: VellixError.self) { try repository.rename(collectionID: collection.record.id, name: "Changed") }
        documents.spaceID = a
        #expect(try repository.snapshot(id: collection.record.id).name == "Private Collection")
    }

    @Test func copiedTrashBatchesRestoreTheirChildrenAndFilesCanBeCleanedAfterRetry() throws {
        let (db, spaces, documents, a, b, store) = try fixture()
        let root = try documents.create(DocumentDraft(title: "Root"))
        _ = try documents.create(DocumentDraft(title: "Child", parentDocumentID: root.id))
        _ = try documents.trash(id: root.id)
        try spaces.transfer(.document(root.id), from: a, to: b, copy: true, store: store)
        documents.spaceID = b
        let copy = try #require(documents.trashed().first)
        _ = try documents.restore(id: copy.id)
        #expect(try documents.children(of: copy.id).count == 1)
        let asset = try store.importData(Data("retry".utf8), originalFileName: "retry.txt", mimeType: "text/plain", documentID: copy.id)
        try db.write { try $0.execute(sql: "INSERT INTO attachmentCleanup VALUES (?)", arguments: [asset.relativePath]) }
        try spaces.drainAttachmentCleanup(store: store)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(relativePath: asset.relativePath).path))
        try spaces.drainAttachmentCleanup(store: store)
        try db.read { try SpaceOwnership.validate(in: $0) }
    }

    @Test func folderMovesAndTemplateCopiesAreCompleteAndIndependent() throws {
        let (db, spaces, documents, a, b, store) = try fixture()
        let folders = FolderRepository(database: db); folders.spaceID = a
        let folder = try folders.create(title: "Move Folder")
        let child = try folders.create(title: "Child", parentFolderID: folder.id)
        let page = try documents.create(DocumentDraft(title: "Page", folderID: child.id))
        let nested = try documents.create(DocumentDraft(title: "Nested", parentDocumentID: page.id))
        try spaces.transfer(.folder(folder.id), from: a, to: b, copy: false, store: store)
        documents.spaceID = b; folders.spaceID = b
        #expect(try documents.requireDocument(id: nested.id).spaceID == b)
        #expect(try folders.all().first { $0.id == folder.id }?.parentFolderID == nil)
        let templates = TemplateRepository(database: db); templates.spaceID = b
        let template = try templates.create(title: "Copy Template")
        let repository = CollectionRepository(database: db, documents: documents)
        let collection = try repository.create(ownerID: template.id, name: "Template Collection", viewName: "Main", kind: .table)
        _ = try repository.addEntry(collectionID: collection.record.id, title: "Template Entry")
        try spaces.transfer(.template(template.templateID!), from: b, to: a, copy: true, store: store)
        templates.spaceID = a; documents.spaceID = a
        let copied = try #require(templates.all().first)
        #expect(copied.id != template.templateID && copied.rootDocumentID != template.id)
        let copiedCollection = try repository.snapshot(id: #require(repository.collectionIDs(forDocument: copied.rootDocumentID!).first))
        #expect(copiedCollection.record.id != collection.record.id && copiedCollection.entries.count == 1)
        try db.read { try SpaceOwnership.validate(in: $0) }
    }

    @Test func workspaceRecordsAndOwnershipSurviveDiskReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Spaces.sqlite").path
        var owner = "", pageID = ""
        do {
            let database = try AppDatabase(DatabaseQueue(path: path))
            let spaces = SpaceRepository(database: database)
            var space = try spaces.create(title: "Persistent")
            space.icon = "sf:moon.stars"; space.iconImageData = Data([137, 80, 78, 71])
            space.spaceDescription = "Saved workspace"; space.sortOrder = 12
            try spaces.save(space); owner = space.id
            let documents = DocumentRepository(database: database); documents.spaceID = owner
            pageID = try documents.create(DocumentDraft(title: "Still here")).id
        }
        let database = try AppDatabase(DatabaseQueue(path: path))
        let loaded = try SpaceRepository(database: database).space(id: owner)
        let space = try #require(loaded)
        #expect(space.icon == "sf:moon.stars" && space.spaceDescription == "Saved workspace" && space.sortOrder == 12)
        #expect(space.iconImageData == Data([137, 80, 78, 71]))
        let documents = DocumentRepository(database: database); documents.spaceID = owner
        #expect(try documents.allDocuments().first?.id == pageID)
        try database.read { try SpaceOwnership.validate(in: $0) }
    }

    @Test func spaceImageMigrationPreservesExistingSpaceAndSupportsRemoval() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.vellixMigrator.migrate(queue, upTo: "v16_independent_spaces")
        let id = try queue.write { db in try SpaceOwnership.defaultSpace(in: db) }
        let database = try AppDatabase(queue)
        let repository = SpaceRepository(database: database)
        var space = try #require(try repository.space(id: id))
        #expect(space.iconImageData == nil)
        let title = space.title
        space.iconImageData = Data([1, 2, 3, 4])
        try repository.save(space)
        #expect(try repository.space(id: id)?.iconImageData == Data([1, 2, 3, 4]))
        #expect(try database.read { try String.fetchOne($0, sql: "SELECT typeof(iconImageData) FROM spaces WHERE id=?", arguments: [id]) } == "blob")
        space.iconImageData = nil
        try repository.save(space)
        let cleared = try #require(try repository.space(id: id))
        #expect(cleared.id == id && cleared.title == title && cleared.iconImageData == nil)
        #expect(try repository.contentCount(id: id) == 0)
    }

    @Test func borrowedAssetsBecomeIndependentWhenMovingOrCopyingAcrossSpaces() throws {
        for copy in [false, true] {
            let (db, spaces, documents, a, b, store) = try fixture()
            let other = try documents.create(DocumentDraft(title: "Other asset owner"))
            let asset = try store.importData(Data("shared".utf8), originalFileName: "cover.txt", mimeType: "text/plain", documentID: other.id)
            try db.write { try asset.insert($0) }
            let page = try documents.create(DocumentDraft(title: "Borrowed cover", cover: asset.relativePath))
            try spaces.transfer(.document(page.id), from: a, to: b, copy: copy, store: store)
            documents.spaceID = b
            let moved = try #require(documents.allDocuments().first)
            let cover = try #require(moved.cover)
            #expect(cover != asset.relativePath)
            _ = try spaces.delete(id: a, store: store)
            #expect(FileManager.default.fileExists(atPath: store.fileURL(relativePath: cover).path))
            #expect(try documents.requireDocument(id: moved.id).cover == cover)
        }
    }

    @Test func copiedFolderRemapsReferencesBetweenSeparateRootPages() throws {
        let (db, spaces, documents, a, b, store) = try fixture()
        let folders = FolderRepository(database: db); folders.spaceID = a
        let folder = try folders.create(title: "References")
        let first = try documents.create(DocumentDraft(title: "First", folderID: folder.id))
        let second = try documents.create(DocumentDraft(title: "Second", folderID: folder.id))
        let repo = CollectionRepository(database: db, documents: documents)
        let collection = try repo.create(ownerID: second.id, name: "Shared inside folder", viewName: "Main", kind: .gallery)
        _ = try documents.saveEditorJSON(id: first.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [
            ["type": "pageReference", "attrs": ["id": "page", "documentID": second.id]],
            ["type": "collection", "attrs": ["id": "collection", "documentID": second.id, "collectionID": collection.record.id]]
        ]))
        try spaces.transfer(.folder(folder.id), from: a, to: b, copy: true, store: store)
        documents.spaceID = b
        let pages = try documents.allDocuments()
        let copiedFirst = try #require(pages.first { $0.title == "First" })
        let copiedSecond = try #require(pages.first { $0.title == "Second" })
        #expect(TipTapContentAnalyzer.pageReferenceIDs(in: copiedFirst.tipTapJSON) == [copiedSecond.id])
        let collections = try repo.collectionIDs(forDocument: copiedFirst.id)
        #expect(collections.count == 1 && collections.first != collection.record.id)
    }

    @Test func failedFilesystemCleanupRemainsQueuedAndCanBeRetried() throws {
        let (db, spaces, documents, a, _, store) = try fixture()
        let page = try documents.create(DocumentDraft(title: "Cleanup"))
        let asset = try store.importData(Data("owned".utf8), originalFileName: "cleanup.txt", mimeType: "text/plain", documentID: page.id)
        try db.write { try asset.insert($0) }
        let root = store.fileURL(relativePath: asset.relativePath).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        _ = try spaces.delete(id: a, store: store)
        let queued = try db.read { try String.fetchAll($0, sql: "SELECT relativePath FROM attachmentCleanup") }
        #expect(queued == [asset.relativePath])
        #expect(try spaces.space(id: a) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try spaces.drainAttachmentCleanup(store: store)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(relativePath: asset.relativePath).path))
        let remaining = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentCleanup") }
        #expect(remaining == 0)
    }
}
