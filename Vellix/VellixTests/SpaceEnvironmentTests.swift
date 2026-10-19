import Foundation
import Testing
@testable import Vellix

@MainActor
struct SpaceEnvironmentTests {
    @Test func closingLibrarySavesPendingJSONAndRevokesLateWrites() async throws {
        let root = try AppDatabase.makeInMemory()
        let scoped = root.scoped(to: LibraryRecord.localID)
        let app = try environment(scoped)
        let page = try app.documents.create(DocumentDraft(title: "Pending"))
        let model = app.editorCache.prepare(page)
        model.session.onEvent?(.documentChanged(TipTapContentAnalyzer.starterDocument(title: "Pending", lines: ["Saved before account switch"])))
        try await app.closeLibrary()
        #expect(try DocumentRepository(database: root).requireDocument(id: page.id).plainText.contains("Saved before account switch"))
        #expect(throws: LibraryError.staleWorkspace) { try app.documents.updateTitle(id: page.id, title: "Late") }
    }

    @Test func remoteImportFlushesEditorsAndUpdatesLoadedContentWithoutStaleRewrites() async throws {
        let app = try environment()
        let page = try app.documents.create(DocumentDraft(title: "Live editor"))
        let model = app.editorCache.prepare(page)
        model.session.onEvent?(.documentChanged(TipTapContentAnalyzer.starterDocument(title: "Local", lines: ["Unsaved local text"])))
        let remote = TipTapContentAnalyzer.starterDocument(title: "Remote", lines: ["Downloaded text"])
        try await app.importLibraryChanges {
            #expect(try app.documents.requireDocument(id: page.id).tipTapJSON.contains("Unsaved local text"))
            _ = try app.documents.saveEditorJSON(id: page.id, canonicalJSON: remote)
            return [page.id]
        }
        try model.saveCurrentContent()
        #expect(try app.documents.requireDocument(id: page.id).tipTapJSON.contains("Downloaded text"))
    }

    @Test func formattingBridgeDecodesActiveControlsAndRejectsUnknownAlignment() throws {
        let event = try TipTapEditorEvent(kind: "formattingState", payload: [
            "bold": true, "italic": true, "underline": true, "strike": true, "code": true,
            "alignment": "center", "checklist": true, "bulletList": false, "numberList": false
        ])
        #expect(event == .formattingStateChanged(TipTapFormattingState(bold: true, italic: true,
            underline: true, strike: true, code: true, alignment: "center", checklist: true)))
        #expect(TipTapFormattingState.decode(["alignment": "invalid", "bold": "true"]) == TipTapFormattingState())
        #expect(TipTapFormattingState.decode(["alignment": NSNull()]).alignment == nil)
    }

    @Test func formattingStateUpdatesWithoutSavingAndResetsBeforeAnotherDocumentLoads() {
        let session = TipTapEditorSession()
        var forwarded = [TipTapEditorEvent]()
        session.onEvent = { forwarded.append($0) }
        session.handleRawMessage(["kind": "formattingState", "payload": ["bold": true, "alignment": "right"]])
        #expect(session.formattingState.bold && session.formattingState.alignment == "right")
        #expect(forwarded.isEmpty && session.saveState == .idle)
        session.load(documentID: "another-document", canonicalJSON: "{}")
        #expect(session.formattingState == TipTapFormattingState())
        session.handleRawMessage(["kind": "formattingState", "payload": ["italic": true]])
        #expect(session.formattingState.italic)
        session.markNavigationStarted()
        #expect(session.formattingState == TipTapFormattingState())
    }

    @Test func dailyNoteCreationCommitsPendingTemplateEditsAndBridgeResponses() async throws {
        let app = try environment()
        let root = try app.templates.create(title: "Daily")
        try app.dailyNotes.setDefaultTemplate(root.templateID)
        let template = app.editorCache.prepare(root)
        var definition = TemplateComponentDefinition(kind: .rating); definition.label = "Current unsaved question"
        let json = try TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "templateComponent",
            "attrs": ["id": "rating", "definition": definition.object, "response": NSNull()]]])
        template.session.onEvent?(.documentChanged(json))
        let note = try await app.openDailyNote(day: DailyNoteDay(key: "2026-10-16")!)
        #expect(note.tipTapJSON.contains("Current unsaved question"))
        #expect(app.dailyNoteOnlyTemplateIDs.contains(root.templateID!))
        let model = app.editorCache.prepare(note)
        var object = TipTapContentAnalyzer.documentObject(from: note.tipTapJSON)
        var nodes = object["content"] as! [[String: Any]]
        var attrs = nodes[0]["attrs"] as! [String: Any]; attrs["response"] = 4; nodes[0]["attrs"] = attrs; object["content"] = nodes
        let snapshot = try TipTapEditorEvent(kind: "snapshot", payload: ["document": object])
        model.session.onEvent?(snapshot)
        try model.saveCurrentContent()
        #expect(try app.documents.requireDocument(id: note.id).tipTapJSON.contains("\"response\":4"))
        let request = try TipTapEditorEvent(kind: "templateComponentConfigure", payload: ["blockID": "rating", "definition": definition.object])
        template.session.onEvent?(request)
        #expect(template.templateComponentRequest?.definition == definition)
        model.session.onEvent?(request)
        #expect(model.templateComponentRequest == nil)
        for model in app.editorCache.preparedModels { model.discardPendingSave() }
    }

    private func environment(_ db: AppDatabase? = nil, preferences: UserDefaults? = nil) throws -> AppEnvironment {
        AppEnvironment(database: try db ?? AppDatabase.makeInMemory(), attachmentStore: AttachmentStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), preferences: preferences)
    }

    @Test func switchingScopesEveryLibrarySurfaceAndKeepsSelectionAcrossNavigation() async throws {
        let app = try environment()
        let first = try #require(app.selectedSpaceID)
        let page = try app.documents.create(DocumentDraft(title: "Private"))
        _ = try app.documents.setFavorite(id: page.id, isFavorite: true)
        _ = try app.templates.create(title: "Private Template")
        _ = try app.folders.create(title: "Private Folder")
        let second = try app.spaces.create(title: "Empty")
        app.refresh()
        try await app.switchSpace(to: second.id)
        #expect(app.overview.all.isEmpty && app.overview.recent.isEmpty && app.overview.favorites.isEmpty)
        #expect(app.overview.templates.isEmpty && app.overview.folders.isEmpty && app.overview.trashed.isEmpty)
        #expect(app.overview.templateDocuments.isEmpty)
        app.selectedDestination = .templates
        app.selectedDestination = .home
        #expect(app.selectedSpaceID == second.id)
        try await app.switchSpace(to: first)
        #expect(app.overview.all.first?.id == page.id)
        #expect(app.overview.templates.count == 1 && app.overview.folders.count == 1)
        #expect(app.overview.templateDocuments.count == 1)
        #expect(app.overview.templateDocuments.values.allSatisfy { $0.spaceID == first })
    }

    @Test func activePreferenceRestoresBeforeTheFirstRefreshAndRejectsArchivedSpaces() async throws {
        let db = try AppDatabase.makeInMemory()
        let preferences = try #require(UserDefaults(suiteName: "Penned.SpaceTests.\(UUID().uuidString)"))
        let app = try environment(db, preferences: preferences)
        let second = try app.spaces.create(title: "Selected")
        try await app.switchSpace(to: second.id)
        let reopened = try environment(db, preferences: preferences)
        #expect(reopened.selectedSpaceID == second.id && reopened.documents.spaceID == second.id)
        try app.spaces.archive(id: second.id)
        let recovered = try environment(db, preferences: preferences)
        #expect(recovered.selectedSpaceID != second.id)
    }

    @Test func pendingEditorJSONIsCommittedBeforeModelsAreEvicted() async throws {
        let app = try environment()
        let first = try #require(app.selectedSpaceID)
        let page = try app.documents.create(DocumentDraft(title: "Pending"))
        let model = app.editorCache.prepare(page)
        let json = TipTapContentAnalyzer.starterDocument(title: "Saved", lines: ["Do not lose this edit"])
        model.session.onEvent?(.documentChanged(json))
        let second = try app.spaces.create(title: "Other")
        try await app.switchSpace(to: second.id)
        #expect(app.editorCache.model(for: page.id) == nil)
        try await app.switchSpace(to: first)
        #expect(try app.documents.requireDocument(id: page.id).plainText.contains("Do not lose this edit"))
    }

    @Test func failedCommitPreventsSwitchingOrDiscardingTheEditor() async throws {
        let app = try environment()
        let first = app.selectedSpaceID
        let page = try app.documents.create(DocumentDraft(title: "Keep"))
        let model = app.editorCache.prepare(page)
        model.prepareForSpaceChange = { throw VellixError.database("Deliberate test failure") }
        let second = try app.spaces.create(title: "Other")
        await #expect(throws: VellixError.self) { try await app.switchSpace(to: second.id) }
        #expect(app.selectedSpaceID == first && app.editorCache.model(for: page.id) === model)
        #expect(!app.isSwitchingSpace)
    }

    @Test func notificationChangesSpaceBeforePreparingTheDestination() async throws {
        let app = try environment()
        let page = try app.documents.create(DocumentDraft(title: "Reminder destination"))
        let owner = app.selectedSpaceID
        let second = try app.spaces.create(title: "Other")
        try await app.switchSpace(to: second.id)
        try await app.openNotificationDocument(page.id)
        #expect(app.selectedSpaceID == owner && app.pendingDocumentID == page.id)
        #expect(app.editorCache.model(for: page.id)?.document?.spaceID == owner)
        try await app.archiveSpace(owner!, archived: true)
        await #expect(throws: VellixError.self) { try await app.openNotificationDocument(page.id) }
    }

    @Test func archiveRestoreAndDeleteTheActiveSpaceChooseValidEmptyFallbacks() async throws {
        let app = try environment()
        let first = try #require(app.selectedSpaceID)
        try await app.archiveSpace(first, archived: true)
        #expect(app.selectedSpaceID != first && app.overview.all.isEmpty)
        try await app.archiveSpace(first, archived: false)
        try await app.switchSpace(to: first)
        try await app.deleteSpace(first)
        #expect(app.selectedSpaceID != first && app.overview.all.isEmpty)
        #expect(try app.spaces.space(id: first) == nil)
    }

    @Test func switchWaitsForInFlightOperationsAndRejectsObsoleteNavigation() async throws {
        let app = try environment()
        let first = app.selectedSpaceID
        let page = try app.documents.create(DocumentDraft(title: "Operation"))
        let model = app.editorCache.prepare(page)
        let operation = model.beginPersistentOperation()
        let second = try app.spaces.create(title: "Other")
        let switching = Task { try await app.switchSpace(to: second.id) }
        while !app.isSwitchingSpace { await Task.yield() }
        #expect(app.selectedSpaceID == first && app.editorCache.model(for: page.id) != nil)
        model.endPersistentOperation(operation)
        try await switching.value
        #expect(app.selectedSpaceID == second.id)
        app.select(page)
        #expect(app.selectedDocumentID == nil && app.pendingDocumentID == nil)
        #expect(app.collections.snapshots.isEmpty)
    }

    @Test func deletingAnotherSpaceKeepsTheCurrentCollectionAvailable() async throws {
        let app = try environment()
        let page = try app.documents.create(DocumentDraft(title: "Keep Collection"))
        let collection = try app.collections.repository.create(ownerID: page.id, name: "Keep", viewName: "Main", kind: .gallery)
        _ = try app.collections.repository.addEntry(collectionID: collection.record.id, title: "Entry")
        app.editorCache.prepare(page)
        app.selectedDocumentID = page.id
        let second = try app.spaces.create(title: "Delete Other")
        try await app.deleteSpace(second.id)
        #expect(app.selectedDocumentID == page.id)
        #expect(app.collections.snapshots[collection.record.id]?.entries.count == 1)
    }

    @Test func calendarDiscardsTheOldWorkspaceAndLoadsOnlyCurrentTasks() async throws {
        let app = try environment()
        func taskJSON() throws -> String {
            let metadata = DocumentTaskMetadata(scheduledAt: nil)
            return try TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "taskList", "content": [
                ["type": "taskItem", "attrs": ["id": UUID().uuidString, "trackedTask": metadata.object],
                 "content": [["type": "paragraph", "content": [["type": "text", "text": "Task"]]]]]
            ]]])
        }
        _ = try app.documents.create(DocumentDraft(title: "Old", tipTapJSON: taskJSON()))
        app.calendar.activate()
        let second = try app.spaces.create(title: "New")
        try await app.switchSpace(to: second.id)
        let current = try app.documents.create(DocumentDraft(title: "Current", tipTapJSON: taskJSON()))
        await app.calendar.refreshAndWait()
        #expect(app.calendar.tasks.count == 1)
        #expect(app.calendar.tasks.allSatisfy { $0.task.documentID == current.id })
        #expect(app.calendar.documents.values.allSatisfy { $0.spaceID == second.id })
        app.calendar.deactivate()
    }
}
