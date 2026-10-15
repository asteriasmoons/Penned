//
//  VellixTests.swift
//  VellixTests
//

import Testing
import Foundation
import CoreGraphics
@testable import Vellix

@MainActor
struct VellixTests {
    @Test func caretScrollingOnlyMovesEnoughToRevealTheActiveLine() {
        let viewport = CGRect(x: 0, y: 80, width: 390, height: 300)
        #expect(TipTapCaretVisibility.targetOffset(caret: CGRect(x: 10, y: 100, width: 1, height: 24),
            viewport: viewport, current: 400, minimum: 0, maximum: 2000) == nil)
        #expect(TipTapCaretVisibility.targetOffset(caret: CGRect(x: 10, y: 390, width: 1, height: 24),
            viewport: viewport, current: 400, minimum: 0, maximum: 2000) == 434)
        #expect(TipTapCaretVisibility.targetOffset(caret: CGRect(x: 10, y: 50, width: 1, height: 24),
            viewport: viewport, current: 400, minimum: 0, maximum: 2000) == 370)
    }

    @Test func caretScrollingClampsOffsetsAndHandlesVeryLargeText() {
        let viewport = CGRect(x: 0, y: 80, width: 390, height: 100)
        #expect(TipTapCaretVisibility.targetOffset(caret: CGRect(x: 10, y: 220, width: 1, height: 24),
            viewport: viewport, current: 980, minimum: -10, maximum: 1000) == 1000)
        #expect(TipTapCaretVisibility.targetOffset(caret: CGRect(x: 10, y: 0, width: 1, height: 24),
            viewport: viewport, current: 0, minimum: -10, maximum: 1000) == -10)
        #expect(TipTapCaretVisibility.targetOffset(caret: CGRect(x: 10, y: 30, width: 1, height: 150),
            viewport: viewport, current: 0, minimum: 0, maximum: 1000) == nil)
    }

    @Test func caretBridgeRejectsInvalidGeometryAndKeepsValidCoordinates() {
        let payload: [String: Any] = ["x": 20, "y": 220, "width": 1, "height": 24, "revision": 3]
        #expect(TipTapCaretUpdate.decode(payload)?.rect == CGRect(x: 20, y: 220, width: 1, height: 24))
        #expect(TipTapCaretUpdate.decode(payload)?.revision == 3)
        var invalid = payload
        invalid["height"] = -1
        #expect(TipTapCaretUpdate.decode(invalid) == nil)
        invalid["height"] = Double.nan
        #expect(TipTapCaretUpdate.decode(invalid) == nil)
    }

    private func makeEnvironment() throws -> AppEnvironment {
        let database = try AppDatabase.makeInMemory()
        let environment = AppEnvironment(
            database: database,
            attachmentStore: .previewStore()
        )
        try environment.bootstrap()
        return environment
    }

    @Test func initialDatabaseMigrationStartsWithoutBuiltInTemplates() throws {
        let environment = try makeEnvironment()
        #expect(environment.overview.templates.isEmpty)
        #expect(environment.overview.all.isEmpty)
    }

    @Test func serifRemainsAvailableWithoutChangingDefaultFonts() throws {
        let original = DocumentAppearance.defaultForTheme(.lunarClouds)
        let encoded = try #require(original.encodedJSON())
        let legacy = encoded.replacingOccurrences(of: "\"rounded\"", with: "\"serif\"")
        let decoded = DocumentAppearance.decode(legacy)
        #expect(decoded.fontStyle == .serif)
        #expect(decoded.themeID == original.themeID)
        #expect(decoded.editorBackground == original.editorBackground)
        #expect(decoded.innerPageBackground == original.innerPageBackground)
        #expect(decoded.textColorHex == original.textColorHex)
        #expect(DocumentFontStyle.allCases == [.system, .serif, .mono, .rounded])
        for theme in DocumentThemeID.allCases {
            #expect(DocumentAppearance.defaultForTheme(theme).fontStyle == .rounded)
        }
    }

    @Test func oldBackgroundJSONRetainsItsDefaultRendering() throws {
        let json = ##"{"kind":"gradient","colorHex":"#123456","secondaryColorHex":"#654321"}"##
        let background = try JSONDecoder().decode(DocumentBackgroundStyle.self, from: Data(json.utf8))
        #expect(background.gradientDirection == nil)
        #expect(background.blurImage == nil)
        #expect(background.effect == nil)
        #expect(background.remotePhoto == nil)
        var appearance = DocumentAppearance.plain
        appearance.enableCustomLayout()
        #expect(appearance.themeID == .custom)
        #expect(!appearance.displaysCover)
    }

    @Test func savedStylesPersistAndApplyEverySettingIndependently() throws {
        let environment = try makeEnvironment()
        let first = try environment.documents.create(DocumentDraft(title: "First"))
        let second = try environment.documents.create(DocumentDraft(title: "Second"))
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let image = try environment.documentStyles.importImage(png, documentID: first.id)
        var appearance = DocumentAppearance.defaultForTheme(.custom)
        appearance.fontStyle = .serif
        appearance.textColorHex = "#123456"
        appearance.innerPageBackground = .solid("#FFEEDD")
        appearance.editorBackground = .image(path: image.relativePath)
        appearance.editorBackground.blurImage = true
        appearance.editorBackground.effect = .faded
        appearance.editorBackground.gradientDirection = .bottomToTop
        appearance.showsCover = true
        let photo = CardRemotePhoto(id: "test-photo", thumbURL: "https://images.unsplash.com/test?width=100",
            imageURL: "https://images.unsplash.com/test", photographer: "Photographer",
            photographerURL: "https://unsplash.com/@photographer", sourceURL: "https://unsplash.com/photos/test")
        appearance.coverPhoto = photo
        appearance.editorBackground.remotePhoto = photo
        let original = DocumentStyleDefinition(appearance: appearance, cover: image.relativePath)
        let saved = try environment.documentStyles.save(title: "My Style", definition: original)
        let reopened = DocumentStyleRepository(database: environment.database, store: environment.attachmentStore)
        let styles = try reopened.all()
        #expect(styles.contains { $0.id == saved.id })
        #expect(try reopened.matchingStyle(original, in: styles)?.id == saved.id)
        let owned = try saved.definition()
        #expect(owned.cover != original.cover)
        #expect(owned.cover == owned.appearance.editorBackground.imagePath)
        let applied = try reopened.apply(saved, to: second.id)
        #expect(applied.cover != owned.cover)
        #expect(applied.appearance.fontStyle == .serif)
        #expect(applied.appearance.textColorHex == "#123456")
        #expect(applied.appearance.innerPageBackground == appearance.innerPageBackground)
        #expect(applied.appearance.editorBackground.blurImage == true)
        #expect(applied.appearance.editorBackground.effect == .faded)
        #expect(applied.appearance.editorBackground.gradientDirection == .bottomToTop)
        #expect(applied.appearance.coverPhoto == photo)
        #expect(applied.appearance.editorBackground.remotePhoto == photo)
        #expect(try reopened.matchingStyle(applied, in: styles)?.id == saved.id)
        _ = try environment.documents.updateAppearance(id: second.id, cover: applied.cover, appearance: applied.appearance)
        let document = try environment.documents.requireDocument(id: second.id)
        #expect(document.appearance == applied.appearance)
        #expect(document.cover == applied.cover)
        try environment.attachmentStore.removeFile(relativePath: image.relativePath)
        #expect(FileManager.default.fileExists(atPath: environment.attachmentStore.fileURL(relativePath: try #require(owned.cover)).path))
        try reopened.delete(saved)
        #expect(FileManager.default.fileExists(atPath: environment.attachmentStore.fileURL(relativePath: try #require(applied.cover)).path))
        #expect(try reopened.all().count == 2)
    }

    @Test func customizedBackdropRemovesThePatternWithoutChangingCoverOrPaper() {
        var appearance = DocumentAppearance.defaultForTheme(.lunarClouds)
        let paper = appearance.innerPageBackground
        appearance.customizeBackdrop()
        appearance.editorBackground = .gradient(primary: "#683CB5", secondary: "#00BBCB")
        #expect(appearance.themeID == .custom)
        #expect(appearance.editorBackground.patternTheme(for: appearance.themeID) == nil)
        #expect(appearance.displaysCover)
        #expect(appearance.resolvedCoverTheme == .lunarClouds)
        #expect(appearance.innerPageBackground == paper)
    }

    @Test func legacyCustomizedGradientDoesNotInheritTheBuiltInPattern() {
        var background = DocumentThemeID.lunarClouds.defaultEditorBackground
        #expect(background.patternTheme(for: .lunarClouds) == .lunarClouds)
        background.colorHex = "#683CB5"
        background.secondaryColorHex = "#00BBCB"
        #expect(background.patternTheme(for: .lunarClouds) == nil)
        #expect(DocumentBackgroundStyle.none.patternTheme(for: .lunarClouds) == nil)
        #expect(DocumentBackgroundStyle.image(path: "background.jpg").patternTheme(for: .lunarClouds) == nil)
    }

    @Test func anyVisibleStyleChangeRequiresSavingAgain() throws {
        let environment = try makeEnvironment()
        let original = DocumentStyleDefinition(appearance: .defaultForTheme(.custom))
        let saved = try environment.documentStyles.save(title: "Original", definition: original)
        let styles = try environment.documentStyles.all()
        #expect(try environment.documentStyles.matchingStyle(original, in: styles)?.id == saved.id)
        var changed = original
        changed.appearance.fontStyle = .serif
        #expect(try environment.documentStyles.matchingStyle(changed, in: styles) == nil)
        changed = original
        changed.appearance.textColorHex = "#FF0088"
        #expect(try environment.documentStyles.matchingStyle(changed, in: styles) == nil)
        changed = original
        changed.appearance.editorBackground = .gradient(primary: "#683CB5", secondary: "#00BBCB")
        #expect(try environment.documentStyles.matchingStyle(changed, in: styles) == nil)
        changed = original
        changed.appearance.innerPageBackground = .solid("#FFFFFF")
        #expect(try environment.documentStyles.matchingStyle(changed, in: styles) == nil)
    }

    @Test func creatingSavingAndReopeningDocumentPersistsTipTapJSON() throws {
        let environment = try makeEnvironment()
        let document = try environment.documents.create(
            DocumentDraft(
                title: "Draft",
                tipTapJSON: TipTapContentAnalyzer.starterDocument(
                    title: "Draft",
                    lines: ["Hello Vellix"]
                )
            )
        )

        let updatedJSON = TipTapContentAnalyzer.starterDocument(
            title: "Draft",
            lines: ["Hello Vellix", "Rich structure survives as JSON"]
        )
        let saved = try environment.documents.saveEditorJSON(
            id: document.id,
            canonicalJSON: updatedJSON
        )
        let reopened = try environment.documents.requireDocument(id: document.id)

        #expect(saved.revision == 2)
        #expect(reopened.tipTapJSON == saved.tipTapJSON)
        #expect(reopened.plainText.contains("Rich structure"))
    }

    @Test func blockquoteEndColorPersistsWhenDocumentReopens() throws {
        let environment = try makeEnvironment()
        let quoteNode: [String: Any] = [
            "type": "blockquote",
            "attrs": ["id": "quote", "color": "#7359ad"],
            "content": [[
                "type": "paragraph",
                "content": [["type": "text", "text": "A colored quote"]]
            ]]
        ]
        let json = try TipTapContentAnalyzer.makeDocumentJSON(content: [quoteNode])
        let document = try environment.documents.create(DocumentDraft(title: "Quote", tipTapJSON: json))
        let reopened = try environment.documents.requireDocument(id: document.id)
        let object = TipTapContentAnalyzer.documentObject(from: reopened.tipTapJSON)
        let content = try #require(object["content"] as? [[String: Any]])
        let quote = try #require(content.first)
        let attrs = try #require(quote["attrs"] as? [String: Any])
        #expect(quote["type"] as? String == "blockquote")
        #expect(attrs["color"] as? String == "#7359ad")
        #expect(reopened.plainText.contains("A colored quote"))
    }

    @Test func blockquoteColorPickerBridgeUsesWhiteDefaultAndTargetedCommand() throws {
        let event = try TipTapEditorEvent(
            kind: "blockquoteColorPickerRequest",
            payload: ["blockId": "quote"]
        )
        #expect(event == .requestBlockquoteColorPicker(blockID: "quote", color: "#ffffff"))
        let command = TipTapEditorCommand.updateBlockquoteColor(blockID: "quote", color: "#7359ad")
        #expect(command.name == "updateBlockquoteColor")
        #expect(command.args["blockId"] as? String == "quote")
        #expect(command.args["color"] as? String == "#7359ad")
    }

    @Test func namedPropertiesPersistValuesOptionsAndSearchText() throws {
        let environment = try makeEnvironment()
        var property = InlinePropertyDefinition()
        property.kind = .multiSelect
        property.name = "Status"
        property.options = [InlinePropertyOption(id: "ready", name: "Ready", color: "#7359AD")]
        property.selectedOptionIDs = ["ready"]
        let json = try TipTapContentAnalyzer.makeDocumentJSON(content: [[
            "type": "inlineProperty",
            "attrs": ["id": "status", "property": try property.bridgeObject()]
        ]])
        let document = try environment.documents.create(DocumentDraft(title: "Properties", tipTapJSON: json))
        let reopened = try environment.documents.requireDocument(id: document.id)
        let object = TipTapContentAnalyzer.documentObject(from: reopened.tipTapJSON)
        let content = try #require(object["content"] as? [[String: Any]])
        let attrs = try #require(content.first?["attrs"] as? [String: Any])
        #expect(InlinePropertyDefinition.decode(attrs["property"]) == property)
        #expect(reopened.plainText.contains("Status: Ready"))
    }

    @Test func propertyBridgeUsesTargetedUpdatesAndRejectsUnsafeLinks() throws {
        var property = InlinePropertyDefinition()
        property.name = "Website"
        property.kind = .url
        property.value = "example.com"
        let object = try property.bridgeObject()
        let event = try TipTapEditorEvent(kind: "propertyEditorRequest", payload: ["blockId": "website", "property": object])
        #expect(event == .requestInlinePropertyEditor(blockID: "website", property: property))
        let command = try TipTapEditorCommand.updateInlineProperty(blockID: "website", property: property)
        #expect(command.name == "updateInlineProperty")
        #expect(command.args["blockId"] as? String == "website")
        #expect(InlinePropertyDefinition.safeURL("example.com")?.scheme == "https")
        #expect(InlinePropertyDefinition.safeURL("javascript:alert(1)") == nil)
        #expect(InlinePropertyDefinition.safeURL("https://user:password@example.com") == nil)
    }

    @Test func analyzerExtractsPreviewCountsAndProtectsMalformedJSON() throws {
        let json = TipTapContentAnalyzer.starterDocument(
            title: "Analyzer",
            lines: ["One two three", "Four"]
        )
        let analysis = try TipTapContentAnalyzer.analyze(json)

        #expect(analysis.previewText.contains("One two"))
        #expect(analysis.wordCount == 4)
        #expect(analysis.characterCount > 0)
        #expect(analysis.estimatedReadingMinutes == 1)
        #expect(throws: VellixError.self) {
            _ = try TipTapContentAnalyzer.analyze("{bad json")
        }
    }

    @Test func retiredColumnsPreserveContentAsNormalBlocks() throws {
        let environment = try makeEnvironment()
        let columns: [String: Any] = [
            "type": "columns", "attrs": ["id": "layout"], "content": [
                ["type": "column", "attrs": ["id": "left"], "content": [
                    ["type": "paragraph", "content": [["type": "text", "text": "Left column"]]]
                ]],
                ["type": "column", "attrs": ["id": "right"], "content": [
                    ["type": "callout", "attrs": ["icon": "sparkle", "color": "#A970FF"], "content": [
                        ["type": "paragraph", "content": [["type": "text", "text": "Right callout"]]]
                    ]]
                ]]
            ]
        ]
        let json = try TipTapContentAnalyzer.makeDocumentJSON(content: [columns])
        let document = try environment.documents.create(DocumentDraft(title: "Columns", tipTapJSON: json))
        let reopened = try environment.documents.requireDocument(id: document.id)
        #expect(reopened.tipTapJSON == document.tipTapJSON)
        #expect(reopened.plainText.contains("Left column"))
        #expect(reopened.plainText.contains("Right callout"))
        let content = try #require(TipTapContentAnalyzer.documentObject(from: reopened.tipTapJSON)["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["paragraph", "callout"])
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

    @Test func creatingAndSelectingPagePreparesTargetWithoutExposingAnUnreadyEditor() throws {
        let environment = try makeEnvironment()
        let first = try #require(environment.createDocument(title: "First Page"))
        let second = try environment.documents.create(DocumentDraft(title: "Second Page"))

        #expect(environment.selectedDocumentID == nil)
        #expect(environment.pendingDocumentID == first.id)

        environment.select(second)
        #expect(environment.selectedDocumentID == nil)
        #expect(environment.pendingDocumentID == second.id)
        #expect(environment.editorCache.model(for: second.id) != nil)
        environment.selectedDocumentID = nil
        #expect(environment.pendingDocumentID == nil)
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

    @Test func nestedPagesAreRealDocumentsButNeverLibraryCards() throws {
        let environment = try makeEnvironment()
        let parent = try environment.documents.create(DocumentDraft(title: "Parent"))
        let child = try environment.documents.create(DocumentDraft(title: "Child", parentDocumentID: parent.id))
        let grandchild = try environment.documents.create(DocumentDraft(title: "Grandchild", parentDocumentID: child.id))
        _ = try environment.documents.setFavorite(id: child.id, isFavorite: true)
        _ = try environment.documents.saveEditorJSON(id: child.id, canonicalJSON:
            TipTapContentAnalyzer.starterDocument(title: "Child", lines: ["Independently saved child content"]))
        environment.refresh()

        #expect(environment.overview.all.map(\.id) == [parent.id])
        #expect(environment.overview.recent.map(\.id) == [parent.id])
        #expect(environment.overview.favorites.isEmpty)
        #expect(try environment.documents.allDocuments(includeTrashed: true).map(\.id) == [parent.id])
        #expect(try environment.documents.children(of: parent.id).map(\.id) == [child.id])
        #expect(try environment.documents.requireDocument(id: child.id).plainText.contains("Independently saved"))
        #expect(environment.editorCache.model(for: child.id) == nil)
        #expect(environment.editorCache.model(for: grandchild.id) == nil)
        environment.select(grandchild)
        #expect(environment.pendingDocumentID == grandchild.id)
        environment.returnFromDocument(grandchild)
        #expect(environment.pendingDocumentID == child.id)
        #expect(environment.editorCache.model(for: child.id) != nil)
    }

    @Test func thumbnailPreservesListMarkersIndentationAndTaskStates() throws {
        let json = #"{"type":"doc","content":[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"First item"}]},{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Nested item"}]}]}]}]}]},{"type":"orderedList","attrs":{"start":3},"content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Third"}]}]}]},{"type":"taskList","content":[{"type":"taskItem","attrs":{"checked":true},"content":[{"type":"paragraph","content":[{"type":"text","text":"Done"}]}]},{"type":"taskItem","attrs":{"crossed":true},"content":[{"type":"paragraph","content":[{"type":"text","text":"Rejected"}]}]}]}]}"#
        let layout = DocumentThumbnailLayout(json: json, title: "List")
        let bullets = layout.marks.filter { $0.shape == .bullet }
        #expect(bullets.count == 2)
        #expect(bullets[1].rect.minX > bullets[0].rect.minX)
        #expect(layout.marks.contains { $0.shape == .number(3) })
        #expect(layout.marks.contains { $0.shape == .checkbox(checked: true, crossed: false) })
        #expect(layout.marks.contains { $0.shape == .checkbox(checked: false, crossed: true) })
    }

    @Test func thumbnailReflectsBlockOrderTextLengthAndContainers() throws {
        let json = ##"{"type":"doc","content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Heading"}]},{"type":"paragraph","content":[{"type":"text","text":"Paragraph"}]},{"type":"codeBlock","content":[{"type":"text","text":"npm run build"}]},{"type":"divider","attrs":{"style":"thinLine"}},{"type":"callout","attrs":{"color":"#7359ad"},"content":[{"type":"paragraph","content":[{"type":"text","text":"Note"}]}]},{"type":"image","attrs":{"src":"saved-image.jpg"}}]}"##
        let layout = DocumentThumbnailLayout(json: json, title: "Blocks")
        let heading = try #require(layout.marks.first { $0.blockType == "heading" })
        let paragraph = try #require(layout.marks.first { $0.blockType == "paragraph" })
        let code = try #require(layout.marks.first { $0.blockType == "codeBlock" })
        let divider = try #require(layout.marks.first { $0.blockType == "divider" })
        let callout = try #require(layout.marks.first { $0.blockType == "callout" })
        let image = try #require(layout.marks.first { $0.shape == .image })
        #expect(heading.rect.height > paragraph.rect.height)
        #expect(heading.rect.minY < paragraph.rect.minY)
        #expect(paragraph.rect.minY < code.rect.minY)
        #expect(code.rect.minY < divider.rect.minY)
        #expect(divider.rect.minY < callout.rect.minY)
        #expect(callout.rect.minY < image.rect.minY)
        #expect(callout.colorHex == "#7359ad")
        let short = DocumentThumbnailLayout(json: TipTapContentAnalyzer.starterDocument(title: "", lines: ["A"]), title: "Same")
        let long = DocumentThumbnailLayout(json: TipTapContentAnalyzer.starterDocument(title: "", lines: ["A longer line"]), title: "Same")
        #expect(short.marks.last!.rect.width < long.marks.last!.rect.width)
    }

    @Test func thumbnailHonorsCollapsedTogglesPropertiesAndEmptyPages() throws {
        let json = ##"{"type":"doc","content":[{"type":"toggleItem","attrs":{"open":false},"content":[{"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":"Summary"}]},{"type":"callout","content":[{"type":"paragraph","content":[{"type":"text","text":"Hidden"}]}]}]},{"type":"inlineProperty","attrs":{"property":{"kind":"multiSelect","name":"Status","selectedOptionIDs":["ready"],"options":[{"id":"ready","name":"Ready","color":"#2EC5F4"},{"id":"later","name":"Later","color":"#A970FF"}]}}}]}"##
        let layout = DocumentThumbnailLayout(json: json, title: "Properties")
        #expect(layout.marks.contains { $0.shape == .toggle(open: false) })
        #expect(!layout.marks.contains { $0.blockType == "callout" })
        let chips = layout.marks.filter { $0.shape == .chip }
        #expect(chips.count == 1)
        #expect(chips.first?.colorHex == "#2EC5F4")
        let open = DocumentThumbnailLayout(json: json.replacingOccurrences(of: "\"open\":false", with: "\"open\":true"), title: "Properties")
        #expect(open.marks.contains { $0.blockType == "callout" })
        let empty = DocumentThumbnailLayout(json: TipTapContentAnalyzer.emptyDocumentJSON, title: "Empty")
        #expect(empty.isEmpty)
        #expect(empty.marks.allSatisfy { $0.blockType == "title" })
        #expect(DocumentThumbnailLayout(json: "bad JSON", title: "Empty").isEmpty)
    }

    @Test func thumbnailLimitsPreviewToTheBeginningOfTheDocument() throws {
        let json = TipTapContentAnalyzer.starterDocument(title: "", lines: Array(repeating: "Visible paragraph", count: 1_000))
        let layout = DocumentThumbnailLayout(json: json, title: "Long page")
        #expect(layout.marks.count < 30)
        #expect(layout.marks.allSatisfy { $0.rect.minY < 120 && $0.rect.maxX <= 90 })
    }

    @Test func thumbnailCoverPrecedesTitleAndDocumentContent() throws {
        let json = TipTapContentAnalyzer.starterDocument(title: "", lines: ["Content below the cover"])
        let layout = DocumentThumbnailLayout(json: json, title: "Covered page", showsCover: true)
        let cover = try #require(layout.coverRect)
        let title = try #require(layout.marks.first { $0.blockType == "title" })
        let content = try #require(layout.marks.first { $0.blockType == "paragraph" })
        #expect(abs(cover.width / cover.height - 1.78) < 0.0001)
        #expect(title.rect.minY > cover.maxY)
        #expect(content.rect.minY > title.rect.maxY)
        #expect(!layout.isEmpty)
        #expect(DocumentThumbnailLayout(json: TipTapContentAnalyzer.emptyDocumentJSON, title: "Cover only", showsCover: true).isEmpty == false)
        #expect(DocumentThumbnailLayout(json: json, title: "Without cover").coverRect == nil)
    }

    @Test func successfulChildSaveUpdatesParentThumbnailWithoutReloadingEditor() async throws {
        let environment = try makeEnvironment()
        let parent = try environment.documents.create(DocumentDraft(title: "Parent"))
        let child = try environment.documents.create(DocumentDraft(title: "Child", parentDocumentID: parent.id))
        environment.refresh()
        let parentModel = try #require(environment.editorCache.model(for: parent.id))
        let childModel = environment.editorCache.prepare(child)
        let oldJSON = try #require(parentModel.children.first?.tipTapJSON)
        let json = TipTapContentAnalyzer.starterDocument(title: "Child", lines: ["New saved content"])
        let notifyParent = childModel.onDocumentSaved
        await withCheckedContinuation { continuation in
            childModel.onDocumentSaved = { saved in
                notifyParent?(saved)
                childModel.onDocumentSaved = notifyParent
                continuation.resume()
            }
            childModel.session.onEvent?(.documentSnapshot(json))
            childModel.flushPendingSave()
        }
        let updated = try #require(parentModel.children.first)
        #expect(updated.tipTapJSON != oldJSON)
        #expect(updated.tipTapJSON == childModel.document?.tipTapJSON)
        #expect(updated.plainText == "New saved content")
        #expect(environment.editorCache.model(for: child.id) === childModel)
        #expect(environment.editorCache.model(for: parent.id) === parentModel)
    }

    @Test func nestedPagesKeepTheirOwnAppearanceRegardlessOfParentTheme() throws {
        let environment = try makeEnvironment()
        let parent = try environment.documents.create(DocumentDraft(title: "Styled"))
        let child = try environment.documents.create(DocumentDraft(title: "Child", parentDocumentID: parent.id))
        let grandchild = try environment.documents.create(DocumentDraft(title: "Grandchild", parentDocumentID: child.id))
        var appearance = DocumentAppearance.defaultForTheme(.neonCode)
        appearance.textColorHex = "#2EC5F4"
        appearance.innerPageBackground = .solid("#335544")
        _ = try environment.documents.updateAppearance(id: parent.id, cover: nil, appearance: appearance)
        environment.refresh()
        environment.editorCache.prepare([child, grandchild])
        #expect(environment.editorCache.model(for: child.id)?.appearance == .plain)
        #expect(environment.editorCache.model(for: grandchild.id)?.appearance == .plain)
        #expect(try environment.documents.requireDocument(id: child.id).appearanceJSON == nil)

        var custom = DocumentAppearance.defaultForTheme(.lunarClouds)
        custom.textColorHex = "#A970FF"
        _ = try environment.documents.updateAppearance(id: child.id, cover: nil, appearance: custom)
        environment.refresh()
        #expect(environment.editorCache.model(for: child.id)?.appearance == custom)
        #expect(environment.editorCache.model(for: grandchild.id)?.appearance == .plain)
        #expect(environment.editorCache.model(for: parent.id)?.appearance == appearance)

        let childModel = try #require(environment.editorCache.model(for: child.id))
        let newPage = try #require(childModel.createChild())
        #expect(environment.editorCache.model(for: newPage.id)?.appearance == .plain)
        #expect(newPage.appearanceJSON == nil)
        #expect(newPage.cover == nil)
    }

    @Test func nestedOwnershipSurvivesTrashRestoreDuplicateAndDeletion() throws {
        let environment = try makeEnvironment()
        let parent = try environment.documents.create(DocumentDraft(title: "Parent"))
        let child = try environment.documents.create(DocumentDraft(title: "Child", parentDocumentID: parent.id))
        let independentlyTrashed = try environment.documents.create(DocumentDraft(title: "Already trashed", parentDocumentID: parent.id))
        _ = try environment.documents.trash(id: independentlyTrashed.id)
        _ = try environment.snapshots.create(document: child, reason: .manual)
        let duplicate = try environment.documents.duplicate(id: parent.id)
        let copiedChild = try #require(environment.documents.children(of: duplicate.id).first)
        #expect(copiedChild.id != child.id)
        #expect(copiedChild.title == child.title)
        _ = try environment.documents.trash(id: parent.id)
        #expect(try environment.documents.requireDocument(id: child.id).isTrashed)
        #expect(try environment.documents.trashed().map(\.id) == [parent.id])
        _ = try environment.documents.restore(id: parent.id)
        #expect(try !environment.documents.requireDocument(id: child.id).isTrashed)
        #expect(try environment.documents.requireDocument(id: independentlyTrashed.id).isTrashed)
        try environment.documents.permanentlyDelete(id: parent.id)
        #expect(try environment.documents.document(id: child.id) == nil)
        #expect(try environment.snapshots.history(documentID: child.id).isEmpty)
        #expect(try environment.documents.allDocuments().map(\.id) == [duplicate.id])
        #expect(try environment.documents.requireDocument(id: copiedChild.id).parentDocumentID == duplicate.id)
    }

    @Test func nestedPageSlashRequestUsesNativeDocumentCreation() throws {
        #expect(try TipTapEditorEvent(kind: "nestedPageRequest", payload: ["blockId": "insertion"]) == .requestNestedPage(blockID: "insertion"))
        #expect(try TipTapEditorEvent(kind: "pageOpenRequest", payload: ["documentId": "child"]) == .requestOpenPage(documentID: "child"))
    }

    @Test func positionedPageBlocksPersistAndDuplicateWithTheirOwnChildren() throws {
        let environment = try makeEnvironment()
        let parent = try environment.documents.create(DocumentDraft(title: "Parent"))
        let child = try environment.documents.create(DocumentDraft(title: "Named page", parentDocumentID: parent.id))
        let content: [[String: Any]] = [
            ["type": "paragraph", "content": [["type": "text", "text": "Before"]]],
            ["type": "pageReference", "attrs": ["id": "link", "documentID": child.id]],
            ["type": "paragraph", "content": [["type": "text", "text": "After"]]]
        ]
        let saved = try environment.documents.saveEditorJSON(id: parent.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: content))
        let reopened = try environment.documents.requireDocument(id: parent.id)
        #expect(reopened.tipTapJSON == saved.tipTapJSON)
        #expect(TipTapContentAnalyzer.pageReferenceIDs(in: reopened.tipTapJSON) == [child.id])
        let copy = try environment.documents.duplicate(id: parent.id)
        let copiedChild = try #require(environment.documents.children(of: copy.id).first)
        #expect(TipTapContentAnalyzer.pageReferenceIDs(in: copy.tipTapJSON) == [copiedChild.id])
        #expect(copiedChild.id != child.id)
        let nodes = try #require(TipTapContentAnalyzer.documentObject(from: copy.tipTapJSON)["content"] as? [[String: Any]])
        #expect(nodes.map { $0["type"] as? String } == ["paragraph", "pageReference", "paragraph"])
    }

    @Test func legacyPagesAppendAtBottomWithoutMovingExistingReferences() throws {
        let json = try TipTapContentAnalyzer.makeDocumentJSON(content: [
            ["type": "paragraph", "content": [["type": "text", "text": "Before"]]],
            ["type": "toggleItem", "attrs": ["id": "toggle", "open": true], "content": [
                ["type": "paragraph", "content": [["type": "text", "text": "Summary"]]],
                ["type": "pageReference", "attrs": ["id": "placed", "documentID": "existing"]]
            ]],
            ["type": "pageBreak", "attrs": ["id": "break"]],
            ["type": "paragraph", "content": [["type": "text", "text": "After"]]]
        ])
        let migrated = try TipTapContentAnalyzer.appendingPageReferences(to: json, documentIDs: ["existing", "unplaced"])
        let nodes = try #require(TipTapContentAnalyzer.documentObject(from: migrated)["content"] as? [[String: Any]])
        #expect(nodes.map { $0["type"] as? String } == ["paragraph", "toggleItem", "pageBreak", "paragraph", "pageReference"])
        #expect(TipTapContentAnalyzer.pageReferenceIDs(in: migrated) == ["existing", "unplaced"])
        #expect(try TipTapContentAnalyzer.appendingPageReferences(to: migrated, documentIDs: ["existing", "unplaced"]) == migrated)
        let remapped = try TipTapContentAnalyzer.remappingPageReferences(in: migrated, documentIDs: ["existing": "copied"])
        #expect(TipTapContentAnalyzer.pageReferenceIDs(in: remapped) == ["copied", "unplaced"])
        #expect(try TipTapContentAnalyzer.analyze(remapped).plainText == TipTapContentAnalyzer.analyze(json).plainText)
    }

    @Test func renamingChildUpdatesParentWithoutSubmittingEditorContent() throws {
        let environment = try makeEnvironment()
        let parent = try environment.documents.create(DocumentDraft(title: "Parent"))
        let child = try environment.documents.create(DocumentDraft(title: "Untitled", parentDocumentID: parent.id))
        environment.refresh()
        let childModel = environment.editorCache.prepare(child)
        childModel.rename(title: "Actual title")
        #expect(try environment.documents.requireDocument(id: child.id).title == "Actual title")
        #expect(environment.editorCache.model(for: parent.id)?.children.first?.title == "Actual title")
    }

    @Test func nestedPageDeleteActionsValidateOwnershipAndPreserveRestorePosition() throws {
        let environment = try makeEnvironment()
        let parent = try environment.documents.create(DocumentDraft(title: "Parent"))
        let child = try environment.documents.create(DocumentDraft(title: "Child", parentDocumentID: parent.id))
        let descendant = try environment.documents.create(DocumentDraft(title: "Inside child", parentDocumentID: child.id))
        let unrelated = try environment.documents.create(DocumentDraft(title: "Other page"))
        let json = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Before"}]},{"type":"pageReference","attrs":{"documentID":"CHILD"}},{"type":"paragraph","content":[{"type":"text","text":"After"}]}]}"#
            .replacingOccurrences(of: "CHILD", with: child.id)
        let savedParent = try environment.documents.saveEditorJSON(id: parent.id, canonicalJSON: json)
        environment.refresh()
        let model = environment.editorCache.prepare(savedParent)
        let request = try TipTapEditorEvent(kind: "pageActionsRequest", payload: ["documentId": child.id])
        #expect(request == .requestPageActions(documentID: child.id))
        model.session.onEvent?(request)
        #expect(model.nestedPageActionTarget?.id == child.id)
        #expect(try environment.documents.requireDocument(id: child.id).isTrashed == false)
        model.nestedPageActionTarget = nil
        model.session.onEvent?(.requestPageActions(documentID: unrelated.id))
        #expect(model.nestedPageActionTarget == nil)
        model.trashChildPage(id: unrelated.id)
        #expect(try environment.documents.requireDocument(id: unrelated.id).isTrashed == false)
        _ = try environment.documents.move(id: child.id, spaceID: nil, folderID: nil, parentDocumentID: unrelated.id)
        model.trashChildPage(id: child.id)
        #expect(try environment.documents.requireDocument(id: child.id).isTrashed == false)
        _ = try environment.documents.move(id: child.id, spaceID: nil, folderID: nil, parentDocumentID: parent.id)
        environment.refresh()
        model.trashChildPage(id: child.id)
        #expect(model.children.isEmpty)
        #expect(try environment.documents.requireDocument(id: child.id).isTrashed)
        #expect(try environment.documents.requireDocument(id: descendant.id).isTrashed)
        #expect(try environment.documents.requireDocument(id: parent.id).tipTapJSON == savedParent.tipTapJSON)
        _ = try environment.documents.restore(id: child.id)
        environment.refresh()
        #expect(model.children.first?.id == child.id)
        #expect(try environment.documents.requireDocument(id: descendant.id).isTrashed == false)
        #expect(try environment.documents.requireDocument(id: parent.id).tipTapJSON == savedParent.tipTapJSON)
    }

    @Test func templateCheckmarkAcknowledgesChangesSeparatelyFromAutosave() async throws {
        let environment = try makeEnvironment()
        let template = try environment.templates.create()
        let model = environment.editorCache.prepare(template)
        #expect(model.templateNeedsSave)
        #expect(!model.isSavingTemplate)
        let firstSave = try await model.saveTemplateEdits()
        #expect(firstSave)
        #expect(!model.templateNeedsSave)
        #expect(!model.isSavingTemplate)

        let unchanged = try #require(model.document?.tipTapJSON)
        model.session.onEvent?(.documentSnapshot(unchanged))
        try model.saveCurrentContent()
        #expect(!model.templateNeedsSave)
        let repeatSave = try await model.saveTemplateEdits()
        #expect(!repeatSave)

        let changed = TipTapContentAnalyzer.starterDocument(title: "", lines: ["New template content"])
        model.session.onEvent?(.documentChanged(changed))
        #expect(model.templateNeedsSave)
        try model.saveCurrentContent()
        #expect(model.templateNeedsSave)
        let secondSave = try await model.saveTemplateEdits()
        #expect(secondSave)
        #expect(!model.templateNeedsSave)
        #expect(try environment.documents.requireDocument(id: template.id).plainText == "New template content")
    }

    @Test func titleIconAndStyleChangesReactivateTemplateCheckmark() async throws {
        let environment = try makeEnvironment()
        let template = try environment.templates.create()
        let model = environment.editorCache.prepare(template)
        _ = try await model.saveTemplateEdits()
        model.rename(title: "New title")
        #expect(model.templateNeedsSave)
        _ = try await model.saveTemplateEdits()
        model.rename(title: "New title")
        #expect(!model.templateNeedsSave)
        model.updateIcon("linedpages")
        #expect(model.templateNeedsSave)
        _ = try await model.saveTemplateEdits()
        var appearance = model.appearance
        appearance.fontStyle = .serif
        model.updateAppearance(cover: nil, appearance: appearance)
        #expect(model.templateNeedsSave)
        _ = try await model.saveTemplateEdits()
        #expect(!model.templateNeedsSave)
    }

    @Test func nestedTemplateEditsReactivateAncestorCheckmarks() async throws {
        let environment = try makeEnvironment()
        let root = try environment.templates.create()
        let child = try environment.documents.create(DocumentDraft(title: "Child", parentDocumentID: root.id))
        let grandchild = try environment.documents.create(DocumentDraft(title: "Grandchild", parentDocumentID: child.id))
        let rootModel = environment.editorCache.prepare(root)
        let childModel = environment.editorCache.prepare(child)
        let grandchildModel = environment.editorCache.prepare(grandchild)
        _ = try await rootModel.saveTemplateEdits()
        _ = try await childModel.saveTemplateEdits()
        _ = try await grandchildModel.saveTemplateEdits()
        #expect(!rootModel.templateNeedsSave)
        #expect(!childModel.templateNeedsSave)
        let guidance = try TipTapContentAnalyzer.makeDocumentJSON(content: [[
            "type": "paragraph", "attrs": ["id": "guidance", "placeholderEnabled": true,
                "placeholderGuidance": [["type": "text", "text": "Write something here"]]]
        ]])
        grandchildModel.session.onEvent?(.documentChanged(guidance))
        try grandchildModel.saveCurrentContent()
        #expect(grandchildModel.templateNeedsSave)
        #expect(childModel.templateNeedsSave)
        #expect(rootModel.templateNeedsSave)
    }

    @Test func ordinaryDocumentsNeverEnableTemplateSaveState() async throws {
        let environment = try makeEnvironment()
        let document = try environment.documents.create(DocumentDraft(title: "Ordinary"))
        let model = environment.editorCache.prepare(document)
        model.session.onEvent?(.documentChanged(TipTapContentAnalyzer.starterDocument(title: "", lines: ["Content"])))
        try model.saveCurrentContent()
        #expect(!model.templateNeedsSave)
        let saved = try await model.saveTemplateEdits()
        #expect(!saved)
    }

    @Test func templateCreatesValidDocument() throws {
        let environment = try makeEnvironment()
        let source = try environment.documents.create(DocumentDraft(title: "My Plan",
            tipTapJSON: TipTapContentAnalyzer.starterDocument(title: "My Plan", lines: ["Overview", "Milestones"])))
        let template = try environment.templates.saveUserTemplate(from: source, title: "My Plan Template")
        let document = try environment.documents.create(
            DocumentDraft(
                title: template.title,
                templateOriginID: template.id,
                tipTapJSON: template.tipTapJSON
            )
        )

        #expect(document.templateOriginID == template.id)
        #expect(document.plainText.contains("Milestones"))
    }

    @Test func structuredTemplatesCloneNestedPagesFormattingAndGuidanceIndependently() throws {
        let environment = try makeEnvironment()
        let folder = try environment.folders.create(title: "Keep This Folder", spaceID: nil)
        let source = try environment.documents.create(DocumentDraft(title: "Source", folderID: folder.id,
            appearanceJSON: DocumentAppearance.defaultForTheme(.lunarClouds).encodedJSON(),
            tipTapJSON: TipTapContentAnalyzer.starterDocument(title: "Source", lines: ["Permanent instruction"])))
        let childJSON = try TipTapContentAnalyzer.makeDocumentJSON(content: [[
            "type": "callout", "attrs": ["id": "callout", "color": "#FF00BB", "icon": "sparkle"],
            "content": [["type": "paragraph", "attrs": ["id": "guided", "placeholderEnabled": true,
                "placeholderGuidance": [["type": "text", "text": "What did you learn?"]]], "content": []]]
        ]])
        let child = try environment.documents.create(DocumentDraft(title: "Child", parentDocumentID: source.id, tipTapJSON: childJSON))
        let rootJSON = try TipTapContentAnalyzer.appendingPageReferences(to: source.tipTapJSON, documentIDs: [child.id])
        let updated = try environment.documents.saveEditorJSON(id: source.id, canonicalJSON: rootJSON)
        let template = try environment.templates.saveUserTemplate(from: updated, title: "Guided Template", attachmentStore: environment.attachmentStore)
        let rootID = try #require(template.rootDocumentID)
        let templateRoot = try environment.documents.requireDocument(id: rootID)
        let templateChild = try #require(environment.documents.children(of: rootID).first)
        #expect(templateChild.templateID == template.id)
        #expect(templateChild.id != child.id)
        #expect(templateRoot.appearance == source.appearance)
        #expect(try environment.documents.allDocuments().map(\.id) == [source.id])

        let first = try environment.templates.instantiate(id: template.id, title: "First", spaceID: nil,
            folderID: folder.id, parentID: nil, attachmentStore: environment.attachmentStore)
        let second = try environment.templates.instantiate(id: template.id, title: "Second", spaceID: nil,
            folderID: nil, parentID: nil, attachmentStore: environment.attachmentStore)
        let firstChild = try #require(environment.documents.children(of: first.id).first)
        let secondChild = try #require(environment.documents.children(of: second.id).first)
        #expect(first.templateID == nil)
        #expect(firstChild.templateID == nil)
        #expect(firstChild.folderID == folder.id)
        #expect(firstChild.id != secondChild.id && firstChild.id != templateChild.id)
        #expect(first.appearance == templateRoot.appearance)
        #expect(first.plainText.contains("Permanent instruction"))
        #expect(firstChild.plainText.isEmpty)
        #expect(firstChild.tipTapJSON.contains("What did you learn?"))
        #expect(firstChild.tipTapJSON.contains("#FF00BB"))
        #expect(TipTapContentAnalyzer.pageReferenceIDs(in: first.tipTapJSON) == [firstChild.id])
        #expect(firstChild.tipTapJSON != secondChild.tipTapJSON)
        _ = try environment.documents.saveEditorJSON(id: firstChild.id,
            canonicalJSON: TipTapContentAnalyzer.starterDocument(title: "Filled", lines: ["Actual answer"]))
        #expect(try environment.documents.requireDocument(id: templateChild.id).tipTapJSON == templateChild.tipTapJSON)
        #expect(try environment.documents.requireDocument(id: secondChild.id).tipTapJSON == secondChild.tipTapJSON)
        try environment.templates.delete(id: template.id, attachmentStore: environment.attachmentStore)
        #expect(try environment.documents.requireDocument(id: first.id).templateOriginID == nil)
        #expect(try environment.documents.requireDocument(id: firstChild.id).plainText == "Actual answer")
        #expect(try environment.documents.requireDocument(id: source.id).folderID == folder.id)
    }

    @Test func authoringProjectionNeverReachesSavedTextOrSearch() throws {
        let json = try TipTapContentAnalyzer.makeDocumentJSON(content: [[
            "type": "heading", "attrs": ["id": "prompt", "level": 2, "placeholderProjection": true],
            "content": [["type": "text", "text": "Guidance only", "marks": [["type": "bold"]]]]
        ]])
        let analysis = try TipTapContentAnalyzer.analyze(json)
        #expect(analysis.plainText.isEmpty)
        #expect(analysis.wordCount == 0)
        #expect(!analysis.canonicalJSON.contains("placeholderProjection"))
        #expect(analysis.canonicalJSON.contains("placeholderGuidance"))
        let object = TipTapContentAnalyzer.documentObject(from: analysis.canonicalJSON)
        let block = try #require((object["content"] as? [[String: Any]])?.first)
        #expect((block["content"] as? [Any])?.isEmpty == true)
    }

    @Test func templateRenameDuplicateAndReopenPreserveGuidance() throws {
        let environment = try makeEnvironment()
        let root = try environment.templates.create(title: "Template")
        let templateID = try #require(root.templateID)
        _ = try environment.documents.saveEditorJSON(id: root.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [[
            "type": "paragraph", "attrs": ["id": "field", "placeholderEnabled": true,
                "placeholderGuidance": [["type": "text", "text": "Answer here"]]], "content": []
        ]]))
        try environment.templates.rename(id: templateID, title: "Renamed")
        let reopened = try environment.templates.editingDocument(id: templateID)
        #expect(reopened.title == "Renamed")
        #expect(reopened.tipTapJSON.contains("Answer here"))
        let copy = try environment.templates.duplicate(id: templateID, attachmentStore: environment.attachmentStore)
        let copiedRoot = try environment.templates.editingDocument(id: copy.id)
        #expect(copy.id != templateID && copiedRoot.id != root.id)
        #expect(copiedRoot.tipTapJSON.contains("Answer here"))
        #expect(copiedRoot.tipTapJSON != reopened.tipTapJSON)
        #expect(try environment.search.search("Answer here").isEmpty)
    }

    @Test func automaticSnapshotsArePrunedAndRestorable() throws {
        let environment = try makeEnvironment()
        var document = try environment.documents.create(DocumentDraft(title: "Snapshots"))
        for index in 0..<25 {
            document = try environment.documents.saveEditorJSON(
                id: document.id,
                canonicalJSON: TipTapContentAnalyzer.starterDocument(
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
                tipTapJSON: TipTapContentAnalyzer.starterDocument(
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
