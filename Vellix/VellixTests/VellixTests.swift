//
//  VellixTests.swift
//  VellixTests
//

import Testing
@testable import Vellix

@MainActor
struct VellixTests {
    private func makeEnvironment() throws -> AppEnvironment {
        let database = try AppDatabase.makeInMemory()
        let environment = AppEnvironment(
            database: database,
            attachmentStore: .previewStore()
        )
        try environment.bootstrap()
        return environment
    }

    @Test func initialDatabaseMigrationAndTemplateSeed() throws {
        let environment = try makeEnvironment()
        #expect(environment.overview.templates.count >= 7)
        #expect(environment.overview.all.isEmpty)
    }

    @Test func creatingSavingAndReopeningDocumentPersistsBlockNoteJSON() throws {
        let environment = try makeEnvironment()
        let document = try environment.documents.create(
            DocumentDraft(
                title: "Draft",
                blockNoteJSON: BlockNoteContentAnalyzer.starterDocument(
                    title: "Draft",
                    lines: ["Hello Vellix"]
                )
            )
        )

        let updatedJSON = BlockNoteContentAnalyzer.starterDocument(
            title: "Draft",
            lines: ["Hello Vellix", "Rich structure survives as JSON"]
        )
        let saved = try environment.documents.saveEditorJSON(
            id: document.id,
            canonicalJSON: updatedJSON
        )
        let reopened = try environment.documents.requireDocument(id: document.id)

        #expect(saved.revision == 2)
        #expect(reopened.blockNoteJSON == saved.blockNoteJSON)
        #expect(reopened.plainText.contains("Rich structure"))
    }

    @Test func analyzerExtractsPreviewCountsAndProtectsMalformedJSON() throws {
        let json = BlockNoteContentAnalyzer.starterDocument(
            title: "Analyzer",
            lines: ["One two three", "Four"]
        )
        let analysis = try BlockNoteContentAnalyzer.analyze(json)

        #expect(analysis.previewText.contains("One two"))
        #expect(analysis.wordCount == 4)
        #expect(analysis.characterCount > 0)
        #expect(analysis.estimatedReadingMinutes == 1)
        #expect(throws: VellixError.self) {
            _ = try BlockNoteContentAnalyzer.analyze("{bad json")
        }
    }

    @Test func favoriteAndRecentQueriesWork() throws {
        let environment = try makeEnvironment()
        let first = try environment.documents.create(DocumentDraft(title: "First"))
        let second = try environment.documents.create(DocumentDraft(title: "Second"))
        _ = try environment.documents.setFavorite(id: first.id, isFavorite: true)
        try environment.documents.markOpened(id: second.id)

        #expect(try environment.documents.favorites().map(\.id) == [first.id])
        #expect(try environment.documents.recent().first?.id == second.id)
    }

    @Test func creatingAndSelectingPageSetsEditorTarget() throws {
        let environment = try makeEnvironment()
        let first = try #require(environment.createDocument(title: "First Page"))
        let second = try environment.documents.create(DocumentDraft(title: "Second Page"))

        #expect(environment.selectedDocumentID == first.id)

        environment.select(second)
        #expect(environment.selectedDocumentID == second.id)
    }

    @Test func documentAppearanceAndCoverPersist() throws {
        let environment = try makeEnvironment()
        let document = try environment.documents.create(DocumentDraft(title: "Styled Page"))
        let appearance = DocumentAppearance(
            themeID: .neonCode,
            editorBackground: .gradient(primary: "#041314", secondary: "#140923"),
            innerPageBackground: .solid("#000000"),
            textColorHex: "#45F7DF",
            fontStyle: .mono
        )

        _ = try environment.documents.updateAppearance(
            id: document.id,
            cover: "cover-image.jpg",
            appearance: appearance
        )
        let reopened = try environment.documents.requireDocument(id: document.id)

        #expect(reopened.cover == "cover-image.jpg")
        #expect(reopened.appearance == appearance)
        #expect(reopened.isThemed)
    }

    @Test func trashRestoreAndPermanentDeleteCleanupWork() throws {
        let environment = try makeEnvironment()
        let document = try environment.documents.create(DocumentDraft(title: "Trash Me"))
        _ = try environment.snapshots.create(document: document, reason: .manual)
        _ = try environment.documents.trash(id: document.id)

        #expect(try environment.documents.trashed().contains { $0.id == document.id })

        _ = try environment.documents.restore(id: document.id)
        #expect(try environment.documents.trashed().isEmpty)

        _ = try environment.documents.trash(id: document.id)
        try environment.documents.permanentlyDelete(id: document.id, attachmentStore: environment.attachmentStore)

        #expect(try environment.documents.document(id: document.id) == nil)
        #expect(try environment.snapshots.history(documentID: document.id).isEmpty)
    }

    @Test func nestedDocumentCycleIsPrevented() throws {
        let environment = try makeEnvironment()
        let parent = try environment.documents.create(DocumentDraft(title: "Parent"))
        let child = try environment.documents.create(
            DocumentDraft(title: "Child", parentDocumentID: parent.id)
        )

        #expect(throws: VellixError.self) {
            _ = try environment.documents.move(
                id: parent.id,
                spaceID: nil,
                folderID: nil,
                parentDocumentID: child.id
            )
        }
    }

    @Test func templateCreatesValidDocument() throws {
        let environment = try makeEnvironment()
        let template = try #require(environment.overview.templates.first { $0.id == "built-in.project-plan" })
        let document = try environment.documents.create(
            DocumentDraft(
                title: template.title,
                templateOriginID: template.id,
                blockNoteJSON: template.blockNoteJSON
            )
        )

        #expect(document.templateOriginID == template.id)
        #expect(document.plainText.contains("Milestones"))
    }

    @Test func automaticSnapshotsArePrunedAndRestorable() throws {
        let environment = try makeEnvironment()
        var document = try environment.documents.create(DocumentDraft(title: "Snapshots"))
        for index in 0..<25 {
            document = try environment.documents.saveEditorJSON(
                id: document.id,
                canonicalJSON: BlockNoteContentAnalyzer.starterDocument(
                    title: "Snapshots",
                    lines: ["Version \(index)"]
                )
            )
            _ = try environment.snapshots.create(document: document, reason: .automatic)
        }

        let history = try environment.snapshots.history(documentID: document.id)
        #expect(history.filter(\.isAutomatic).count == 20)

        let restored = try environment.snapshots.restore(snapshotID: history.last!.id)
        #expect(restored.revision > document.revision)
    }

    @Test func ftsSearchFindsSavedContent() throws {
        let environment = try makeEnvironment()
        _ = try environment.documents.create(
            DocumentDraft(
                title: "Searchable",
                blockNoteJSON: BlockNoteContentAnalyzer.starterDocument(
                    title: "Searchable",
                    lines: ["Needle phrase inside the saved content"]
                )
            )
        )

        let results = try environment.search.search("needle phrase")
        #expect(results.count == 1)
        #expect(results.first?.title == "Searchable")
    }
}
