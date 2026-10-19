import Foundation
import Testing
import GRDB
@testable import Vellix

@MainActor struct DocumentTagTests {
    @MainActor struct Fixture {
        let db: AppDatabase
        let documents: DocumentRepository
        let tags: DocumentTagRepository
        let space: String
        init() throws {
            db = try .makeInMemory()
            documents = DocumentRepository(database: db)
            tags = DocumentTagRepository(database: db)
            space = try SpaceRepository(database: db).fallback(preferred: nil)
            documents.spaceID = space; tags.spaceID = space
        }
    }
    private func tag(_ name: String, id: String = UUID().uuidString) -> [String: Any] {
        ["type": "inlineTag", "attrs": ["id": id, "name": name]]
    }
    private func paragraph(_ id: String, _ names: [String], text: String = "Actual content") -> [String: Any] {
        ["type": "paragraph", "attrs": ["id": id], "content": names.map { tag($0) } + [["type": "text", "text": " " + text]]]
    }
    private func json(_ blocks: [[String: Any]]) throws -> String { try TipTapContentAnalyzer.makeDocumentJSON(content: blocks) }
    private func save(_ f: Fixture, _ blocks: [[String: Any]], title: String = "Journal", parent: String? = nil) throws -> DocumentRecord {
        try f.documents.create(DocumentDraft(title: title, parentDocumentID: parent, tipTapJSON: json(blocks)))
    }

    @Test func nameValidationUniquenessAndSpaceIsolation() throws {
        let f = try Fixture()
        let first = try f.tags.resolve("#Journals"), second = try f.tags.resolve("journals")
        #expect(first.id == second.id && first.normalizedName == "journals")
        #expect(TagName.normalized("Cafe\u{301}") == TagName.normalized("CAFÉ"))
        #expect(try f.tags.resolve("Straße").id == f.tags.resolve("STRASSE").id)
        for input in ["", "#", "a b", "a/b", "<script>", String(repeating: "a", count: 81)] {
            #expect(throws: (any Error).self) { try f.tags.resolve(input) }
        }
        let other = try SpaceRepository(database: f.db).create(title: "Other")
        f.tags.spaceID = other.id
        #expect(try f.tags.catalogue().isEmpty)
        #expect(try f.tags.resolve("Journals").id != first.id)
    }

    @Test func completeThreeBlockWorkflowDeduplicationFilteringAndDeletion() throws {
        let f = try Fixture()
        let doc = try save(f, [paragraph("one", ["journals", "JOURNALS"], text: "First"), paragraph("two", ["journals", "rituals"], text: "Second"), paragraph("three", ["journals"], text: "Third")])
        let journals = try f.tags.resolve("journals"), rituals = try f.tags.resolve("rituals")
        let found = try f.tags.snapshot(selected: [journals.id])
        #expect(found.documents.count == 1 && found.documentCounts[journals.id] == 1)
        #expect(found.documents[0].blocks.map(\.blockID) == ["one", "two", "three"])
        #expect(found.documents[0].blocks[0].text.contains("#journals#JOURNALS First"))
        #expect(try f.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM documentTagOccurrences") } == 5)
        let third = found.documents[0].blocks[2]
        let target = TagNavigationTarget(documentID: doc.id, blockID: third.blockID, occurrenceID: third.occurrenceIDs[journals.id])
        #expect(try f.tags.targetIsAvailable(target))
        #expect(try f.tags.snapshot(selected: [journals.id, rituals.id]).documents[0].blocks.count == 3)
        #expect(try f.tags.snapshot(selected: [rituals.id]).documents[0].blocks.map(\.blockID) == ["two"])
        _ = try f.documents.saveEditorJSON(id: doc.id, canonicalJSON: json([paragraph("one", ["journals"]), paragraph("two", ["journals", "rituals"])]))
        #expect(try f.tags.snapshot(selected: [journals.id]).documents[0].blocks.count == 2)
        #expect(try !f.tags.targetIsAvailable(target))
        let reopened = try f.documents.requireDocument(id: doc.id)
        #expect(DocumentTagIndex.blocks(in: reopened.tipTapJSON).map(\.id) == ["one", "two"])
        let freshRepository = DocumentTagRepository(database: f.db); freshRepository.spaceID = f.space
        #expect(try freshRepository.snapshot(selected: [journals.id]).documents[0].blocks.count == 2)
    }

    @Test func plainHashtagsAreNotIndexedAndSwappingFinalOccurrencesUpdatesAssociations() throws {
        let f = try Fixture(), doc = try save(f, [paragraph("block", ["journals", "journals"])])
        let journals = try f.tags.resolve("journals")
        _ = try f.documents.saveEditorJSON(id: doc.id, canonicalJSON: json([paragraph("block", ["journals", "research"])]))
        #expect(try f.tags.snapshot(selected: [journals.id]).documents[0].blocks.count == 1)
        _ = try f.documents.saveEditorJSON(id: doc.id, canonicalJSON: json([paragraph("block", ["research"], text: "#journals is plain text")] ))
        #expect(try f.tags.snapshot(selected: [journals.id]).documents.isEmpty)
        #expect(try f.tags.snapshot().documents[0].blocks[0].text.contains("#journals is plain text"))
        _ = try f.documents.saveEditorJSON(id: doc.id, canonicalJSON: json([paragraph("block", [], text: "#research #journals")]))
        #expect(try f.tags.snapshot().documents.isEmpty)
    }

    @Test func nestedBreadcrumbsRootCountsReferenceOrderAndAncestorEligibility() throws {
        let f = try Fixture()
        let root = try save(f, [paragraph("root", ["journals"])], title: "Dashboard")
        let last = try save(f, [paragraph("last", ["rituals"], text: "last nested page")], title: "November 9", parent: root.id)
        let first = try save(f, [paragraph("first", ["journals"])], title: "November 8", parent: root.id)
        _ = try f.documents.saveEditorJSON(id: root.id, canonicalJSON: json([paragraph("root", ["journals"]),
            ["type": "pageReference", "attrs": ["documentID": first.id]], ["type": "pageReference", "attrs": ["documentID": last.id]]]))
        let journals = try f.tags.resolve("journals"), rituals = try f.tags.resolve("rituals")
        let result = try f.tags.snapshot(selected: [journals.id, rituals.id])
        #expect(result.documents.map(\.id) == [root.id])
        #expect(result.documents[0].blocks.map(\.blockID) == ["root", "first", "last"])
        #expect(result.documents[0].blocks[2].breadcrumbs == ["Dashboard", "November 9"])
        #expect(try f.tags.snapshot(query: "nested").documents.map(\.id) == [root.id])
        #expect(try f.tags.snapshot(query: "November", titleOnly: true).documents.count == 1)
        try f.db.write { try $0.execute(sql: "UPDATE documents SET isTrashed=1 WHERE id=?", arguments: [root.id]) }
        #expect(try f.tags.snapshot().documents.isEmpty)
        try f.db.write { try $0.execute(sql: "UPDATE documents SET isTrashed=0 WHERE id=?", arguments: [root.id]) }
        #expect(try f.tags.snapshot().documents[0].blocks.count == 3)
    }

    @Test func duplicatesHaveIndependentDocumentTargetsAndSharedTagIdentity() throws {
        let f = try Fixture(), doc = try save(f, [paragraph("block", ["journals"])])
        let duplicate = try f.documents.duplicate(id: doc.id)
        let snapshot = try f.tags.snapshot()
        #expect(snapshot.documents.count == 2)
        #expect(Set(snapshot.documents.flatMap(\.blocks).map(\.id)).count == 2)
        #expect(try f.tags.catalogue().count == 1)
        _ = try f.documents.saveEditorJSON(id: duplicate.id, canonicalJSON: json([paragraph("new", ["rituals"])]))
        #expect(DocumentTagIndex.blocks(in: try f.documents.requireDocument(id: doc.id).tipTapJSON)[0].occurrences[0].name == "journals")
        try f.db.write { try $0.execute(sql: "DELETE FROM documents WHERE id=?", arguments: [duplicate.id]) }
        #expect(try f.tags.snapshot().documents.map(\.id) == [doc.id])
        #expect(try f.db.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
    }

    @Test func pastedDuplicateIDsAreRepairedWithoutChangingExistingTargets() throws {
        let nodes = [paragraph("block", ["journals"]), paragraph("block", ["rituals"])]
        let canonical = try json(nodes)
        let blocks = DocumentTagIndex.blocks(in: canonical)
        #expect(blocks[0].id == "block" && blocks[1].id != "block")
        #expect(try TipTapContentAnalyzer.analyze(canonical).canonicalJSON == canonical)
        #expect(try TipTapContentAnalyzer.analyze(canonical).plainText.contains("#journals"))
        #expect(TipTapContentAnalyzer.hasInlineTags(in: canonical))
        #expect(!TipTapContentAnalyzer.hasInlineTags(in: TipTapContentAnalyzer.starterDocument(title: "Plain", lines: ["inlineTag"])))
        #expect(DocumentTagIndex.blocks(in: TipTapContentAnalyzer.emptyDocumentJSON).isEmpty)
    }

    @Test func staleTagIDsCannotLeakAcrossSpaces() throws {
        let f = try Fixture(), oldTag = try f.tags.resolve("journals")
        let other = try SpaceRepository(database: f.db).create(title: "Private")
        f.documents.spaceID = other.id; f.tags.spaceID = other.id
        let node: [String: Any] = ["type": "paragraph", "attrs": ["id": "p"], "content": [["type": "inlineTag", "attrs": ["id": "t", "name": "journals", "tagID": oldTag.id]]]]
        let copy = try save(f, [node])
        let current = try f.tags.resolve("journals")
        #expect(current.id != oldTag.id)
        #expect(try f.tags.snapshot(selected: [oldTag.id]).documents.isEmpty)
        #expect(try f.tags.snapshot(selected: [current.id]).documents.map(\.id) == [copy.id])
        f.tags.spaceID = f.space
        #expect(try f.tags.snapshot().documents.isEmpty)
    }

    @Test func diskReopenPreservesCatalogueIndicesAndExactNavigationTargets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var documentID = "", tagID = "", occurrenceID = ""
        do {
            let db = try AppDatabase(DatabaseQueue(path: url.path), isInMemory: true)
            let documents = DocumentRepository(database: db), tags = DocumentTagRepository(database: db)
            let doc = try documents.create(DocumentDraft(title: "Persistent", tipTapJSON: json([paragraph("block", ["journals"])])))
            documentID = doc.id; tagID = try tags.resolve("Journals").id
            occurrenceID = try #require(tags.snapshot().documents.first?.blocks.first?.occurrenceIDs[tagID])
            _ = try tags.resolve("Unused-but-reusable")
        }
        let reopened = try AppDatabase(DatabaseQueue(path: url.path), isInMemory: true)
        let tags = DocumentTagRepository(database: reopened)
        #expect(try tags.resolve("journals").id == tagID)
        #expect(try tags.catalogue().count == 2)
        #expect(try tags.snapshot().documents.map(\.id) == [documentID])
        #expect(try tags.targetIsAvailable(TagNavigationTarget(documentID: documentID, blockID: "block", occurrenceID: occurrenceID)))
    }

    @Test func migrationBackfillsStructuredTagsWithoutConvertingHistoricalHashtags() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.vellixMigrator.migrate(queue, upTo: "v18_daily_notes")
        let tagged = try json([paragraph("p", ["journals"])]), plain = try json([paragraph("plain", [], text: "#journals")])
        try queue.write { db in
            let space = try SpaceOwnership.defaultSpace(in: db)
            try DocumentRecord(id: "tagged", title: "Tagged", tipTapJSON: tagged, spaceID: space).insert(db)
            try DocumentRecord(id: "plain", title: "Plain", tipTapJSON: plain, spaceID: space).insert(db)
        }
        let migrated = try AppDatabase(queue, isInMemory: true), tags = DocumentTagRepository(database: migrated)
        #expect(try tags.snapshot().documents.map(\.id) == ["tagged"])
        #expect(try DocumentRepository(database: migrated).requireDocument(id: "plain").tipTapJSON == plain)
    }

    @Test func failedSaveRollsBackDocumentAndTagIndexTogether() throws {
        let f = try Fixture(), doc = try save(f, [paragraph("p", ["journals"])])
        #expect(throws: VellixError.self) {
            try f.db.write { db in
                try db.execute(sql: "UPDATE documents SET tipTapJSON=? WHERE id=?", arguments: [json([paragraph("p", ["research"])]), doc.id])
                throw VellixError.database("Deliberate rollback")
            }
        }
        #expect(try f.tags.catalogue().map(\.normalizedName) == ["journals"])
        #expect(try f.tags.snapshot().documents[0].blocks[0].text.contains("#journals"))
    }

    @Test func movingNestedPagesAndTaggedBlocksUpdatesRootsBreadcrumbsAndPositions() throws {
        let f = try Fixture(), first = try save(f, [paragraph("one", ["journals"])], title: "First")
        let second = try save(f, [], title: "Second")
        let child = try save(f, [paragraph("stable", ["journals"])], title: "Child", parent: first.id)
        try f.db.write { try $0.execute(sql: "UPDATE documents SET parentDocumentID=? WHERE id=?", arguments: [second.id, child.id]) }
        let moved = try #require(f.tags.snapshot().documents.first { $0.id == second.id }?.blocks.first)
        #expect(moved.breadcrumbs == ["Second", "Child"] && moved.blockID == "stable")
        #expect(try f.tags.targetIsAvailable(TagNavigationTarget(documentID: child.id, blockID: "stable")))
        _ = try f.documents.saveEditorJSON(id: child.id, canonicalJSON: json([paragraph("new", ["rituals"]), paragraph("stable", ["journals"])]))
        #expect(try f.tags.snapshot().documents.first { $0.id == second.id }?.blocks.map(\.blockID) == ["new", "stable"])
    }

    @Test func templateAndDailyNoteCopiesKeepTagsWithIndependentBlockAndOccurrenceIDs() throws {
        let f = try Fixture(), templates = TemplateRepository(database: f.db)
        templates.spaceID = f.space
        let root = try templates.create(title: "Daily")
        let saved = try f.documents.saveEditorJSON(id: root.id, canonicalJSON: json([paragraph("template-block", ["journals"])]))
        let daily = DailyNoteRepository(database: f.db, templates: templates); daily.spaceID = f.space
        try daily.setDefaultTemplate(root.templateID)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let note = try daily.createOrFind(day: DailyNoteDay(key: "2026-10-16")!, attachmentStore: AttachmentStore(rootURL: path))
        let snapshot = try f.tags.snapshot()
        #expect(snapshot.documents.map(\.id) == [note.id])
        let source = DocumentTagIndex.blocks(in: saved.tipTapJSON)[0], copy = snapshot.documents[0].blocks[0]
        #expect(source.id != copy.blockID && source.occurrences[0].id != copy.occurrenceIDs.values.first)
    }

    @Test func actualEditorRoundTripRetainsIndexCountsAndNavigationAfterReopeningSQLite() throws {
        guard let path = ProcessInfo.processInfo.environment["PENNED_TAGS_EDITOR_EXCHANGE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase(DatabaseQueue(path: directory.appendingPathComponent("tags.sqlite").path), isInMemory: true)
        let documents = DocumentRepository(database: database), tags = DocumentTagRepository(database: database)
        let response = directory.appendingPathComponent("response.json"), input = directory.appendingPathComponent("input.json")
        if FileManager.default.fileExists(atPath: response.path) {
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
            let documentID = fixture["documentID"] as! String
            let returned = try JSONSerialization.jsonObject(with: Data(contentsOf: response))
            let saved = try documents.saveEditorJSON(id: documentID, canonicalJSON: TipTapContentAnalyzer.normalizePayloadToJSON(returned))
            let journals = try tags.resolve("journals"), rituals = try tags.resolve("rituals")
            #expect(try tags.snapshot(selected: [journals.id]).documents[0].blocks.count == 2)
            #expect(try tags.snapshot(selected: [journals.id, rituals.id]).documents[0].blocks.count == 3)
            let reopened = try AppDatabase(DatabaseQueue(path: directory.appendingPathComponent("tags.sqlite").path), isInMemory: true)
            let reloaded = DocumentTagRepository(database: reopened)
            #expect(try DocumentRepository(database: reopened).requireDocument(id: documentID).tipTapJSON == saved.tipTapJSON)
            #expect(try reloaded.snapshot(selected: [journals.id]).documents[0].blocks.map(\.blockID) == ["one", "two"])
            #expect(try !reloaded.targetIsAvailable(TagNavigationTarget(documentID: documentID, blockID: "three")))
            for block in try reloaded.snapshot().documents[0].blocks {
                #expect(try reloaded.targetIsAvailable(TagNavigationTarget(documentID: block.documentID, blockID: block.blockID, occurrenceID: block.occurrenceIDs.values.first)))
            }
        } else {
            let doc = try documents.create(DocumentDraft(title: "Editor Exchange", tipTapJSON: json([
                paragraph("one", ["journals", "journals"], text: "First block"), paragraph("two", ["journals"], text: "Second block"),
                paragraph("three", ["journals"], text: "Third block"), paragraph("four", [], text: "#rituals")
            ])))
            let payload: [String: Any] = ["documentID": doc.id, "document": TipTapContentAnalyzer.documentObject(from: doc.tipTapJSON),
                "tags": try tags.catalogue().map { ["id": $0.id, "name": $0.name] }]
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: input)
        }
    }

    @Test func tagsInTablesCalloutsAndChecklistsUseTheContainingTextBlock() throws {
        let f = try Fixture()
        let doc = try save(f, [
            ["type": "table", "content": [["type": "tableRow", "content": [["type": "tableCell", "content": [paragraph("cell", ["research"])]]]]]],
            ["type": "plainCallout", "content": [paragraph("callout-text", ["research"])]],
            ["type": "taskList", "content": [["type": "taskItem", "attrs": ["id": "task"], "content": [paragraph("task-text", ["research"])]]]]
        ])
        let results = try f.tags.snapshot()
        #expect(results.documents[0].blocks.map(\.blockID) == ["cell", "callout-text", "task-text"])
        #expect(DocumentTaskIndex.texts(in: doc.tipTapJSON)["task"]?.contains("#research") == true)
    }
}
