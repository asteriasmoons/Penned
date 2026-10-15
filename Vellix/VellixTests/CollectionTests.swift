import Foundation
import GRDB
import Testing
import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import Vellix

@MainActor
struct CollectionTests {
    @Test func nativeCollectionPreviewImagesContainPersistedViewsAndColumnColors() throws {
        guard let directory = ProcessInfo.processInfo.environment["PENNED_COLLECTION_PREVIEW_IMAGES_DIR"] else { return }
        #if canImport(AppKit)
        _ = NSApplication.shared
        #endif
        let f = try Fixture(), id = f.collection.record.id
        let priority = try f.field("Priority", kind: .select, options: ["High", "Low"])
        let first = try f.repository.addEntry(collectionID: id, title: "Water Prep")
        try f.repository.saveValue(collectionID: id, documentID: first.id, fieldID: priority.id, value: CollectionValue(optionIDs: [priority.configuration.options[0].id]))
        let attachmentRoot = FileManager.default.temporaryDirectory.appendingPathComponent("penned-native-preview-\(UUID().uuidString)")
        let attachments = AttachmentStore(rootURL: attachmentRoot)
        defer { try? FileManager.default.removeItem(at: attachmentRoot) }
        if let assets = ProcessInfo.processInfo.environment["PENNED_COLLECTION_ASSETS"] {
            let image = try Data(contentsOf: URL(fileURLWithPath: assets).appendingPathComponent("AppIcon.appiconset/original 1.png"))
            let cover = try attachments.importData(image, originalFileName: "Cover.png", mimeType: "image/png", documentID: first.id)
            try f.database.write { try cover.insert($0) }
            var appearance = first.appearance; appearance.enableCustomLayout(); appearance.showsCover = true
            _ = try f.documents.updateAppearance(id: first.id, cover: cover.relativePath, appearance: appearance)
        }
        _ = try f.repository.addEntry(collectionID: id, title: "Hygiene Check")
        _ = try f.repository.addEntry(collectionID: id, title: "Daily Note")
        _ = try f.repository.addEntry(collectionID: id, title: "Dog Care")
        let table = try f.repository.addView(collectionID: id, name: "All Tasks", kind: .table)
        let board = try f.repository.addView(collectionID: id, name: "Routines", kind: .kanban)
        let column = try f.repository.addKanbanColumn(collectionID: id, viewID: board.id, name: "Health", color: "#503A71")
        try f.repository.moveKanbanEntry(collectionID: id, viewID: board.id, documentID: first.id, columnID: column.id)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, viewID) in [("gallery", f.collection.views[0].id), ("table", table.id), ("kanban", board.id)] {
            try f.repository.selectView(collectionID: id, viewID: viewID)
            let snapshot = try f.repository.snapshot(id: id)
            let renderer = ImageRenderer(content: CollectionSnapshotPreview(snapshot: snapshot, appearance: .plain, attachments: attachments)
                .frame(width: 320).background(Color(vellixHex: "#242424")).environment(\.colorScheme, .dark))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == 640 && image.height > 80)
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }

    @Test func presentationWaitsForNativeLayoutAndRejectsStaleDocumentCompletion() {
        var state = DocumentPresentationState()
        state.begin(documentID: "first")
        let first = state.startPreparation()
        state.prepared(generation: first, nativeViews: ["block": "view"])
        #expect(!state.isReady)
        state.nativeDidLayout(blockID: "block", viewID: "old-view")
        #expect(!state.isReady)
        state.nativeDidLayout(blockID: "block", viewID: "view")
        #expect(state.isContentReady && !state.isReady)
        state.framePresented(generation: first)
        #expect(state.isReady)
        state.begin(documentID: "second")
        state.prepared(generation: first, nativeViews: [:])
        #expect(!state.isReady)
        let second = state.startPreparation()
        state.prepared(generation: second, nativeViews: [:])
        state.framePresented(generation: second)
        #expect(state.isReady)
    }

    @Test func collectionPreviewUsesSharedDataAndInvalidatesWithoutChangingParentJSON() throws {
        let f = try Fixture(), id = f.collection.record.id
        let field = try f.field("Priority", kind: .select, options: ["High", "Low"])
        let entry = try f.repository.addEntry(collectionID: id, title: "Care")
        let first = try f.repository.previewContent(for: f.owner, documents: f.documents)
        #expect(first.hasResolvedCollections && first.payloads.first?["name"] as? String == "Small Favors")
        #expect(first.children.isEmpty, "Collection rows must not load full document bodies for previews")
        try f.repository.saveValue(collectionID: id, documentID: entry.id, fieldID: field.id,
            value: CollectionValue(optionIDs: [field.configuration.options[0].id]))
        let changed = try f.repository.previewContent(for: f.owner, documents: f.documents)
        #expect(first.cacheKey != changed.cacheKey)
        #expect(try f.documents.requireDocument(id: f.owner.id).tipTapJSON == f.owner.tipTapJSON)
        let fields = try f.repository.previewContent(for: entry, documents: f.documents)
        #expect(fields.entryContext?.1.values[field.id]?.optionIDs == [field.configuration.options[0].id])
    }

    @Test func repreparingKeepsValidNativeLayoutsButWaitsForTheSelectedView() {
        var state = DocumentPresentationState()
        state.begin(documentID: "page")
        state.nativeDidLayout(blockID: "board", viewID: "main")
        let first = state.startPreparation()
        let replacement = state.startPreparation()
        state.prepared(generation: first, nativeViews: [:])
        #expect(!state.isReady)
        state.prepared(generation: replacement, nativeViews: ["board": "main"])
        state.framePresented(generation: first)
        #expect(!state.isReady)
        state.framePresented(generation: replacement)
        #expect(state.isReady)
        let changedView = state.startPreparation()
        state.prepared(generation: changedView, nativeViews: ["board": "routines"])
        #expect(!state.isReady)
        state.nativeDidLayout(blockID: "board", viewID: "routines")
        state.framePresented(generation: changedView)
        #expect(state.isReady)
        let table = state.startPreparation()
        state.prepared(generation: table, nativeViews: [:])
        state.framePresented(generation: table)
        #expect(state.isReady)
    }

    @Test func previewFingerprintTracksKanbanColumnsCoversAndViewChangesButNotOpening() throws {
        let f = try Fixture(), id = f.collection.record.id
        let board = try f.repository.addView(collectionID: id, name: "Routines", kind: .kanban)
        let entry = try f.repository.addEntry(collectionID: id, title: "Care")
        let first = try f.repository.previewContent(for: f.owner, documents: f.documents)
        try f.repository.updateKanbanColumn(collectionID: id, viewID: board.id, columnID: CollectionKanbanColumn.inboxID, color: "#445566", collapsed: true)
        let recolored = try f.repository.previewContent(for: f.owner, documents: f.documents)
        #expect(first.cacheKey != recolored.cacheKey)
        var appearance = entry.appearance; appearance.enableCustomLayout(); appearance.showsCover = true
        _ = try f.documents.updateAppearance(id: entry.id, cover: "covers/test.png", appearance: appearance)
        let covered = try f.repository.previewContent(for: f.owner, documents: f.documents)
        #expect(recolored.cacheKey != covered.cacheKey)
        try f.repository.selectView(collectionID: id, viewID: f.collection.views[0].id)
        let gallery = try f.repository.previewContent(for: f.owner, documents: f.documents)
        #expect(covered.cacheKey != gallery.cacheKey)
        var opened = f.owner; opened.lastOpenedAt = .now; opened.isFavorite = true
        #expect(gallery.cacheKey == DocumentPreviewContent.cacheKey(opened, children: gallery.children, collections: gallery.collections))
    }

    @Test func previewFingerprintSurvivesCollectionEncodingAndCollectionOrder() throws {
        let f = try Fixture()
        let other = try f.repository.create(ownerID: f.owner.id, name: "Other", viewName: "Main", kind: .kanban)
        let snapshots = [try f.repository.snapshot(id: f.collection.record.id), other]
        let restored = try JSONDecoder().decode([CollectionSnapshot].self, from: JSONEncoder().encode(snapshots))
        #expect(DocumentPreviewContent.cacheKey(f.owner, children: [], collections: snapshots)
            == DocumentPreviewContent.cacheKey(f.owner, children: [], collections: restored.reversed()))
    }

    @Test func collectionViewMenuSymbolsExistOnTheCurrentPlatform() {
        let symbols = CollectionViewKind.allCases.map(\.systemIcon) + ["plus.square.on.square"]
        #expect(CollectionViewKind.kanban.icon == "sf:rectangle.split.3x1")
        for symbol in symbols {
            #if canImport(UIKit)
            #expect(UIImage(systemName: symbol) != nil, "Missing collection menu symbol: \(symbol)")
            #elseif canImport(AppKit)
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "Missing collection menu symbol: \(symbol)")
            #endif
        }
    }

    private struct Fixture {
        let database: AppDatabase
        let documents: DocumentRepository
        let repository: CollectionRepository
        let owner: DocumentRecord
        let collection: CollectionSnapshot
        init(database: AppDatabase? = nil) throws {
            let database = try database ?? AppDatabase.makeInMemory()
            self.database = database
            documents = DocumentRepository(database: database)
            repository = CollectionRepository(database: database, documents: documents)
            let document = try documents.create(DocumentDraft(title: "Notebook"))
            collection = try repository.create(ownerID: document.id, name: "Small Favors", viewName: "Main", kind: .gallery)
            let block = TipTapContentAnalyzer.documentObject(from: try CollectionRepository.blockJSON(collectionID: collection.record.id, documentID: collection.record.documentID))["content"] as! [Any]
            owner = try documents.saveEditorJSON(id: document.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: block))
        }
        func field(_ name: String, kind: CollectionFieldKind, options: [String] = []) throws -> CollectionField {
            var field = CollectionField(collectionID: collection.record.id, name: name, kind: kind)
            var config = field.configuration
            config.options = options.map { InlinePropertyOption(name: $0, color: "#714FAB") }
            field.configuration = config
            try repository.saveField(field)
            return try repository.snapshot(id: collection.record.id).field(field.id)!
        }
    }

    @Test func oldViewJSONKeepsItsSettingsWhenKanbanFieldsAreAbsent() throws {
        let data = Data("""
            {"filters":[{"id":"filter","fieldID":"$title","operation":"contains","value":{"text":"Care","optionIDs":[]}}],"matchAll":false,"sorts":[{"id":"sort","fieldID":"$title","ascending":false}],"visibleFieldIDs":["priority"],"galleryColumns":3,"showsCover":false,"compactCards":true}
            """.utf8)
        let config = try JSONDecoder().decode(CollectionViewConfiguration.self, from: data)
        #expect(!config.matchAll && !config.showsCover && config.compactCards && config.galleryColumns == 3)
        #expect(config.filters[0].value.text == "Care" && !config.sorts[0].ascending && config.visibleFieldIDs == ["priority"])
        #expect(config.kanbanColumns == [.inbox] && config.kanbanAssignments.isEmpty)
        #expect(try JSONDecoder().decode(CollectionViewConfiguration.self, from: JSONEncoder().encode(config)) == config)
    }

    @Test func kanbanSharesDocumentsAndPropertiesWithIndependentViewAssignments() throws {
        let f = try Fixture(), id = f.collection.record.id
        let field = try f.field("Priority", kind: .select, options: ["High", "Low"])
        let board = try f.repository.addView(collectionID: id, name: "Board", kind: .kanban)
        let health = try f.repository.addKanbanColumn(collectionID: id, viewID: board.id, name: "Health", color: "#503A71")
        let entry = try f.repository.addEntry(collectionID: id, title: "Water Prep", kanbanViewID: board.id, columnID: health.id)
        try f.repository.saveValue(collectionID: id, documentID: entry.id, fieldID: field.id, value: CollectionValue(optionIDs: [field.configuration.options[0].id]))
        let another = try f.repository.addView(collectionID: id, name: "Another Board", kind: .kanban)
        var snapshot = try f.repository.snapshot(id: id)
        #expect(snapshot.kanbanGroups(in: snapshot.views.first { $0.id == board.id }!)[1].entries[0].id == entry.id)
        #expect(snapshot.kanbanGroups(in: another)[0].entries[0].id == entry.id)
        #expect(snapshot.presentedEntries(in: snapshot.views[0])[0].values[field.id]?.optionIDs == [field.configuration.options[0].id])
        #expect(try f.documents.children(of: f.owner.id).count == 1)
        try f.repository.moveKanbanEntry(collectionID: id, viewID: board.id, documentID: entry.id, columnID: CollectionKanbanColumn.inboxID)
        snapshot = try f.repository.snapshot(id: id)
        #expect(snapshot.kanbanGroups(in: snapshot.views.first { $0.id == board.id }!)[0].entries.map(\.id) == [entry.id])
        #expect(snapshot.entries[0].values[field.id]?.optionIDs == [field.configuration.options[0].id])
    }

    @Test func kanbanColumnReorderingDoesNotMoveImplicitEntriesAndDeletionPreservesDocuments() throws {
        let f = try Fixture(), id = f.collection.record.id
        let board = try f.repository.addView(collectionID: id, name: "Board", kind: .kanban)
        let second = try f.repository.addKanbanColumn(collectionID: id, viewID: board.id, name: "Second", color: "#3C6479")
        let entry = try f.repository.addEntry(collectionID: id, title: "Outside Board")
        try f.repository.reorderKanbanColumns(collectionID: id, viewID: board.id, ids: [second.id, CollectionKanbanColumn.inboxID])
        var snapshot = try f.repository.snapshot(id: id)
        #expect(snapshot.kanbanGroups(in: snapshot.activeView!)[1].entries[0].id == entry.id)
        try f.repository.deleteKanbanColumn(collectionID: id, viewID: board.id, columnID: CollectionKanbanColumn.inboxID, destinationID: second.id)
        snapshot = try f.repository.snapshot(id: id)
        #expect(snapshot.kanbanGroups(in: snapshot.activeView!)[0].entries[0].id == entry.id)
        #expect(try f.documents.requireDocument(id: entry.id).isTrashed == false)
        do { try f.repository.deleteKanbanColumn(collectionID: id, viewID: board.id, columnID: second.id, destinationID: second.id); Issue.record("Deleted the final column") } catch {}
    }

    @Test func kanbanCardOrderFiltersSortsAndStaleSettingsRemainConsistent() throws {
        let f = try Fixture(), id = f.collection.record.id
        var board = try f.repository.addView(collectionID: id, name: "Board", kind: .kanban)
        let a = try f.repository.addEntry(collectionID: id, title: "A Care"), b = try f.repository.addEntry(collectionID: id, title: "B Care")
        let c = try f.repository.addEntry(collectionID: id, title: "C Other")
        try f.repository.moveKanbanEntry(collectionID: id, viewID: board.id, documentID: b.id, columnID: CollectionKanbanColumn.inboxID, beforeID: a.id)
        var snapshot = try f.repository.snapshot(id: id)
        #expect(snapshot.kanbanGroups(in: snapshot.activeView!)[0].entries.map(\.id) == [b.id, a.id, c.id])
        try f.repository.updateKanbanColumn(collectionID: id, viewID: board.id, columnID: CollectionKanbanColumn.inboxID, color: "#864E74", collapsed: true)
        var config = board.configuration
        config.filters = [CollectionFilter(value: CollectionValue(text: "Care"))]
        config.sorts = [CollectionSort()]
        board.configuration = config; try f.repository.saveView(board)
        snapshot = try f.repository.snapshot(id: id)
        #expect(snapshot.kanbanGroups(in: snapshot.activeView!)[0].entries.map(\.id) == [a.id, b.id])
        #expect(snapshot.activeView!.configuration.kanbanColumns[0].collapsed)
        #expect(snapshot.activeView!.configuration.kanbanColumns[0].color == "#864E74")
        do { try f.repository.moveKanbanEntry(collectionID: id, viewID: board.id, documentID: b.id, columnID: CollectionKanbanColumn.inboxID, beforeID: a.id); Issue.record("Reordered while sorted") } catch {}
        #expect(snapshot.entries.count == 3)
    }

    @Test func kanbanDiskReopenPreservesColorsCollapseOrderAndAssignments() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("penned-kanban-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        var id = "", entryID = "", columnID = "", viewID = ""
        do {
            let f = try Fixture(database: AppDatabase(DatabaseQueue(path: path))); id = f.collection.record.id
            let board = try f.repository.addView(collectionID: id, name: "Board", kind: .kanban); viewID = board.id
            let column = try f.repository.addKanbanColumn(collectionID: id, viewID: board.id, name: "Custom", color: "#123ABC"); columnID = column.id
            entryID = try f.repository.addEntry(collectionID: id, title: "Saved", kanbanViewID: board.id, columnID: column.id).id
            try f.repository.updateKanbanColumn(collectionID: id, viewID: board.id, columnID: column.id, collapsed: true)
            try f.repository.reorderKanbanColumns(collectionID: id, viewID: board.id, ids: [column.id, CollectionKanbanColumn.inboxID])
        }
        let db = try AppDatabase(DatabaseQueue(path: path)), documents = DocumentRepository(database: db)
        let snapshot = try CollectionRepository(database: db, documents: documents).snapshot(id: id)
        #expect(snapshot.activeView?.id == viewID && snapshot.activeView?.kind == .kanban)
        let config = snapshot.activeView!.configuration
        #expect(config.kanbanColumns[0].id == columnID && config.kanbanColumns[0].color == "#123ABC" && config.kanbanColumns[0].collapsed)
        #expect(config.kanbanAssignments[entryID] == columnID && config.kanbanEntryOrder[columnID] == [entryID])
    }

    @Test func kanbanViewAndDocumentDuplicationPreserveConfigurationWithoutCrossLinking() throws {
        let f = try Fixture(), id = f.collection.record.id
        let board = try f.repository.addView(collectionID: id, name: "Board", kind: .kanban)
        let column = try f.repository.addKanbanColumn(collectionID: id, viewID: board.id, name: "Custom", color: "#234567")
        let entry = try f.repository.addEntry(collectionID: id, title: "Shared", kanbanViewID: board.id, columnID: column.id)
        let duplicate = try f.repository.addView(collectionID: id, name: "Duplicate", kind: .kanban, duplicateID: board.id)
        #expect(duplicate.configuration.kanbanAssignments[entry.id] == column.id)
        let copy = try f.documents.duplicate(id: f.owner.id)
        let copied = try f.repository.snapshot(id: f.repository.collectionIDs(forDocument: copy.id)[0])
        #expect(copied.entries.count == 1 && copied.entries[0].id != entry.id)
        #expect(copied.activeView!.configuration.kanbanAssignments[copied.entries[0].id] == column.id)
        #expect(copied.activeView!.configuration.kanbanAssignments[entry.id] == nil)
        try f.repository.deleteView(collectionID: id, viewID: board.id)
        #expect(try f.repository.snapshot(id: id).entries.map(\.id) == [entry.id])
    }

    @Test func kanbanInvalidOwnershipAndMissingColumnCreationAreAtomic() throws {
        let f = try Fixture(), id = f.collection.record.id
        let board = try f.repository.addView(collectionID: id, name: "Board", kind: .kanban)
        let other = try f.repository.create(ownerID: f.owner.id, name: "Other", viewName: "Main", kind: .gallery)
        let entry = try f.repository.addEntry(collectionID: other.record.id, title: "Other")
        do { try f.repository.moveKanbanEntry(collectionID: id, viewID: board.id, documentID: entry.id, columnID: CollectionKanbanColumn.inboxID); Issue.record("Accepted foreign document") } catch {}
        do { _ = try f.repository.addEntry(collectionID: id, title: "Invalid", kanbanViewID: board.id, columnID: "missing"); Issue.record("Accepted missing column") } catch {}
        do { _ = try f.repository.addKanbanColumn(collectionID: id, viewID: board.id, name: "Invalid", color: "garbage"); Issue.record("Accepted invalid color") } catch {}
        #expect(try f.repository.snapshot(id: id).entries.isEmpty)
        #expect(try f.documents.children(of: f.owner.id).count == 1)
    }

    @Test func duplicatedKanbanEntryKeepsItsColumnValuesAndAdjacentPosition() throws {
        let f = try Fixture(), id = f.collection.record.id
        let board = try f.repository.addView(collectionID: id, name: "Board", kind: .kanban)
        let column = try f.repository.addKanbanColumn(collectionID: id, viewID: board.id, name: "Health", color: "#345678")
        let field = try f.field("Note", kind: .text)
        let entry = try f.repository.addEntry(collectionID: id, title: "Care", kanbanViewID: board.id, columnID: column.id)
        try f.repository.saveValue(collectionID: id, documentID: entry.id, fieldID: field.id, value: CollectionValue(text: "Shared schema"))
        let copy = try f.documents.duplicate(id: entry.id)
        let snapshot = try f.repository.snapshot(id: id)
        #expect(snapshot.kanbanGroups(in: snapshot.activeView!)[1].entries.map(\.id) == [entry.id, copy.id])
        #expect(snapshot.entries.first { $0.id == copy.id }?.values[field.id]?.text == "Shared schema")
        #expect(copy.parentDocumentID == entry.parentDocumentID && copy.id != entry.id)
    }

    @Test func kanbanTrashAndRestoreRetainColumnAndCardPosition() throws {
        let f = try Fixture(), id = f.collection.record.id
        let board = try f.repository.addView(collectionID: id, name: "Board", kind: .kanban)
        let column = try f.repository.addKanbanColumn(collectionID: id, viewID: board.id, name: "Health", color: "#345678")
        let entry = try f.repository.addEntry(collectionID: id, title: "Care", kanbanViewID: board.id, columnID: column.id)
        _ = try f.documents.trash(id: entry.id)
        #expect(try f.repository.snapshot(id: id).kanbanGroups(in: f.repository.snapshot(id: id).activeView!)[1].entries.isEmpty)
        try f.repository.updateKanbanColumn(collectionID: id, viewID: board.id, columnID: column.id, name: "Wellness")
        _ = try f.documents.restore(id: entry.id)
        let restored = try f.repository.snapshot(id: id)
        #expect(restored.kanbanGroups(in: restored.activeView!)[1].entries[0].id == entry.id)
        #expect(restored.activeView!.configuration.kanbanEntryOrder[column.id] == [entry.id])
    }

    @Test func kanbanBridgeOnlySendsPlacementMetadataAndViewTypeChangesKeepTheBoard() throws {
        let f = try Fixture(), id = f.collection.record.id
        var board = try f.repository.addView(collectionID: id, name: "Board", kind: .kanban)
        let column = try f.repository.addKanbanColumn(collectionID: id, viewID: board.id, name: "Custom", color: "#345678")
        let entry = try f.repository.addEntry(collectionID: id, title: "Care", kanbanViewID: board.id, columnID: column.id)
        let store = CollectionStore(repository: f.repository, database: f.database)
        store.watchDocument(f.owner.id)
        let payload = store.payloads(for: f.owner.id)[0]
        #expect(payload["kind"] as? String == "kanban" && payload["nativeHeight"] as? Double == 560)
        #expect(payload["entries"] == nil && payload["fields"] == nil)
        board.kind = .table; try f.repository.saveView(board)
        var snapshot = try f.repository.snapshot(id: id)
        #expect(snapshot.activeView!.configuration.kanbanAssignments[entry.id] == column.id)
        board.kind = .kanban; try f.repository.saveView(board)
        snapshot = try f.repository.snapshot(id: id)
        #expect(snapshot.kanbanGroups(in: snapshot.activeView!)[1].entries[0].id == entry.id)
    }

    @Test func collectionEntriesAreRealNestedDocumentsWithOneSharedIdentity() throws {
        let f = try Fixture()
        let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Dog Care")
        #expect(entry.parentDocumentID == f.collection.record.documentID)
        #expect(f.collection.record.documentID == f.owner.id)
        #expect(try f.documents.requireDocument(id: f.owner.id).parentDocumentID == nil)
        let table = try f.repository.addView(collectionID: f.collection.record.id, name: "All Tasks", kind: .table)
        let snapshot = try f.repository.snapshot(id: f.collection.record.id)
        #expect(snapshot.presentedEntries(in: table).map(\.id) == [entry.id])
        #expect(snapshot.presentedEntries(in: snapshot.views[0]).map(\.id) == [entry.id])
        #expect(try f.documents.children(of: f.collection.record.documentID).count == 1)
    }

    @Test func independentViewFiltersANDORAndPropertyEditsUseSharedValues() throws {
        let f = try Fixture()
        let priority = try f.field("Priority", kind: .select, options: ["High", "Low"])
        let category = try f.field("Category", kind: .select, options: ["Health", "Pets"])
        let first = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Water Prep")
        let second = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Dog Care")
        try f.repository.saveValue(collectionID: f.collection.record.id, documentID: first.id, fieldID: priority.id,
            value: CollectionValue(optionIDs: [priority.configuration.options[0].id]))
        try f.repository.saveValue(collectionID: f.collection.record.id, documentID: second.id, fieldID: category.id,
            value: CollectionValue(optionIDs: [category.configuration.options[1].id]))
        var view = try f.repository.addView(collectionID: f.collection.record.id, name: "High Priority", kind: .table)
        var config = view.configuration
        config.filters = [CollectionFilter(fieldID: priority.id, operation: .equals, value: CollectionValue(optionIDs: [priority.configuration.options[0].id])),
            CollectionFilter(fieldID: category.id, operation: .contains, value: CollectionValue(optionIDs: [category.configuration.options[1].id]))]
        view.configuration = config
        try f.repository.saveView(view)
        var snapshot = try f.repository.snapshot(id: f.collection.record.id)
        #expect(snapshot.presentedEntries(in: view).isEmpty)
        config.matchAll = false; view.configuration = config; try f.repository.saveView(view)
        snapshot = try f.repository.snapshot(id: f.collection.record.id)
        #expect(Set(snapshot.presentedEntries(in: view).map(\.id)) == [first.id, second.id])
        #expect(snapshot.views[0].configuration.filters.isEmpty)
        try f.repository.saveValue(collectionID: f.collection.record.id, documentID: second.id, fieldID: priority.id,
            value: CollectionValue(optionIDs: [priority.configuration.options[0].id]))
        config.matchAll = true; view.configuration = config
        snapshot = try f.repository.snapshot(id: f.collection.record.id)
        #expect(snapshot.presentedEntries(in: view).map(\.id) == [second.id])
    }

    @Test func numberDateTextCheckboxAndMultiselectFiltersAndSortPriority() throws {
        let f = try Fixture()
        let number = try f.field("Energy", kind: .number)
        let date = try f.field("Day", kind: .date)
        let checkbox = try f.field("Done", kind: .checkbox)
        let multi = try f.field("Obstacle", kind: .multiSelect, options: ["Time", "Memory"])
        let a = try f.repository.addEntry(collectionID: f.collection.record.id, title: "A Care")
        let b = try f.repository.addEntry(collectionID: f.collection.record.id, title: "B Care")
        for (entry, energy, day) in [(a, "80", "2026-10-14"), (b, "20", "2026-10-15")] {
            try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: number.id, value: CollectionValue(text: energy))
            try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: date.id, value: CollectionValue(text: day))
        }
        try f.repository.saveValue(collectionID: f.collection.record.id, documentID: a.id, fieldID: checkbox.id, value: CollectionValue(checked: false))
        try f.repository.saveValue(collectionID: f.collection.record.id, documentID: a.id, fieldID: multi.id,
            value: CollectionValue(optionIDs: multi.configuration.options.map(\.id)))
        let snapshot = try f.repository.snapshot(id: f.collection.record.id)
        var view = snapshot.views[0], config = view.configuration
        config.sorts = [CollectionSort(fieldID: number.id, ascending: true), CollectionSort(ascending: false)]
        view.configuration = config
        #expect(snapshot.presentedEntries(in: view).map(\.id) == [b.id, a.id])
        config.filters = [CollectionFilter(fieldID: number.id, operation: .greater, value: CollectionValue(text: "40")),
            CollectionFilter(fieldID: date.id, operation: .less, value: CollectionValue(text: "2026-10-15")),
            CollectionFilter(operation: .contains, value: CollectionValue(text: "care")),
            CollectionFilter(fieldID: checkbox.id, operation: .equals, value: CollectionValue(checked: false)),
            CollectionFilter(fieldID: multi.id, operation: .contains, value: CollectionValue(optionIDs: [multi.configuration.options[1].id]))]
        view.configuration = config
        #expect(snapshot.presentedEntries(in: view).map(\.id) == [a.id])
        config.filters = [CollectionFilter(fieldID: checkbox.id, operation: .isEmpty)]
        view.configuration = config
        #expect(snapshot.presentedEntries(in: view).map(\.id) == [b.id])
    }

    @Test func schemaRenameRetainsStableOptionsAndRemovingAssignedOptionsRequiresConsent() throws {
        let f = try Fixture()
        var field = try f.field("Category", kind: .select, options: ["Pets", "Health"])
        let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Dog Care")
        let optionID = field.configuration.options[0].id
        try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: field.id, value: CollectionValue(optionIDs: [optionID]))
        field.name = "Area"
        var config = field.configuration; config.options[0].name = "Animals"; config.options[0].color = "#FF499E"; field.configuration = config
        try f.repository.saveField(field)
        let snapshot = try f.repository.snapshot(id: f.collection.record.id)
        #expect(snapshot.entries[0].values[field.id]?.optionIDs == [optionID])
        #expect(snapshot.field(field.id)?.display(snapshot.entries[0].values[field.id]!) == "Animals")
        config.options.removeFirst(); field.configuration = config
        #expect(throws: CollectionIntegrityError.confirmationRequired) { try f.repository.saveField(field) }
        #expect(try f.repository.snapshot(id: f.collection.record.id).entries[0].values[field.id]?.optionIDs == [optionID])
        try f.repository.saveField(field, allowClearingValues: true)
        #expect(try f.repository.snapshot(id: f.collection.record.id).entries[0].values[field.id]?.optionIDs.isEmpty == true)
    }

    @Test func duplicatedViewsOnlyCopyConfigurationAndLastViewIsProtected() throws {
        let f = try Fixture()
        let field = try f.field("Priority", kind: .text)
        _ = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Daily Note")
        let duplicate = try f.repository.addView(collectionID: f.collection.record.id, name: "Copy", kind: .gallery, duplicateID: f.collection.views[0].id)
        let snapshot = try f.repository.snapshot(id: f.collection.record.id)
        #expect(snapshot.views.count == 2 && snapshot.fields.count == 1 && snapshot.entries.count == 1)
        #expect(duplicate.configuration.visibleFieldIDs == [field.id])
        try f.repository.deleteView(collectionID: f.collection.record.id, viewID: f.collection.views[0].id)
        do { try f.repository.deleteView(collectionID: f.collection.record.id, viewID: duplicate.id); Issue.record("Deleted the last view") }
        catch { #expect(try f.repository.snapshot(id: f.collection.record.id).entries.count == 1) }
    }

    @Test func fieldDeletionCleansOnlyItsValuesAndViewReferences() throws {
        let f = try Fixture()
        let deleted = try f.field("A", kind: .text), retained = try f.field("B", kind: .text)
        let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Daily Note")
        for field in [deleted, retained] { try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: field.id, value: CollectionValue(text: "Value")) }
        var view = try f.repository.snapshot(id: f.collection.record.id).views[0]
        var config = view.configuration; config.filters = [CollectionFilter(fieldID: deleted.id, value: CollectionValue(text: "Value"))]; config.sorts = [CollectionSort(fieldID: deleted.id)]; view.configuration = config
        try f.repository.saveView(view); try f.repository.deleteField(deleted)
        let saved = try f.repository.snapshot(id: f.collection.record.id)
        #expect(saved.fields.map(\.id) == [retained.id])
        #expect(saved.entries[0].values[retained.id]?.text == "Value")
        #expect(saved.views[0].configuration.filters.isEmpty && saved.views[0].configuration.sorts.isEmpty)
        #expect(saved.views[0].configuration.visibleFieldIDs == [retained.id])
    }

    @Test func foreignOwnershipIsRejectedAndTrashRestorePreservesValues() throws {
        let f = try Fixture()
        let field = try f.field("Note", kind: .text)
        let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Care")
        let other = try f.repository.create(ownerID: f.owner.id, name: "Other", viewName: "Main", kind: .table)
        let wrong = try f.repository.addEntry(collectionID: other.record.id, title: "Other Page")
        do { try f.repository.saveValue(collectionID: f.collection.record.id, documentID: wrong.id, fieldID: field.id, value: CollectionValue(text: "Wrong")); Issue.record("Accepted another collection's entry") }
        catch {}
        try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: field.id, value: CollectionValue(text: "Saved"))
        _ = try f.documents.trash(id: entry.id)
        #expect(try f.repository.snapshot(id: f.collection.record.id).entries.isEmpty)
        _ = try f.documents.restore(id: entry.id)
        #expect(try f.repository.snapshot(id: f.collection.record.id).entries[0].values[field.id]?.text == "Saved")
        try f.documents.permanentlyDelete(id: f.collection.record.documentID)
        #expect(try f.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collectionValues") } == 0)
    }

    @Test func documentAndTemplateCopyHaveIndependentCollectionsAndSharedViewsWithinEachCopy() throws {
        let f = try Fixture()
        let field = try f.field("Note", kind: .text)
        let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Dog Care")
        try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: field.id, value: CollectionValue(text: "Original"))
        let copy = try f.documents.duplicate(id: f.owner.id)
        let copiedID = try f.repository.collectionIDs(forDocument: copy.id)[0]
        let copied = try f.repository.snapshot(id: copiedID)
        #expect(copied.record.documentID == copy.id)
        #expect(TipTapContentAnalyzer.pageReferenceIDs(in: copy.tipTapJSON).isEmpty)
        #expect(copied.record.id != f.collection.record.id && copied.fields[0].id != field.id && copied.entries[0].id != entry.id)
        #expect(copied.entries[0].values[copied.fields[0].id]?.text == "Original")
        try f.repository.saveValue(collectionID: copiedID, documentID: copied.entries[0].id, fieldID: copied.fields[0].id, value: CollectionValue(text: "Copy"))
        #expect(try f.repository.snapshot(id: f.collection.record.id).entries[0].values[field.id]?.text == "Original")
        let templates = TemplateRepository(database: f.database)
        let template = try templates.saveUserTemplate(from: f.owner, title: "Favors")
        let store = AttachmentStore.previewStore()
        let instantiated = try templates.instantiate(id: template.id, title: "Instantiated", spaceID: nil, folderID: nil, parentID: nil, attachmentStore: store)
        let instantiatedID = try f.repository.collectionIDs(forDocument: instantiated.id)[0]
        #expect(instantiatedID != copiedID && instantiatedID != f.collection.record.id)
        #expect(try f.repository.snapshot(id: instantiatedID).entries.count == 1)
    }

    @Test func diskReopenPreservesFieldsValuesAndIndependentViewConfiguration() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("penned-collections-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        var id = "", fieldID = "", entryID = "", viewID = ""
        do {
            let f = try Fixture(database: AppDatabase(DatabaseQueue(path: path)))
            id = f.collection.record.id
            let field = try f.field("Duration", kind: .number); fieldID = field.id
            let entry = try f.repository.addEntry(collectionID: id, title: "Hygiene Check"); entryID = entry.id
            try f.repository.saveValue(collectionID: id, documentID: entry.id, fieldID: field.id, value: CollectionValue(text: "10"))
            var view = try f.repository.addView(collectionID: id, name: "Quick Tasks", kind: .table); viewID = view.id
            var config = view.configuration; config.filters = [CollectionFilter(fieldID: field.id, operation: .lessEqual, value: CollectionValue(text: "10"))]; view.configuration = config
            try f.repository.saveView(view)
        }
        let db = try AppDatabase(DatabaseQueue(path: path)), documents = DocumentRepository(database: db)
        let reopened = try CollectionRepository(database: db, documents: documents).snapshot(id: id)
        #expect(reopened.record.activeViewID == viewID)
        #expect(reopened.entries[0].id == entryID && reopened.entries[0].values[fieldID]?.text == "10")
        #expect(reopened.presentedEntries(in: reopened.activeView!).map(\.id) == [entryID])
    }

    @Test func reorderTypeChangesAndFilterOptionRemovalRemainConsistent() throws {
        let f = try Fixture()
        var field = try f.field("Priority", kind: .select, options: ["High", "Low"])
        let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Care")
        var view = try f.repository.addView(collectionID: f.collection.record.id, name: "High Priority", kind: .table)
        var config = view.configuration
        config.filters = [CollectionFilter(fieldID: field.id, operation: .equals, value: CollectionValue(optionIDs: [field.configuration.options[0].id]))]
        view.configuration = config; try f.repository.saveView(view)
        var definition = field.configuration; definition.options.removeFirst(); field.configuration = definition
        #expect(throws: CollectionIntegrityError.confirmationRequired) { try f.repository.saveField(field) }
        try f.repository.saveField(field, allowClearingValues: true)
        let saved = try f.repository.snapshot(id: f.collection.record.id)
        #expect(saved.views.first { $0.id == view.id }?.configuration.filters.isEmpty == true)
        let ids = saved.views.map(\.id).reversed()
        try f.repository.reorder(collectionID: saved.record.id, table: "collectionViews", ids: Array(ids))
        #expect(try f.repository.snapshot(id: saved.record.id).views.map(\.id) == Array(ids))
        let outside = try f.documents.create(DocumentDraft(title: "Outside"))
        do { _ = try f.documents.move(id: entry.id, spaceID: nil, folderID: nil, parentDocumentID: outside.id); Issue.record("Moved an entry out of its collection") }
        catch {}
        #expect(try f.repository.collectionID(forEntry: entry.id) == f.collection.record.id)
    }

    @Test func collectionBodiesStayOutOfEditorPrewarmingAndBridgeValuesAreLive() throws {
        let f = try Fixture()
        let field = try f.field("Note", kind: .text)
        let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Care")
        #expect(try !f.documents.editorDocuments(excludingCollectionEntries: true).contains { $0.id == entry.id })
        #expect(try f.documents.existingDocumentIDs().contains(entry.id))
        #expect(try f.documents.children(of: f.collection.record.documentID, includingCollectionEntries: false).isEmpty)
        let store = CollectionStore(repository: f.repository, database: f.database)
        store.watchDocument(f.owner.id)
        #expect(store.payloads(for: f.owner.id).count == 1)
        try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: field.id, value: CollectionValue(text: "Updated"))
        store.refresh()
        let payload = store.payloads(for: f.owner.id)[0]
        let entries = payload["entries"] as! [[String: Any]]
        let values = entries[0]["values"] as! [String: [String: Any]]
        #expect(values[field.id]?["text"] as? String == "Updated")
        store.watchDocument(entry.id)
        #expect(store.entryContext(entry.id)?.1.id == entry.id)
        store.unwatchDocument(entry.id)
        #expect(store.snapshots.isEmpty)
    }

    @Test func collectionsHaveNoSeparateDocumentAndNamesAreIndependentOfTheOwner() throws {
        let f = try Fixture()
        let second = try f.repository.create(ownerID: f.owner.id, name: "Second", viewName: "Table", kind: .table)
        #expect(second.record.documentID == f.owner.id)
        #expect(try f.documents.children(of: f.owner.id).isEmpty)
        #expect(try f.repository.collectionIDs(forDocument: f.owner.id).count == 2)
        try f.repository.rename(collectionID: second.record.id, name: "Renamed Collection")
        #expect(try f.repository.snapshot(id: second.record.id).name == "Renamed Collection")
        #expect(try f.documents.requireDocument(id: f.owner.id).title == "Notebook")
        #expect(try f.repository.snapshot(id: f.collection.record.id).name == "Small Favors")
    }

    @Test func collectionEntriesStartWithTheirOwnPlainStyleAndKeepLaterCustomizations() throws {
        let f = try Fixture()
        let parentStyle = DocumentAppearance.defaultForTheme(.neonCode)
        _ = try f.documents.updateAppearance(id: f.owner.id, cover: "parent.png", appearance: parentStyle)
        let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Independent")
        #expect(entry.appearance == .plain && entry.appearanceJSON == nil && entry.cover == nil)
        var ownStyle = DocumentAppearance.defaultForTheme(.lunarClouds)
        ownStyle.showsCover = true
        _ = try f.documents.updateAppearance(id: entry.id, cover: "entry.png", appearance: ownStyle)
        _ = try f.documents.updateAppearance(id: f.owner.id, cover: nil, appearance: .plain)
        #expect(try f.documents.requireDocument(id: entry.id).appearance == ownStyle)
        #expect(try f.documents.requireDocument(id: entry.id).cover == "entry.png")
    }

    @Test func inheritedStyleMigrationPreservesCoversAndIndependentlyEditedPageStyles() throws {
        var configuration = Configuration(); configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try DatabaseMigrator.vellixMigrator.migrate(queue, upTo: "v14_embedded_collections")
        let parentStyle = DocumentAppearance.defaultForTheme(.neonCode)
        let parent = DocumentRecord(title: "Styled Parent", appearanceJSON: parentStyle.encodedJSON())
        let inherited = parentStyle
        let entry = DocumentRecord(title: "Inherited", cover: "own-cover.png", appearanceJSON: inherited.encodedJSON(), parentDocumentID: parent.id)
        var custom = parentStyle; custom.fontStyle = .serif
        let independentlyStyled = DocumentRecord(title: "Custom", appearanceJSON: custom.encodedJSON(), parentDocumentID: parent.id)
        try queue.write { db in
            try parent.insert(db); try entry.insert(db); try independentlyStyled.insert(db)
            try CollectionRecord(id: "style-collection", documentID: parent.id, name: "Styles", activeViewID: "main").insert(db)
            try CollectionViewRecord(id: "main", collectionID: "style-collection", name: "Main", kind: .gallery).insert(db)
            for id in [entry.id, independentlyStyled.id] { try db.execute(sql: "INSERT INTO collectionEntries VALUES (?, 'style-collection', 0)", arguments: [id]) }
        }
        let database = try AppDatabase(queue), documents = DocumentRepository(database: database)
        let migrated = try documents.requireDocument(id: entry.id)
        #expect(migrated.appearance.editorBackground == DocumentAppearance.plain.editorBackground)
        #expect(migrated.appearance.innerPageBackground == DocumentAppearance.plain.innerPageBackground)
        #expect(migrated.appearance.textColorHex == DocumentAppearance.plain.textColorHex)
        #expect(migrated.cover == "own-cover.png" && migrated.appearance.displaysCover)
        #expect(migrated.appearance.resolvedCoverTheme == inherited.resolvedCoverTheme)
        #expect(try documents.requireDocument(id: independentlyStyled.id).appearance == custom)
        #expect(try documents.requireDocument(id: parent.id).appearance == parentStyle)
    }

    @Test func embeddedCollectionIDsRestorePayloadsEvenWhenThePresentationCacheIsEmpty() throws {
        let f = try Fixture()
        let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Make Coffee")
        let store = CollectionStore(repository: f.repository, database: f.database)
        #expect(store.snapshots.isEmpty)
        let first = store.payloads(for: f.owner.id)
        #expect(first.count == 1)
        #expect((first[0]["entries"] as! [[String: Any]])[0]["id"] as? String == entry.id)
        store.watchDocument(entry.id); store.unwatchDocument(entry.id)
        #expect(store.snapshots.isEmpty)
        #expect(store.payloads(for: f.owner.id).count == 1)
        #expect(TipTapContentAnalyzer.collectionIDs(in: f.owner.tipTapJSON) == [f.collection.record.id])
    }

    @Test func embeddedReferencesResolveExistingRecordsWithLegacyContainerOwnership() throws {
        let f = try Fixture()
        let legacyContainer = try f.documents.create(DocumentDraft(title: "Legacy Container", parentDocumentID: f.owner.id))
        try f.database.write { db in
            try db.execute(sql: "UPDATE collections SET documentID = ? WHERE id = ?", arguments: [legacyContainer.id, f.collection.record.id])
        }
        let store = CollectionStore(repository: f.repository, database: f.database)
        store.watchDocument(f.owner.id)
        #expect(store.payloads(for: f.owner.id).first?["id"] as? String == f.collection.record.id)
    }

    @Test func recoverCollectionFromActualDeviceDatabaseCopy() throws {
        guard let path = ProcessInfo.processInfo.environment["PENNED_COLLECTION_RECOVERY_DATABASE"] else { return }
        var configuration = Configuration(); configuration.readonly = true
        let source = try DatabaseQueue(path: path, configuration: configuration)
        let queue = try DatabaseQueue()
        try source.backup(to: queue)
        let before = try queue.read { db in try String.fetchAll(db, sql: "SELECT documentID FROM collectionEntries ORDER BY documentID") }
        let database = try AppDatabase(queue), documents = DocumentRepository(database: database)
        let repository = CollectionRepository(database: database, documents: documents)
        let owners = try database.read { db in try String.fetchAll(db, sql: "SELECT DISTINCT documentID FROM collections") }
        let store = CollectionStore(repository: repository, database: database)
        var payloads: [[String: Any]] = []
        for owner in owners {
            let document = try documents.requireDocument(id: owner)
            let ids = TipTapContentAnalyzer.collectionIDs(in: document.tipTapJSON)
            store.watchDocument(owner)
            let restored = store.payloads(for: owner)
            #expect(Set(restored.compactMap { $0["id"] as? String }).isSuperset(of: ids))
            #expect(store.errorMessage == nil)
            payloads.append(contentsOf: restored)
        }
        let after = try database.read { db in try String.fetchAll(db, sql: "SELECT documentID FROM collectionEntries ORDER BY documentID") }
        #expect(before == after && !before.isEmpty)
        #expect(payloads.contains { $0["name"] as? String == "Daily Tasks" })
        #expect(payloads.flatMap { $0["entries"] as? [[String: Any]] ?? [] }.contains { $0["title"] as? String == "Make Coffee" })
        let output = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("recovered-collection-payloads.json")
        try JSONSerialization.data(withJSONObject: payloads, options: [.sortedKeys]).write(to: output)
    }

    @Test func selectedFieldIconsPersistAndCopyWithoutChangingValues() throws {
        let f = try Fixture()
        var field = try f.field("Priority", kind: .text)
        let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Care")
        try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: field.id, value: CollectionValue(text: "High"))
        field.icon = "sf:flag.fill"; try f.repository.saveField(field)
        let store = CollectionStore(repository: f.repository, database: f.database); store.watchDocument(f.owner.id)
        let fields = store.payloads(for: f.owner.id)[0]["fields"] as! [[String: String]]
        #expect(fields[0]["icon"] == "sf:flag.fill")
        let copy = try f.documents.duplicate(id: f.owner.id)
        let copied = try f.repository.snapshot(id: f.repository.collectionIDs(forDocument: copy.id)[0])
        #expect(copied.fields[0].resolvedIcon == field.icon)
        #expect(copied.entries[0].values[copied.fields[0].id]?.text == "High")
    }

    @Test func legacyGeneratedPagesMigrateWithoutLosingEntriesFieldsViewsOrAuthoredText() throws {
        var configuration = Configuration(); configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try DatabaseMigrator.vellixMigrator.migrate(queue, upTo: "v13_document_collections")
        let owner = DocumentRecord(title: "Original Page")
        let generated = DocumentRecord(title: "Daily Tasks", tipTapJSON: try CollectionRepository.blockJSON(collectionID: "legacy", documentID: "wrapper"), parentDocumentID: owner.id)
        var wrapper = generated; wrapper.id = "wrapper"
        let authored = DocumentRecord(id: "authored", title: "Authored Wrapper", tipTapJSON: try TipTapContentAnalyzer.makeDocumentJSON(content: [
            ["type": "collection", "attrs": ["id": "node", "collectionID": "authored-collection", "documentID": "authored"]],
            ["type": "collection", "attrs": ["id": "inner", "collectionID": "nested-collection", "documentID": "nested"]],
            ["type": "paragraph", "content": [["type": "text", "text": "Keep this writing"]]]
        ]), parentDocumentID: owner.id)
        let entry = DocumentRecord(title: "Make Coffee", parentDocumentID: wrapper.id)
        let regularChild = DocumentRecord(title: "Keep this child", parentDocumentID: authored.id)
        let nested = DocumentRecord(id: "nested", title: "Nested", tipTapJSON: try CollectionRepository.blockJSON(collectionID: "nested-collection", documentID: "nested"), parentDocumentID: authored.id)
        try queue.write { db in
            try owner.insert(db); try wrapper.insert(db); try authored.insert(db); try entry.insert(db); try regularChild.insert(db); try nested.insert(db)
            for (id, doc) in [("legacy", wrapper.id), ("authored-collection", authored.id), ("nested-collection", nested.id)] {
                try db.execute(sql: "INSERT INTO collections VALUES (?, ?, ?, ?)", arguments: [id, doc, id + "-view", Date()])
                try CollectionViewRecord(id: id + "-view", collectionID: id, name: "Main", kind: .gallery).insert(db)
            }
            try db.execute(sql: "INSERT INTO collectionFields VALUES ('priority', 'legacy', 'Priority', 'text', '{}', 0)")
            try db.execute(sql: "INSERT INTO collectionEntries VALUES (?, 'legacy', 0)", arguments: [entry.id])
            try db.execute(sql: "INSERT INTO collectionValues VALUES (?, 'priority', ?)", arguments: [entry.id, "{\"text\":\"Medium\",\"optionIDs\":[]}"])
            var ownerContent = TipTapContentAnalyzer.documentObject(from: try CollectionRepository.blockJSON(collectionID: "legacy", documentID: wrapper.id))["content"] as! [Any]
            ownerContent.append(["type": "pageReference", "attrs": ["id": "link", "documentID": authored.id]])
            let ownerJSON = try TipTapContentAnalyzer.makeDocumentJSON(content: ownerContent)
            try db.execute(sql: "UPDATE documents SET tipTapJSON = ? WHERE id = ?", arguments: [ownerJSON, owner.id])
        }
        let database = try AppDatabase(queue), documents = DocumentRepository(database: database)
        let repository = CollectionRepository(database: database, documents: documents)
        let snapshot = try repository.snapshot(id: "legacy")
        #expect(snapshot.record.documentID == owner.id && snapshot.name == "Daily Tasks")
        #expect(snapshot.entries[0].id == entry.id && snapshot.entries[0].values["priority"]?.text == "Medium")
        #expect(try documents.requireDocument(id: entry.id).parentDocumentID == owner.id)
        #expect(try documents.requireDocument(id: wrapper.id).isTrashed)
        let retained = try documents.requireDocument(id: authored.id)
        #expect(!retained.isTrashed && retained.tipTapJSON.contains("Keep this writing"))
        #expect(!retained.tipTapJSON.contains("authored-collection"))
        #expect(try documents.requireDocument(id: regularChild.id).parentDocumentID == authored.id)
        #expect(try documents.requireDocument(id: owner.id).tipTapJSON.contains(authored.id))
        #expect(try repository.collectionIDs(forDocument: owner.id).count == 2)
        #expect(try repository.collectionIDs(forDocument: authored.id) == ["nested-collection"])
        #expect(try repository.snapshot(id: "nested-collection").record.documentID == authored.id)
        try database.read { try $0.checkForeignKeys() }
    }

    @Test func coversTitlesAndRichTextSurviveEntryCopiesAndAllViewsSeeTheSameCover() throws {
        let f = try Fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("penned-cover-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(rootURL: root)
        let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: "Dog Care")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ZkAAAAASUVORK5CYII=")!
        let attachment = try store.importData(png, originalFileName: "Cover.png", mimeType: "image/png", documentID: entry.id)
        try f.database.write { try attachment.insert($0) }
        var appearance = entry.appearance; appearance.enableCustomLayout(); appearance.showsCover = true
        _ = try f.documents.updateAppearance(id: entry.id, cover: attachment.relativePath, appearance: appearance)
        let json = try TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "paragraph", "content": [["type": "text", "text": "Formatted content", "marks": [["type": "bold"]]]]]])
        _ = try f.documents.saveEditorJSON(id: entry.id, canonicalJSON: json)
        _ = try f.documents.updateTitle(id: entry.id, title: "Dog Care Updated")
        let table = try f.repository.addView(collectionID: f.collection.record.id, name: "All Tasks", kind: .table)
        let snapshot = try f.repository.snapshot(id: f.collection.record.id)
        #expect(snapshot.presentedEntries(in: table)[0].cover == attachment.relativePath)
        #expect(snapshot.presentedEntries(in: snapshot.views[0])[0].title == "Dog Care Updated")
        let copy = try f.documents.duplicate(id: entry.id, attachmentStore: store)
        #expect(copy.cover != attachment.relativePath)
        #expect(try Data(contentsOf: store.fileURL(relativePath: copy.cover!)) == png)
        #expect(copy.tipTapJSON.contains("Formatted content") && copy.tipTapJSON.contains("bold"))
        var removed = appearance; removed.showsCover = false
        _ = try f.documents.updateAppearance(id: entry.id, cover: nil, appearance: removed)
        #expect(try f.repository.snapshot(id: f.collection.record.id).entries.first { $0.id == entry.id }?.cover == nil)
    }

    @Test func exportRealRepositoryFixtureForBrowserChecks() throws {
        guard let target = ProcessInfo.processInfo.environment["PENNED_COLLECTION_FIXTURE_PATH"],
              let assets = ProcessInfo.processInfo.environment["PENNED_COLLECTION_ASSETS"] else { return }
        let f = try Fixture()
        let priority = try f.field("Priority", kind: .select, options: ["High", "Medium", "Low"])
        let category = try f.field("Category", kind: .select, options: ["Health", "Hygiene", "Self-Care", "Pets"])
        let energy = try f.field("Energy", kind: .number)
        let day = try f.field("Day", kind: .select, options: ["Daily", "Weekly", "Monthly"])
        let duration = try f.field("Duration", kind: .number)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("penned-browser-covers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = AttachmentStore(rootURL: root)
        let imagePaths = ["AppIcon.appiconset/original 1.png", "AppIcon.appiconset/original 2.png", "AppIcon.appiconset/original 3.png", "ghostiepng.imageset/6.png"]
        var covers: [String: String] = [:]
        for (index, name) in ["Water Prep", "Hygiene Check", "Daily Note", "Dog Care"].enumerated() {
            let entry = try f.repository.addEntry(collectionID: f.collection.record.id, title: name)
            let image = try Data(contentsOf: URL(fileURLWithPath: assets).appendingPathComponent(imagePaths[index]))
            let attachment = try attachments.importData(image, originalFileName: "Cover.png", mimeType: "image/png", documentID: entry.id)
            try f.database.write { try attachment.insert($0) }
            covers[attachment.relativePath] = image.base64EncodedString()
            var appearance = entry.appearance; appearance.enableCustomLayout(); appearance.showsCover = true
            _ = try f.documents.updateAppearance(id: entry.id, cover: attachment.relativePath, appearance: appearance)
            try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: priority.id,
                value: CollectionValue(optionIDs: [priority.configuration.options[[0, 2, 1, 1][index]].id]))
            try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: category.id,
                value: CollectionValue(optionIDs: [category.configuration.options[index].id]))
            try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: energy.id, value: CollectionValue(text: String([40, 20, 60, 60][index])))
            try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: day.id,
                value: CollectionValue(optionIDs: [day.configuration.options[0].id]))
            try f.repository.saveValue(collectionID: f.collection.record.id, documentID: entry.id, fieldID: duration.id, value: CollectionValue(text: String([10, 5, 20, 10][index])))
        }
        let store = CollectionStore(repository: f.repository, database: f.database)
        store.watchDocument(f.owner.id)
        var variants: [String: Any] = ["gallery": store.payloads(for: f.owner.id)]
        _ = try f.repository.addView(collectionID: f.collection.record.id, name: "All Tasks", kind: .table)
        store.refresh(); variants["table"] = store.payloads(for: f.owner.id)
        var high = try f.repository.addView(collectionID: f.collection.record.id, name: "High Priority", kind: .table)
        var config = high.configuration
        config.filters = [CollectionFilter(fieldID: priority.id, operation: .equals, value: CollectionValue(optionIDs: [priority.configuration.options[0].id]))]
        high.configuration = config; try f.repository.saveView(high)
        store.refresh(); variants["high"] = store.payloads(for: f.owner.id)
        var pets = try f.repository.addView(collectionID: f.collection.record.id, name: "Pets", kind: .gallery)
        config = pets.configuration
        config.filters = [CollectionFilter(fieldID: category.id, operation: .equals, value: CollectionValue(optionIDs: [category.configuration.options[3].id]))]
        pets.configuration = config; try f.repository.saveView(pets)
        store.refresh(); variants["pets"] = store.payloads(for: f.owner.id)
        let data = try JSONSerialization.data(withJSONObject: ["document": TipTapContentAnalyzer.documentObject(from: f.owner.tipTapJSON), "variants": variants, "covers": covers], options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
    }
}
