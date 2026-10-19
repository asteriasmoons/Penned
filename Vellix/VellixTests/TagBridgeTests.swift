import Foundation
import Combine
import Testing
@testable import Vellix

@MainActor struct TagBridgeTests {
    @Test func repeatedWebViewLoadChecksDoNotPublishOrInvalidateTagActions() {
        let session = TipTapEditorSession()
        let json = TipTapContentAnalyzer.emptyDocumentJSON
        var attachmentResolutions = 0
        session.attachmentResolver = { _, _ in attachmentResolutions += 1; return [] }
        session.load(documentID: "same", canonicalJSON: json)
        var publications = 0
        let observation = session.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        for _ in 0..<50 { session.load(documentID: "same", canonicalJSON: json) }
        #expect(publications == 0 && attachmentResolutions == 1)

        let request = InlineTagRequest(token: "open-menu", action: "menu", name: "journals")
        session.handleRawMessage(["kind": "tagRequest", "payload": ["token": request.token, "action": request.action, "name": request.name]])
        publications = 0
        for _ in 0..<50 { session.load(documentID: "same", canonicalJSON: json) }
        #expect(publications == 0 && attachmentResolutions == 1 && session.tagRequest == request)

        session.load(documentID: "other", canonicalJSON: json)
        #expect(session.tagRequest == nil && attachmentResolutions == 2)
    }

    @Test func changedAndForcedQueuedLoadsStillResetTagState() throws {
        let session = TipTapEditorSession()
        let empty = TipTapContentAnalyzer.emptyDocumentJSON
        let changed = try TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "paragraph", "content": [["type": "text", "text": "Updated"]]]])
        var attachmentResolutions = 0
        session.attachmentResolver = { _, _ in attachmentResolutions += 1; return [] }
        session.load(documentID: "same", canonicalJSON: empty)
        session.tagRequest = InlineTagRequest(token: "old", action: "menu", name: "journals")
        session.load(documentID: "same", canonicalJSON: changed)
        #expect(session.tagRequest == nil && attachmentResolutions == 2)
        session.tagRequest = InlineTagRequest(token: "force", action: "menu", name: "journals")
        session.load(documentID: "same", canonicalJSON: changed, force: true)
        #expect(session.tagRequest == nil && attachmentResolutions == 3)
    }

    @Test func tagRequestsDecodeValidateAndClearBeforeLoadingAnotherDocument() throws {
        let event = try TipTapEditorEvent(kind: "tagRequest", payload: ["token": "selection", "action": "menu", "name": "journals"])
        #expect(event == .tagRequest(InlineTagRequest(token: "selection", action: "menu", name: "journals")))
        let session = TipTapEditorSession()
        session.handleRawMessage(["kind": "tagRequest", "payload": ["token": "selection", "action": "commit", "name": "journals"]])
        #expect(session.tagRequest?.name == "journals")
        session.load(documentID: "other", canonicalJSON: TipTapContentAnalyzer.emptyDocumentJSON)
        #expect(session.tagRequest == nil)
        for payload: [String: Any] in [["action": "menu", "name": "journals"], ["token": "x", "action": "delete", "name": "journals"], ["token": "x", "action": "commit", "name": "<bad>"]] {
            #expect(try TipTapEditorEvent(kind: "tagRequest", payload: payload) == .unknown("tagRequest"))
        }
    }

    @Test func browserCommitsPendingEditorContentAndNestedNavigationRetainsExactIdentity() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let app = AppEnvironment(database: try .makeInMemory(), attachmentStore: AttachmentStore(rootURL: rootURL))
        let root = try app.documents.create(DocumentDraft(title: "Root"))
        let child = try app.documents.create(DocumentDraft(title: "Nested", parentDocumentID: root.id))
        let model = app.editorCache.prepare(child)
        let json = try TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "paragraph", "attrs": ["id": "exact-block"],
            "content": [["type": "inlineTag", "attrs": ["id": "exact-tag", "name": "journals"]], ["type": "text", "text": " real text"]]]])
        model.session.onEvent?(.documentChanged(json))
        app.selectedDocumentID = child.id
        await app.browseTags(named: "Journals")
        #expect(app.selectedDocumentID == nil && app.selectedDestination == .tags)
        let results = try app.tags.snapshot(selected: app.selectedTagIDs)
        let block = try #require(results.documents.first?.blocks.first)
        #expect(results.documents.first?.id == root.id && block.documentID == child.id)
        #expect(block.breadcrumbs == ["Root", "Nested"] && block.blockID == "exact-block")
        await app.openTaggedBlock(block, selectedTags: app.selectedTagIDs)
        #expect(app.pendingDocumentID == child.id && app.tagNavigationTarget?.blockID == "exact-block")
        #expect(app.tagNavigationTarget?.occurrenceID == "exact-tag")
        let first = app.tagNavigationTarget?.id
        app.selectedDocumentID = child.id
        await app.openTaggedBlock(block, selectedTags: app.selectedTagIDs)
        #expect(app.tagNavigationTarget?.id != first && app.tagNavigationTarget?.documentID == child.id)
        _ = try app.documents.saveEditorJSON(id: child.id, canonicalJSON: TipTapContentAnalyzer.emptyDocumentJSON)
        app.editorCache.remove(documentID: child.id)
        await app.openTaggedBlock(block, selectedTags: app.selectedTagIDs)
        #expect(app.tagNavigationTarget == nil && app.errorMessage != nil)
        for model in app.editorCache.preparedModels { model.discardPendingSave() }
    }

    @Test func spaceSwitchClearsTagFiltersAndPendingBlockTargets() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let app = AppEnvironment(database: try .makeInMemory(), attachmentStore: AttachmentStore(rootURL: rootURL))
        let tag = try app.tags.resolve("private")
        app.selectedTagIDs = [tag.id]
        app.tagNavigationTarget = TagNavigationTarget(documentID: "old", blockID: "old")
        let other = try app.spaces.create(title: "Other")
        try await app.switchSpace(to: other.id)
        #expect(app.tags.spaceID == other.id && app.selectedTagIDs.isEmpty && app.tagNavigationTarget == nil)
        #expect(try app.tags.catalogue().isEmpty)
    }
}
