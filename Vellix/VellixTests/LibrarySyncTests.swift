import CloudKit
import Foundation
import GRDB
import Testing
@testable import Vellix

@Suite @MainActor
struct LibrarySyncTests {
    @Test func pendingBatchesPrioritizeSpaceMetadataAndDecodeOnlySelectedRecords() throws {
        let (_, database, store) = try fixture()
        try store.enable(confirmed: true)
        let space = try SpaceRepository(database: database).create(title: "Arrive before pages")
        let folders = FolderRepository(database: database)
        for index in 0..<105 { _ = try folders.create(title: "Folder \(index)", spaceID: space.id) }
        let names = try store.pendingRecordNames()
        #expect(names.count == 106 && names.first?.hasPrefix("spaces-") == true)
        let batch = try store.pending(recordNames: Array(names.prefix(100)))
        #expect(batch.count == 100 && batch.map { $0.row.recordName } == Array(names.prefix(100)))
        #expect(try store.pending(recordNames: []).isEmpty)
        #expect(try store.pending().count == 106)
    }

    @Test func immediateRequestsStartWithoutATimerAndRetainWritesQueuedDuringATransfer() async throws {
        let requests = LibrarySyncRequests()
        var calls: [(Bool, Bool)] = []
        var release: CheckedContinuation<Void, Never>?
        let first = Task {
            try await requests.run(fetch: true, send: true) { fetch, send in
                calls.append((fetch, send))
                if calls.count == 1 { await withCheckedContinuation { release = $0 } }
            }
        }
        while release == nil { await Task.yield() }
        #expect(calls.count == 1 && calls[0].0 && calls[0].1)
        var queued = false
        let edit = Task {
            queued = true
            try await requests.run(fetch: false, send: true) { _, _ in
                Issue.record("The active drain should own coalesced requests")
            }
        }
        while !queued { await Task.yield() }
        release?.resume()
        try await first.value; try await edit.value
        #expect(calls.count == 2 && !calls[1].0 && calls[1].1)
    }

    @Test func failedImmediateRequestCanRetryWithoutReplacingTheDurableQueue() async throws {
        let requests = LibrarySyncRequests()
        do {
            try await requests.run(fetch: true, send: true) { _, _ in throw URLError(.notConnectedToInternet) }
            Issue.record("Expected the network error")
        } catch {}
        var retried = false
        try await requests.run(fetch: true, send: true) { fetch, send in retried = fetch && send }
        #expect(retried)
    }

    @Test func accountInvalidationCancelsTheActiveDrainAndDiscardsQueuedWork() async throws {
        let requests = LibrarySyncRequests()
        var release: CheckedContinuation<Void, Never>?
        var count = 0
        let transfer = Task {
            try await requests.run(fetch: true, send: true) { _, _ in
                count += 1
                await withCheckedContinuation { release = $0 }
            }
        }
        while release == nil { await Task.yield() }
        requests.cancel()
        release?.resume()
        do { try await transfer.value; Issue.record("Cancelled sync must not report completion") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(count == 1)
    }

    func fixture() throws -> (AppDatabase, AppDatabase, LibrarySyncStore) {
        let root = try AppDatabase.makeInMemory()
        let owner = "apple:sync-tests"
        let library = try LibraryRepository(database: root).accountLibrary(ownerKey: owner)
        return (root, root.scoped(to: library.id), LibrarySyncStore(database: root, libraryID: library.id, ownerKey: owner, cloudAccountID: "iCloud-A"))
    }

    func attachmentStore() throws -> AttachmentStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return AttachmentStore(rootURL: url)
    }

    func deliver(_ source: LibrarySyncStore, to target: LibrarySyncStore,
                 sourceFiles: AttachmentStore, targetFiles: AttachmentStore) throws {
        for item in try source.pending().reversed() {
            let record = try source.makeRecord(item, attachments: sourceFiles)
            try target.stageIncoming(record, attachments: targetFiles)
            try source.acknowledge(record)
        }
        _ = try target.applyIncoming()
    }

    @Test func actualRecordsCollectionsAndAttachmentBytesRoundTripBetweenIndependentDatabases() throws {
        let (_, first, source) = try fixture(), (_, second, target) = try fixture()
        let sourceFiles = try attachmentStore(), targetFiles = try attachmentStore()
        try source.enable(confirmed: true); try target.enable(confirmed: true)
        let space = try SpaceRepository(database: first).create(title: "Synced Space")
        let folders = FolderRepository(database: first)
        let folder = try folders.create(title: "Folder", spaceID: space.id)
        let docs = DocumentRepository(database: first)
        let page = try docs.create(DocumentDraft(title: "Real authored page", spaceID: space.id, folderID: folder.id))
        let collections = CollectionRepository(database: first, documents: docs)
        let collection = try collections.create(ownerID: page.id, name: "Projects", viewName: "Main", kind: .gallery)
        let attachment = try AttachmentRepository(database: first, store: sourceFiles).importData(Data("real-file-bytes".utf8), originalFileName: "file.txt", mimeType: "text/plain", documentID: page.id)
        try deliver(source, to: target, sourceFiles: sourceFiles, targetFiles: targetFiles)
        let restored = try DocumentRepository(database: second).requireDocument(id: page.id)
        #expect(restored.spaceID == space.id && restored.folderID == folder.id)
        #expect(restored.tipTapJSON == page.tipTapJSON)
        #expect(try CollectionRepository(database: second, documents: DocumentRepository(database: second)).snapshot(id: collection.record.id).record.name == "Projects")
        #expect(try Data(contentsOf: targetFiles.fileURL(relativePath: attachment.relativePath)) == Data("real-file-bytes".utf8))
        #expect(try target.pending().isEmpty)
        #expect(try DocumentSearchService(database: second).search("authored").map(\.documentID).contains(page.id))
    }

    @Test func dependenciesWaitAcrossBatchesAndConflictsRetainRecoverableRichText() throws {
        let (_, first, source) = try fixture(), (_, second, target) = try fixture()
        let sourceFiles = try attachmentStore(), targetFiles = try attachmentStore()
        try source.enable(confirmed: true); try target.enable(confirmed: true)
        let docs = DocumentRepository(database: first)
        let page = try docs.create(DocumentDraft(title: "Original"))
        let documentItem = try source.pending().first { $0.row.table == "documents" }!
        try target.stageIncoming(source.makeRecord(documentItem, attachments: sourceFiles), attachments: targetFiles)
        _ = try target.applyIncoming()
        #expect(try DocumentRepository(database: second).document(id: page.id) == nil)
        try deliver(source, to: target, sourceFiles: sourceFiles, targetFiles: targetFiles)
        let localJSON = try TipTapContentAnalyzer.starterDocument(title: "Local revision", lines: ["Do not lose this text"])
        _ = try DocumentRepository(database: second).saveEditorJSON(id: page.id, canonicalJSON: localJSON)
        _ = try docs.updateTitle(id: page.id, title: "Concurrent remote edit")
        try deliver(source, to: target, sourceFiles: sourceFiles, targetFiles: targetFiles)
        let conflict = try target.conflicts().first { $0.row.table == "documents" }!
        #expect(conflict.row.values["tipTapJSON"]?.text?.contains("Do not lose this text") == true)
        #expect(try SnapshotRepository(database: second).history(documentID: page.id).contains(where: { $0.reason == SnapshotReason.recovery.rawValue }))
        try target.recover(conflictID: conflict.id)
        #expect(try DocumentRepository(database: second).requireDocument(id: page.id).tipTapJSON.contains("Do not lose this text"))
        #expect(try target.pending().contains { $0.row.table == "documents" })
    }

    @Test func tombstonesDeleteOnlyTheirOwnedContentAndRetainOfflineAssets() throws {
        let (_, first, source) = try fixture(), (_, second, target) = try fixture()
        let sourceFiles = try attachmentStore(), targetFiles = try attachmentStore()
        try source.enable(confirmed: true); try target.enable(confirmed: true)
        let docs = DocumentRepository(database: first)
        let parent = try docs.create(DocumentDraft(title: "Parent"))
        let child = try docs.create(DocumentDraft(title: "Child", parentDocumentID: parent.id))
        let file = try AttachmentRepository(database: first, store: sourceFiles).importData(Data("retained".utf8), originalFileName: "retained.txt", mimeType: "text/plain", documentID: child.id)
        try deliver(source, to: target, sourceFiles: sourceFiles, targetFiles: targetFiles)
        try docs.permanentlyDelete(id: parent.id, attachmentStore: sourceFiles)
        #expect(FileManager.default.fileExists(atPath: sourceFiles.fileURL(relativePath: file.relativePath).path))
        try deliver(source, to: target, sourceFiles: sourceFiles, targetFiles: targetFiles)
        #expect(try DocumentRepository(database: second).document(id: parent.id) == nil)
        #expect(try DocumentRepository(database: second).document(id: child.id) == nil)
        #expect(try target.pending().isEmpty)
    }

    @Test func templatesDailyNotesAppearanceStylesTasksAndSnapshotsPreserveTheirGraph() throws {
        let (_, first, source) = try fixture(), (_, second, target) = try fixture()
        let files = try attachmentStore(), restoredFiles = try attachmentStore()
        try source.enable(confirmed: true); try target.enable(confirmed: true)
        let templates = TemplateRepository(database: first)
        let template = try templates.create(title: "Daily template")
        let docs = DocumentRepository(database: first)
        var task = DocumentTaskMetadata()
        task.history = [TaskCompletedOccurrence(id: "finished-occurrence", completedAt: Date().timeIntervalSince1970)]
        let json = try TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "taskList", "content": [["type": "taskItem",
            "attrs": ["id": "tracked-block", "checked": true, "trackedTask": task.object],
            "content": [["type": "paragraph", "content": [["type": "text", "text": "Completed work"]]]]]]]])
        let page = try docs.create(DocumentDraft(title: "Styled task", appearanceJSON: DocumentAppearance.plain.encodedJSON(), tipTapJSON: json))
        _ = try SnapshotRepository(database: first).create(document: page, reason: .manual)
        let savedStyle = try DocumentStyleRepository(database: first, store: files).save(title: "Saved style", definition: DocumentStyleDefinition(appearance: .plain))
        let daily = DailyNoteRepository(database: first, templates: templates)
        daily.spaceID = template.spaceID
        try daily.setDefaultTemplate(template.templateID)
        let note = try daily.createOrFind(day: DailyNoteDay(key: "2026-10-18")!, attachmentStore: files)
        try deliver(source, to: target, sourceFiles: files, targetFiles: restoredFiles)
        let loadedTemplates = TemplateRepository(database: second)
        #expect(try loadedTemplates.editingDocument(id: template.templateID!).id == template.id)
        let loadedDaily = DailyNoteRepository(database: second, templates: loadedTemplates)
        loadedDaily.spaceID = template.spaceID
        #expect(try loadedDaily.defaultTemplate()?.id == template.templateID)
        #expect(try DocumentRepository(database: second).requireDocument(id: note.id).dailyNoteDate == "2026-10-18")
        #expect(try DocumentRepository(database: second).requireDocument(id: page.id).appearanceJSON == page.appearanceJSON)
        #expect(try SnapshotRepository(database: second).history(documentID: page.id).count == 1)
        #expect(try DocumentTaskRepository(database: second).completedOccurrences().map(\.id).contains("finished-occurrence"))
        #expect(try DocumentStyleRepository(database: second, store: restoredFiles).all().contains(where: { $0.id == savedStyle.id }))
    }

    @Test func offlineJournalAndPausedBindingSurviveReopeningSQLite() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let root = try AppDatabase(DatabaseQueue(path: path.path), isInMemory: true)
        let owner = "email:durability"
        let library = try LibraryRepository(database: root).accountLibrary(ownerKey: owner)
        let source = LibrarySyncStore(database: root, libraryID: library.id, ownerKey: owner, cloudAccountID: "cloud")
        try source.enable(confirmed: true)
        let page = try DocumentRepository(database: root.scoped(to: library.id)).create(DocumentDraft(title: "Offline"))
        let reopened = try AppDatabase(DatabaseQueue(path: path.path), isInMemory: true)
        let restored = LibrarySyncStore(database: reopened, libraryID: library.id, ownerKey: owner, cloudAccountID: "cloud")
        #expect(try restored.pending().contains(where: { $0.row.values["id"]?.text == page.id }))
        try restored.pause("Temporary import failure")
        #expect(throws: (any Error).self) { try restored.state() }
        try restored.prepareRetry()
        #expect(try restored.state() == nil)
        #expect(try restored.pending().contains(where: { $0.row.values["id"]?.text == page.id }))
        try restored.pause(LibrarySyncError.zoneRemoved.localizedDescription)
        #expect(throws: (any Error).self) { try restored.prepareRetry() }
        try restored.prepareRetry(restoringRemovedZone: true)
        #expect(try DocumentRepository(database: reopened.scoped(to: library.id)).requireDocument(id: page.id).title == "Offline")
    }

    @Test func stagedIncomingDependencySurvivesReopeningBeforeItsParentArrives() throws {
        let (_, first, source) = try fixture()
        try source.enable(confirmed: true)
        let page = try DocumentRepository(database: first).create(DocumentDraft(title: "Interrupted download"))
        let files = try attachmentStore(), targetFiles = try attachmentStore()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let root = try AppDatabase(DatabaseQueue(path: path.path), isInMemory: true)
        let library = try LibraryRepository(database: root).accountLibrary(ownerKey: source.ownerKey)
        let target = LibrarySyncStore(database: root, libraryID: library.id, ownerKey: source.ownerKey, cloudAccountID: source.cloudAccountID)
        try target.enable(confirmed: true)
        let item = try source.pending().first { $0.row.table == "documents" }!
        try target.stageIncoming(source.makeRecord(item, attachments: files), attachments: targetFiles)
        _ = try target.applyIncoming()
        #expect(try target.incomingCount() == 1)
        let reopened = try AppDatabase(DatabaseQueue(path: path.path), isInMemory: true)
        let restored = LibrarySyncStore(database: reopened, libraryID: library.id, ownerKey: source.ownerKey, cloudAccountID: source.cloudAccountID)
        #expect(try restored.incomingCount() == 1)
        for parent in try source.pending() where parent.row.table == "spaces" {
            try restored.stageIncoming(source.makeRecord(parent, attachments: files), attachments: targetFiles)
        }
        _ = try restored.applyIncoming()
        #expect(try restored.incomingCount() == 0)
        #expect(try DocumentRepository(database: reopened.scoped(to: library.id)).requireDocument(id: page.id).title == "Interrupted download")
    }

    @Test func remoteParentDeletionRetainsAnUnsyncedAttachmentAndItsRecoveryGraph() throws {
        let (_, first, source) = try fixture(), (_, second, target) = try fixture()
        let sourceFiles = try attachmentStore(), targetFiles = try attachmentStore()
        try source.enable(confirmed: true); try target.enable(confirmed: true)
        let docs = DocumentRepository(database: first)
        let parent = try docs.create(DocumentDraft(title: "Parent"))
        try deliver(source, to: target, sourceFiles: sourceFiles, targetFiles: targetFiles)
        let file = try AttachmentRepository(database: second, store: targetFiles).importData(Data("unsent bytes".utf8), originalFileName: "unsent.txt", mimeType: "text/plain", documentID: parent.id)
        try docs.permanentlyDelete(id: parent.id)
        try deliver(source, to: target, sourceFiles: sourceFiles, targetFiles: targetFiles)
        let revisions = try target.conflicts()
        let savedParent = try #require(revisions.first { $0.row.table == "documents" })
        let savedAttachment = try #require(revisions.first { $0.row.values["id"]?.text == file.id })
        #expect(try target.pending().isEmpty)
        try target.recover(conflictID: savedParent.id)
        try target.recover(conflictID: savedAttachment.id)
        #expect(try AttachmentRepository(database: second, store: targetFiles).attachments(for: parent.id).count == 1)
        #expect(try Data(contentsOf: targetFiles.fileURL(relativePath: file.relativePath)) == Data("unsent bytes".utf8))
    }

    @Test func ownAcknowledgedOldRevisionCannotOverwriteANewerOfflineEdit() throws {
        let (_, scoped, sync) = try fixture()
        let files = try attachmentStore()
        try sync.enable(confirmed: true)
        let docs = DocumentRepository(database: scoped)
        let page = try docs.create(DocumentDraft(title: "Old"))
        let old = try sync.pending().first { $0.row.table == "documents" }!
        let record = try sync.makeRecord(old, attachments: files)
        _ = try docs.updateTitle(id: page.id, title: "Newer offline edit")
        try sync.acknowledge(record)
        try sync.stageIncoming(record, attachments: files)
        _ = try sync.applyIncoming()
        #expect(try docs.requireDocument(id: page.id).title == "Newer offline edit")
        #expect(try sync.pending().contains(where: { $0.row.recordName == old.row.recordName }))
        #expect(try sync.conflicts().isEmpty)
    }

    @Test func missingAssetsStayQueuedAndInvalidDownloadsNeverEnterTheInbox() throws {
        let (_, scoped, source) = try fixture(), (_, _, target) = try fixture()
        let files = try attachmentStore(), targetFiles = try attachmentStore()
        try source.enable(confirmed: true); try target.enable(confirmed: true)
        let page = try DocumentRepository(database: scoped).create(DocumentDraft(title: "File"))
        let file = try AttachmentRepository(database: scoped, store: files).importData(Data("bytes".utf8), originalFileName: "file.txt", mimeType: "text/plain", documentID: page.id)
        let item = try source.pending().first { $0.row.table == "attachments" }!
        let record = try source.makeRecord(item, attachments: files)
        record["fileHashes"] = ["invalid-checksum"] as CKRecordValue
        #expect(throws: (any Error).self) { try target.stageIncoming(record, attachments: targetFiles) }
        #expect(try target.incomingCount() == 0)
        try files.removeFile(relativePath: file.relativePath)
        #expect(throws: (any Error).self) { try source.makeRecord(item, attachments: files) }
        #expect(try source.pending().contains(where: { $0.row.recordName == item.row.recordName }))
    }

    @Test func acknowledgedTombstonesDoNotUploadOrRetainDeletedContentInTheJournal() throws {
        let (_, scoped, source) = try fixture()
        try source.enable(confirmed: true)
        let docs = DocumentRepository(database: scoped)
        let page = try docs.create(DocumentDraft(title: "Private deleted title", tipTapJSON: TipTapContentAnalyzer.starterDocument(title: "", lines: ["Private deleted body"])))
        try docs.permanentlyDelete(id: page.id)
        let item = try #require(source.pending().first { $0.row.table == "documents" })
        let record = try source.makeRecord(item, attachments: attachmentStore())
        let payload = try Data(contentsOf: #require((record["payload"] as? CKAsset)?.fileURL))
        #expect(!String(decoding: payload, as: UTF8.self).contains("Private deleted"))
        #expect(record["files"] == nil && record["filePaths"] == nil)
        try source.acknowledge(record)
        let stored = try source.database.read { try Data.fetchOne($0, sql: "SELECT payload FROM librarySyncItems WHERE libraryID=? AND recordName=?", arguments: [source.libraryID, item.row.recordName])! }
        #expect(!String(decoding: stored, as: UTF8.self).contains("Private deleted"))
    }

    @Test func aCorruptedStagingCacheIsRebuiltBeforeAnUpload() throws {
        let (_, scoped, sync) = try fixture()
        try sync.enable(confirmed: true)
        _ = try DocumentRepository(database: scoped).create(DocumentDraft(title: "Safe payload"))
        let item = try #require(sync.pending().first { $0.row.table == "documents" })
        let files = try attachmentStore()
        _ = try sync.makeRecord(item, attachments: files)
        let data = try item.row.encoded
        let cached = files.syncDirectory.appendingPathComponent(sync.libraryID).appendingPathComponent(SyncRow.digest(data))
        try Data("corrupt cache".utf8).write(to: cached)
        let rebuilt = try sync.makeRecord(item, attachments: files)
        #expect(try Data(contentsOf: #require((rebuilt["payload"] as? CKAsset)?.fileURL)) == data)
    }

    @Test func aSpaceTransferWaitsForCoMovingChildrenInsteadOfRejectingAPartialBatch() throws {
        let (_, first, source) = try fixture(), (_, second, target) = try fixture()
        let files = try attachmentStore(), targetFiles = try attachmentStore()
        try source.enable(confirmed: true); try target.enable(confirmed: true)
        let docs = DocumentRepository(database: first)
        let parent = try docs.create(DocumentDraft(title: "Moving parent"))
        let child = try docs.create(DocumentDraft(title: "Moving child", parentDocumentID: parent.id))
        let destination = try SpaceRepository(database: first).create(title: "Destination")
        try deliver(source, to: target, sourceFiles: files, targetFiles: targetFiles)
        try SpaceRepository(database: first).transfer(.document(parent.id), from: parent.spaceID!, to: destination.id, copy: false, store: files)
        let changes = try source.pending()
        let movingParent = try #require(changes.first { $0.row.values["id"]?.text == parent.id })
        try target.stageIncoming(source.makeRecord(movingParent, attachments: files), attachments: targetFiles)
        _ = try target.applyIncoming()
        #expect(try target.incomingCount() == 1)
        #expect(try DocumentRepository(database: second).requireDocument(id: parent.id).spaceID == parent.spaceID)
        for item in changes where item.row.recordName != movingParent.row.recordName {
            try target.stageIncoming(source.makeRecord(item, attachments: files), attachments: targetFiles)
        }
        _ = try target.applyIncoming()
        #expect(try target.incomingCount() == 0)
        #expect(try DocumentRepository(database: second).requireDocument(id: parent.id).spaceID == destination.id)
        #expect(try DocumentRepository(database: second).requireDocument(id: child.id).spaceID == destination.id)
    }

    @Test func echoedOldTemplateCannotUndoANewerTemplateRename() throws {
        let (_, scoped, sync) = try fixture()
        try sync.enable(confirmed: true)
        let templates = TemplateRepository(database: scoped)
        let root = try templates.create(title: "Original template")
        let old = try #require(sync.pending().first { $0.row.table == "templates" })
        let files = try attachmentStore()
        let sent = try sync.makeRecord(old, attachments: files)
        try templates.rename(id: root.templateID!, title: "Newer template name")
        try sync.acknowledge(sent)
        try sync.stageIncoming(sent, attachments: files)
        _ = try sync.applyIncoming()
        #expect(try templates.all().first?.title == "Newer template name")
    }

    @Test func physicalDeletionRecoveryCanCreateANewCloudRecordWithTheOriginalID() throws {
        let (_, scoped, sync) = try fixture()
        try sync.enable(confirmed: true)
        let docs = DocumentRepository(database: scoped)
        let page = try docs.create(DocumentDraft(title: "Original"))
        let files = try attachmentStore()
        for item in try sync.pending() { try sync.acknowledge(sync.makeRecord(item, attachments: files)) }
        _ = try docs.updateTitle(id: page.id, title: "Unsynced local version")
        let item = try #require(sync.pending().first { $0.row.table == "documents" })
        let id = CKRecord.ID(recordName: item.row.recordName, zoneID: sync.zoneID)
        try sync.stagePhysicalDeletion(id)
        _ = try sync.applyIncoming()
        let revision = try #require(sync.conflicts().first { $0.row.table == "documents" })
        try sync.recover(conflictID: revision.id)
        let recovered = try #require(sync.pending().first { $0.row.table == "documents" })
        #expect(recovered.systemFields == nil)
        #expect(try sync.makeRecord(recovered, attachments: files).recordID == id)
    }

    @Test func concurrentDailyNoteIdentityConflictsRetainBothCopiesUntilExplicitResolution() throws {
        let (_, first, source) = try fixture(), (_, second, target) = try fixture()
        let files = try attachmentStore(), targetFiles = try attachmentStore()
        try source.enable(confirmed: true); try target.enable(confirmed: true)
        let templates = TemplateRepository(database: first)
        let template = try templates.create(title: "Daily")
        let daily = DailyNoteRepository(database: first, templates: templates)
        daily.spaceID = template.spaceID; try daily.setDefaultTemplate(template.templateID)
        try deliver(source, to: target, sourceFiles: files, targetFiles: targetFiles)
        let targetDaily = DailyNoteRepository(database: second, templates: TemplateRepository(database: second))
        targetDaily.spaceID = template.spaceID
        let day = DailyNoteDay(key: "2026-10-18")!
        let remote = try daily.createOrFind(day: day, attachmentStore: files)
        let local = try targetDaily.createOrFind(day: day, attachmentStore: targetFiles)
        #expect(remote.id != local.id)
        do {
            try deliver(source, to: target, sourceFiles: files, targetFiles: targetFiles)
            Issue.record("A duplicate Daily Note must require an explicit choice")
        } catch let error as LibrarySyncError {
            guard case .requiresResolution(let name, _) = error else { throw error }
            try target.archiveStagedRevision(recordName: name, reason: error.localizedDescription)
        }
        #expect(try target.conflicts().contains(where: { $0.row.values["id"]?.text == remote.id }))
        #expect(try target.incomingCount() > 0)
        _ = try DocumentRepository(database: second).trash(id: local.id)
        _ = try target.applyIncoming()
        #expect(try DocumentRepository(database: second).requireDocument(id: local.id).isTrashed)
        #expect(try DocumentRepository(database: second).requireDocument(id: remote.id).dailyNoteDate == day.key)
    }

    @Test func synchronizationIsOptInAndCannotRebindToAnotherICloudIdentity() throws {
        let (root, _, sync) = try fixture()
        #expect(throws: LibraryError.syncDisabled) { try sync.pending() }
        #expect(throws: LibraryError.confirmationRequired) { try sync.enable(confirmed: false) }
        try sync.enable(confirmed: true)
        let foreign = LibrarySyncStore(database: root, libraryID: sync.libraryID, ownerKey: sync.ownerKey, cloudAccountID: "iCloud-B")
        #expect(throws: LibraryError.cloudIdentityChanged) { try foreign.pending() }
        #expect(throws: LibraryError.cloudIdentityChanged) { try foreign.enable(confirmed: true) }
    }

    @Test func journalCommitsAtomicallyAndAcknowledgmentDoesNotDiscardNewerEdits() throws {
        let (_, scoped, sync) = try fixture()
        try sync.enable(confirmed: true)
        let docs = DocumentRepository(database: scoped)
        let page = try docs.create(DocumentDraft(title: "Original"))
        let pending = try sync.pending().first { $0.row.values["id"]?.text == page.id }!
        #expect(throws: LibraryError.confirmationRequired) {
            try scoped.write { db in
                try db.execute(sql: "UPDATE documents SET title='Rolled back' WHERE id=?", arguments: [page.id])
                throw LibraryError.confirmationRequired
            }
        }
        #expect(try sync.pending().first { $0.row.recordName == pending.row.recordName }?.version == pending.version)
        _ = try docs.updateTitle(id: page.id, title: "New offline edit")
        let ack = CKRecord(recordType: "PennedLibraryRecord", recordID: CKRecord.ID(recordName: pending.row.recordName, zoneID: sync.zoneID))
        ack["mutationID"] = pending.mutationID
        try sync.acknowledge(ack)
        #expect(try sync.pending().first { $0.row.recordName == pending.row.recordName }?.row.values["title"]?.text == "New offline edit")
        try docs.permanentlyDelete(id: page.id)
        #expect(try sync.pending().contains { $0.row.recordName == pending.row.recordName && $0.deleted })
    }
}
