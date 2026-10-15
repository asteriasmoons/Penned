import Foundation
import Testing
@testable import Vellix

@MainActor
struct PageCardTests {
    @Test func cardConfigurationCancelDoesNotCreateAPage() throws {
        let env = AppEnvironment(database: try AppDatabase.makeInMemory(), attachmentStore: .previewStore())
        let parent = try env.documents.create(DocumentDraft(title: "Parent"))
        let model = env.editorCache.prepare(parent)
        let event = try TipTapEditorEvent(kind: "pageCardRequest", payload: ["blockId": "card-placeholder"])
        model.session.onEvent?(event)
        #expect(model.cardEditorRequest?.blockID == "card-placeholder")
        #expect(try env.documents.children(of: parent.id).isEmpty)
        model.cardEditorRequest = nil
        model.cancelCardInsertion()
        #expect(try env.documents.children(of: parent.id).isEmpty)
    }

    @Test func allCardLayoutsPersistOnRealIndependentChildPages() throws {
        let env = AppEnvironment(database: try AppDatabase.makeInMemory(), attachmentStore: .previewStore())
        let parent = try env.documents.create(DocumentDraft(title: "Parent", appearanceJSON: DocumentAppearance.defaultForTheme(.neonCode).encodedJSON()))
        for size in PageCardSize.allCases {
            var style = PageCardStyle()
            style.size = size
            style.showsPages = false
            style.backdrop = .gradient
            style.startColor = "#93A5FF"
            style.endColor = "#FFC7D7"
            let page = try env.documents.savePageCard(parentID: parent.id, documentID: nil, style: style, imageData: nil, attachmentStore: env.attachmentStore)
            let json = TipTapContentAnalyzer.starterDocument(title: "Notes", lines: ["Saved content"])
            _ = try env.documents.saveEditorJSON(id: page.id, canonicalJSON: json)
            let reopened = try env.documents.requireDocument(id: page.id)
            #expect(reopened.cardStyle == style)
            #expect(reopened.appearanceJSON == nil && reopened.cover == nil)
            #expect(reopened.plainText.contains("Saved content"))
            #expect(!((try env.documents.allDocuments()).contains { $0.id == page.id }))
            let payload = PageReferencePresentation.bridgeObject(reopened)
            #expect(payload["cardWidth"] as? CGFloat == size.size.width)
            #expect((payload["cardImage"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        }
    }

    @Test func cardEditRejectsUnownedOrTrashedPagesWithoutChangingThem() throws {
        let env = AppEnvironment(database: try AppDatabase.makeInMemory(), attachmentStore: .previewStore())
        let parent = try env.documents.create(DocumentDraft(title: "Parent"))
        let other = try env.documents.create(DocumentDraft(title: "Other"))
        #expect(throws: VellixError.self) {
            try env.documents.savePageCard(parentID: parent.id, documentID: other.id, style: PageCardStyle(), imageData: nil, attachmentStore: env.attachmentStore)
        }
        #expect(try env.documents.requireDocument(id: other.id).cardStyle == nil)
        let page = try env.documents.savePageCard(parentID: parent.id, documentID: nil, style: PageCardStyle(), imageData: nil, attachmentStore: env.attachmentStore)
        _ = try env.documents.trash(id: page.id)
        #expect(throws: VellixError.self) {
            try env.documents.savePageCard(parentID: parent.id, documentID: page.id, style: PageCardStyle(), imageData: nil, attachmentStore: env.attachmentStore)
        }
    }
}
