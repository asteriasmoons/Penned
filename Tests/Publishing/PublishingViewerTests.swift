import Foundation
import Testing
@testable import Vellix

@Suite @MainActor
struct PublishingViewerTests {
    private func paragraph(_ text: String) -> [String: Any] { ["type": "paragraph", "content": [["type": "text", "text": text]]] }

    @Test func optedInParentIncludesChildAndGrandchildBodiesWithoutSeparatePublicationOrPrivateHierarchy() throws {
        let db = try AppDatabase.makeInMemory(), docs = DocumentRepository(database: db)
        let parent = try docs.create(DocumentDraft(title: "PRIVATE PARENT"))
        let root = try docs.create(DocumentDraft(title: "Selected", parentDocumentID: parent.id))
        _ = try docs.create(DocumentDraft(title: "PRIVATE SIBLING", parentDocumentID: parent.id))
        let child = try docs.create(DocumentDraft(title: "Child", parentDocumentID: root.id))
        let grandchild = try docs.create(DocumentDraft(title: "Grandchild", parentDocumentID: child.id))
        _ = try docs.saveEditorJSON(id: child.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [paragraph("Child actual body"), ["type": "pageReference", "attrs": ["documentID": root.id]], ["type": "pageReference", "attrs": ["documentID": grandchild.id]]]))
        _ = try docs.saveEditorJSON(id: grandchild.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [paragraph("Grandchild actual body")]))
        var appearance = grandchild.appearance; appearance.fontStyle = .serif; appearance.textColorHex = "#123456"
        _ = try docs.updateAppearance(id: grandchild.id, cover: nil, appearance: appearance)
        let builder = PublishingDocumentBuilder(database: db, attachmentStore: .previewStore())
        let off = try builder.prepare(documentID: root.id, owner: .apple("owner"))
        #expect(off.document.linkedPages == nil)
        let on = try builder.prepare(documentID: root.id, owner: .apple("owner"), includeLinkedPages: true)
        let pages = try #require(on.document.linkedPages); #expect(pages.count == 2)
        let wire = String(decoding: try JSONEncoder().encode(on.document), as: UTF8.self)
        #expect(wire.contains("Child actual body")); #expect(wire.contains("Grandchild actual body")); #expect(wire.contains("#123456"))
        #expect(wire.contains("targetPage")); #expect(!wire.contains("targetDocumentID")); #expect(!wire.contains("PRIVATE"))
        for id in [root.id, child.id, grandchild.id, parent.id] { #expect(!wire.contains(id)) }
        let childPage = try #require(pages.first { $0.document.title == "Child" }), grandchildPage = try #require(pages.first { $0.document.title == "Grandchild" })
        #expect(childPage.parentKey == "root"); #expect(grandchildPage.parentKey == childPage.key)
        try exportLinkedFixture(on, name: "pages")
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM publicationJobs") } == 0)
        _ = try docs.saveEditorJSON(id: grandchild.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [paragraph("Updated child writing")]))
        let updated = try builder.prepare(documentID: root.id, owner: .apple("owner"), includeLinkedPages: true)
        #expect(try updated.document.fingerprint() != on.document.fingerprint())
        _ = try docs.trash(id: grandchild.id)
        #expect(try builder.prepare(documentID: root.id, owner: .apple("owner"), includeLinkedPages: true).document.linkedPages?.count == 1)
    }

    @Test func collectionEntryPagesAreIncludedWithApprovedFieldsAndPublicationScopedMedia() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.makeInMemory(), docs = DocumentRepository(database: db), store = AttachmentStore(rootURL: directory)
        let root = try docs.create(DocumentDraft(title: "Root")), collections = CollectionRepository(database: db, documents: docs)
        let collection = try collections.create(ownerID: root.id, name: "Entries", viewName: "Main", kind: .gallery)
        let hidden = CollectionField(collectionID: collection.record.id, name: "PRIVATE FIELD", kind: .text)
        try collections.saveField(hidden)
        let entry = try collections.addEntry(collectionID: collection.record.id, title: "Entry page")
        try collections.saveValue(collectionID: collection.record.id, documentID: entry.id, fieldID: hidden.id, value: CollectionValue(text: "PRIVATE VALUE"))
        var view = try #require(collections.snapshot(id: collection.record.id).activeView), config = view.configuration
        config.visibleFieldIDs = []; view.configuration = config; try collections.saveView(view)
        let file = try docs.attachmentRepository(store: store).importData(Data("Child attachment bytes".utf8), originalFileName: "child.txt", mimeType: "text/plain", documentID: entry.id)
        _ = try docs.saveEditorJSON(id: entry.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [paragraph("Actual collection entry body"), ["type": "attachment", "attrs": ["file": ["relativePath": file.relativePath, "kind": "file"]]]]))
        _ = try docs.saveEditorJSON(id: root.id, canonicalJSON: CollectionRepository.blockJSON(collectionID: collection.record.id, documentID: root.id))
        let result = try PublishingDocumentBuilder(database: db, attachmentStore: store).prepare(documentID: root.id, owner: .apple("owner"), includeLinkedPages: true)
        #expect(result.document.linkedPages?.count == 1); #expect(result.document.media.count == 1)
        #expect(result.document.linkedPages?.first?.document.media == result.document.media)
        #expect(result.files.values.first == Data("Child attachment bytes".utf8))
        let wire = String(decoding: try JSONEncoder().encode(result.document), as: UTF8.self)
        #expect(wire.contains("Actual collection entry body")); #expect(!wire.contains("PRIVATE")); #expect(!wire.contains(file.relativePath))
        try exportLinkedFixture(result, name: "collection")
    }

    private func exportLinkedFixture(_ prepared: PreparedPublication, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PENNED_LINKED_FIXTURE_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["sourceLibraryID": prepared.sourceLibraryID, "sourceDocumentID": prepared.sourceDocumentID,
            "document": JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared.document)), "files": prepared.files.mapValues { $0.base64EncodedString() }], options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }

    @Test func everySavedCollectionViewKeepsItsOwnVisibleFieldsAndLayoutWithoutPrivateBodies() throws {
        let db = try AppDatabase.makeInMemory(), docs = DocumentRepository(database: db)
        let page = try docs.create(DocumentDraft(title: "View switching")), collections = CollectionRepository(database: db, documents: docs)
        let collection = try collections.create(ownerID: page.id, name: "Saved views", viewName: "Home", kind: .gallery)
        let first = CollectionField(collectionID: collection.record.id, name: "Gallery field", kind: .text)
        let second = CollectionField(collectionID: collection.record.id, name: "Table field", kind: .text)
        let hidden = CollectionField(collectionID: collection.record.id, name: "PRIVATE FIELD", kind: .text)
        for field in [first, second, hidden] { try collections.saveField(field) }
        let entry = try collections.addEntry(collectionID: collection.record.id, title: "Saved entry")
        _ = try docs.saveEditorJSON(id: entry.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [paragraph("PRIVATE BODY")]))
        var gallery = try #require(collections.snapshot(id: collection.record.id).activeView), config = gallery.configuration
        config.visibleFieldIDs = [first.id]; config.galleryColumns = 3; gallery.configuration = config; try collections.saveView(gallery)
        var table = try collections.addView(collectionID: collection.record.id, name: "Main", kind: .table)
        config = table.configuration; config.visibleFieldIDs = [second.id]; table.configuration = config; try collections.saveView(table)
        try collections.selectView(collectionID: collection.record.id, viewID: gallery.id)
        let root = try #require(JSONSerialization.jsonObject(with: Data(CollectionRepository.blockJSON(collectionID: collection.record.id, documentID: page.id).utf8)) as? [String: Any])
        let projected = try PublishingVisibleContent.prepare(root, document: page, repository: docs, collections: collections)
        let nodes = try #require(projected["content"] as? [[String: Any]])
        let attrs = try #require(nodes.first?["attrs"] as? [String: Any]), value = try #require(attrs["projection"] as? [String: Any])
        let views = try #require(value["views"] as? [[String: Any]])
        #expect(views.count == 2); #expect(views[0]["galleryColumns"] as? Int == 3)
        #expect((views[0]["fields"] as? [[String: String]])?.first?["name"] == "Gallery field")
        #expect((views[1]["fields"] as? [[String: String]])?.first?["name"] == "Table field")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: projected), as: UTF8.self)
        #expect(!json.contains("PRIVATE")); #expect(!json.contains(collection.record.id)); #expect(!json.contains(gallery.id))
    }

    @Test func visibleCollectionsExcludeHiddenFieldsAndEntryBodies() throws {
        let db = try AppDatabase.makeInMemory(), docs = DocumentRepository(database: db)
        let page = try docs.create(DocumentDraft(title: "Visible collection"))
        let collections = CollectionRepository(database: db, documents: docs)
        let created = try collections.create(ownerID: page.id, name: "Visible board", viewName: "Main", kind: .kanban)
        let visible = CollectionField(collectionID: created.record.id, name: "Visible field", kind: .text)
        let hidden = CollectionField(collectionID: created.record.id, name: "PRIVATE HIDDEN FIELD", kind: .text)
        try collections.saveField(visible); try collections.saveField(hidden)
        let entry = try collections.addEntry(collectionID: created.record.id, title: "Visible entry")
        _ = try docs.saveEditorJSON(id: entry.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [paragraph("PRIVATE ENTRY BODY")]))
        try collections.saveValue(collectionID: created.record.id, documentID: entry.id, fieldID: visible.id, value: CollectionValue(text: "Approved value"))
        try collections.saveValue(collectionID: created.record.id, documentID: entry.id, fieldID: hidden.id, value: CollectionValue(text: "PRIVATE VALUE"))
        var view = try #require(collections.snapshot(id: created.record.id).activeView), config = view.configuration
        config.visibleFieldIDs = [visible.id]; view.configuration = config; try collections.saveView(view)
        _ = try docs.saveEditorJSON(id: page.id, canonicalJSON: CollectionRepository.blockJSON(collectionID: created.record.id, documentID: page.id))
        let prepared = try PublishingDocumentBuilder(database: db, attachmentStore: .previewStore()).prepare(documentID: page.id, owner: .apple("owner"))
        let wire = String(decoding: try JSONEncoder().encode(prepared.document), as: UTF8.self)
        #expect(wire.contains("publishedCollection")); #expect(wire.contains("kanban")); #expect(wire.contains("Approved value"))
        #expect(!wire.contains("PRIVATE")); #expect(!wire.contains(visible.id)); #expect(!wire.contains(hidden.id)); #expect(!wire.contains(created.record.id))
    }

    @Test func childRowsAndCardsRemainVisibleWithoutPublishingTheirBodies() throws {
        let db = try AppDatabase.makeInMemory(), docs = DocumentRepository(database: db)
        let parent = try docs.create(DocumentDraft(title: "PRIVATE PARENT"))
        let selected = try docs.create(DocumentDraft(title: "Selected", parentDocumentID: parent.id))
        _ = try docs.create(DocumentDraft(title: "PRIVATE SIBLING", parentDocumentID: parent.id))
        var card = PageCardStyle(); card.size = .large; card.backdrop = .gradient
        let child = try docs.create(DocumentDraft(title: "Visible child card", parentDocumentID: selected.id, cardStyleJSON: card.encodedJSON()))
        _ = try docs.saveEditorJSON(id: child.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [paragraph(String(repeating: "Visible preview. ", count: 50)), paragraph("PRIVATE BODY TAIL")]))
        let prepared = try PublishingDocumentBuilder(database: db, attachmentStore: .previewStore()).prepare(documentID: selected.id, owner: .apple("owner"))
        let wire = String(decoding: try JSONEncoder().encode(prepared.document), as: UTF8.self)
        #expect(wire.contains("Visible child card")); #expect(wire.contains("cardStyle")); #expect(wire.contains("large"))
        #expect(!wire.contains("PRIVATE")); #expect(!wire.contains(parent.id))
    }

    @Test func followLinkedContentDefaultsOffForPreviouslyPublishedSettings() throws {
        let old = Data("{\"showTitle\":true,\"showAuthor\":false,\"showTableOfContents\":true,\"allowIndexing\":false,\"authorName\":\"\"}".utf8)
        #expect(try JSONDecoder().decode(PublishingSettings.self, from: old).allowFollowLinkedContent == false)
        var settings = PublishingSettings(); settings.allowFollowLinkedContent = true
        #expect(try JSONDecoder().decode(PublishingSettings.self, from: JSONEncoder().encode(settings)).allowFollowLinkedContent)
    }

    @Test func exportSavedReaderDocumentsWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["PENNED_READER_FIXTURE_DIR"],
              let assets = ProcessInfo.processInfo.environment["PENNED_READER_FIXTURE_ASSETS"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try AppDatabase.makeInMemory(), docs = DocumentRepository(database: db), store = AttachmentStore(rootURL: directory.appendingPathComponent("attachments"))
        let selected = try docs.create(DocumentDraft(title: "A Penned Reading Journal", subtitle: "Saved native content, published through the real API"))
        let attachments = docs.attachmentRepository(store: store)
        let image = try attachments.importData(Data(contentsOf: URL(fileURLWithPath: assets).appendingPathComponent("Penned.png")), originalFileName: "Penned.png", mimeType: "image/png", documentID: selected.id)
        let pdf = try attachments.importData(Data(contentsOf: URL(fileURLWithPath: assets).appendingPathComponent("Guide.pdf")), originalFileName: "Guide.pdf", mimeType: "application/pdf", documentID: selected.id)
        let audio = try attachments.importData(Data(contentsOf: URL(fileURLWithPath: assets).appendingPathComponent("Tone.wav")), originalFileName: "Tone.wav", mimeType: "audio/wav", documentID: selected.id)
        let video = try attachments.importData(Data(contentsOf: URL(fileURLWithPath: assets).appendingPathComponent("Clip.mp4")), originalFileName: "Clip.mp4", mimeType: "video/mp4", documentID: selected.id)
        func attachment(_ file: AttachmentRecord, _ kind: String) -> [String: Any] {
            var value: [String: Any] = ["relativePath": file.relativePath, "kind": kind]
            if let preview = file.thumbnailRelativePath { value["previewPath"] = preview }
            return ["type": "attachment", "attrs": ["file": value]]
        }
        var cardStyle = PageCardStyle(); cardStyle.size = .large; cardStyle.backdrop = .gradient; cardStyle.startColor = "#377D88"; cardStyle.endColor = "#984E86"
        let child = try docs.create(DocumentDraft(title: "A nested reading page", parentDocumentID: selected.id, cardStyleJSON: cardStyle.encodedJSON()))
        _ = try docs.saveEditorJSON(id: child.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [paragraph("A saved page card, with its original backdrop and a visible excerpt."), paragraph(String(repeating: "Reading notes. ", count: 50)), paragraph("PRIVATE DESTINATION BODY TAIL")]))
        var nodes: [[String: Any]] = [
            paragraph("A place for reading, reflection, and the details worth keeping. This document exercises Penned’s actual saved block types."),
            ["type": "heading", "attrs": ["level": 2], "content": [["type": "text", "text": "The reading desk"]]],
            ["type": "paragraph", "content": [["type": "text", "text": "Selected words", "marks": [["type": "bold"], ["type": "italic"], ["type": "underline"]]], ["type": "text", "text": " can carry a "], ["type": "text", "text": "custom gradient", "marks": [["type": "textStyle", "attrs": ["gradient": ["start": "#BC76FF", "end": "#FF7AB6", "angle": 90]]]]], ["type": "text", "text": " and a working "], ["type": "text", "text": "external link", "marks": [["type": "link", "attrs": ["href": "https://example.com"]]]]]],
            ["type": "callout", "attrs": ["icon": "sparkle", "color": "#E59BD1"], "content": [paragraph("Keep a little room for something unexpected.")]],
            ["type": "plainCallout", "attrs": ["color": "#79DCC4"], "content": [paragraph("A callout without an icon retains its own saved color.")]],
            ["type": "blockquote", "attrs": ["color": "#BC76FF"], "content": [paragraph("The best notes preserve the feeling of a thought as well as the thought itself.")]],
            ["type": "toggleItem", "attrs": ["open": false], "content": [paragraph("Open these reading notes"), paragraph("Expandable writing stays selectable, searchable, and read-only."), ["type": "heading", "attrs": ["level": 3], "content": [["type": "text", "text": "A heading inside the toggle"]]]]],
            ["type": "taskList", "content": [["type": "taskItem", "attrs": ["checked": true], "content": [paragraph("Finish the chapter")]], ["type": "taskItem", "attrs": ["checked": false, "crossed": true], "content": [paragraph("A skipped task")]], ["type": "taskItem", "attrs": ["checked": false], "content": [paragraph("Start another page")]]]],
            ["type": "bulletList", "content": [["type": "listItem", "content": [paragraph("A small observation")]], ["type": "listItem", "content": [paragraph("A line worth remembering")]]]],
            ["type": "orderedList", "attrs": ["start": 3], "content": [["type": "listItem", "content": [paragraph("Continue where you left off")]]]],
            ["type": "inlineProperty", "attrs": ["property": ["kind": "multiSelect", "name": "Themes", "options": [["id": "a", "name": "Wonder", "color": "#6ACDB9"], ["id": "b", "name": "Writing", "color": "#E59BD1"]], "selectedOptionIDs": ["a", "b"]]]],
            ["type": "templateComponent", "attrs": ["definition": ["kind": "slider", "label": "Energy", "minimum": 1, "maximum": 5, "step": 1], "response": 3]],
            ["type": "templateComponent", "attrs": ["definition": ["kind": "multiSelect", "label": "Today’s mood", "choices": [["id": "a", "label": "Curious"], ["id": "b", "label": "Thoughtful"], ["id": "c", "label": "Quiet"]]], "response": ["a", "b"]]],
            ["type": "divider", "attrs": ["style": "dottedCircles"]],
            ["type": "heading", "attrs": ["level": 2], "content": [["type": "text", "text": "Tables and collections"]]],
        ]
        func cell(_ text: String, header: Bool = false, formula: String? = nil) -> [String: Any] {
            var attrs: [String: Any] = ["colspan": 1, "rowspan": 1, "colwidth": [180]]
            if let formula { attrs["formula"] = formula; attrs["format"] = "number"; attrs["decimals"] = 0 }
            return ["type": header ? "tableHeader" : "tableCell", "attrs": attrs, "content": [paragraph(text)]]
        }
        nodes.append(["type": "table", "attrs": ["name": "ReadingLog", "stripeColor": "#FFFFFF08"], "content": [
            ["type": "tableRow", "content": [cell("Morning", header: true), cell("Evening", header: true), cell("Total", header: true)]],
            ["type": "tableRow", "content": [cell("5"), cell("8"), cell("", formula: "=SUM(A2:B2)")]]]])
        let collections = CollectionRepository(database: db, documents: docs)
        for kind in CollectionViewKind.allCases {
            let container = try docs.create(DocumentDraft(title: "\(kind.title) collection page", parentDocumentID: selected.id))
            let snapshot = try collections.create(ownerID: container.id, name: "\(kind.title) reading shelf", viewName: "Main", kind: kind)
            let field = CollectionField(collectionID: snapshot.record.id, name: "Status", kind: .text)
            let hidden = CollectionField(collectionID: snapshot.record.id, name: "PRIVATE HIDDEN FIELD", kind: .text)
            try collections.saveField(field); try collections.saveField(hidden)
            var view = try #require(collections.snapshot(id: snapshot.record.id).activeView), config = view.configuration
            config.visibleFieldIDs = [field.id]; view.configuration = config; try collections.saveView(view)
            let titles = ["The next chapter", "Notes in the margins", "A different perspective"]
            for (index, title) in titles.enumerated() {
                let entry = try collections.addEntry(collectionID: snapshot.record.id, title: title)
                try collections.saveValue(collectionID: snapshot.record.id, documentID: entry.id, fieldID: field.id, value: CollectionValue(text: index == 0 ? "Reading" : "Saved"))
                try collections.saveValue(collectionID: snapshot.record.id, documentID: entry.id, fieldID: hidden.id, value: CollectionValue(text: "PRIVATE HIDDEN VALUE"))
                _ = try docs.saveEditorJSON(id: entry.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [paragraph("PRIVATE ENTRY BODY")]))
                var entryAppearance = DocumentAppearance.defaultForTheme(index == 0 ? .lunarClouds : .neonCode)
                if index == 1 { entryAppearance.showsCover = false }
                _ = try docs.updateAppearance(id: entry.id, cover: nil, appearance: entryAppearance)
            }
            if kind == .gallery {
                for alternative in [CollectionViewKind.table, .kanban] {
                    var extra = try collections.addView(collectionID: snapshot.record.id, name: alternative.title, kind: alternative)
                    var options = extra.configuration; options.visibleFieldIDs = [field.id]; extra.configuration = options
                    try collections.saveView(extra)
                }
                try collections.selectView(collectionID: snapshot.record.id, viewID: view.id)
            }
            nodes.append(["type": "collection", "attrs": ["collectionID": snapshot.record.id, "documentID": container.id]])
        }
        nodes += [["type": "pageBreak"], ["type": "heading", "attrs": ["level": 2], "content": [["type": "text", "text": "Media and linked pages"]]],
            attachment(image, "image"), attachment(pdf, "pdf"), attachment(audio, "audio"), attachment(video, "video"),
            ["type": "pageReference", "attrs": ["documentID": child.id]], ["type": "divider", "attrs": ["style": "fourCircles"]],
            ["type": "codeBlock", "attrs": ["language": "swift"], "content": [["type": "text", "text": "let thought = \"Keep this one\"\nprint(thought)"]]]]
        _ = try docs.saveEditorJSON(id: selected.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: nodes))
        for (name, style) in [("dark", DocumentAppearance.defaultForTheme(.neonCode)), ("light", DocumentAppearance(themeID: .custom, editorBackground: .solid("#DCE9E8"), innerPageBackground: .solid("#FFFFFF"), textColorHex: "#273A3C", fontStyle: .serif))] {
            var appearance = style; appearance.showsCover = true
            let target = name == "dark" ? selected : try docs.duplicate(id: selected.id, attachmentStore: store)
            _ = try docs.updateTitle(id: target.id, title: selected.title)
            if name == "light" {
                appearance.editorBackground = .image(path: image.relativePath, fallback: "#DCE9E8")
                appearance.editorBackground.effect = .faded
                appearance.editorBackground.blurImage = true
            }
            _ = try docs.updateAppearance(id: target.id, cover: nil, appearance: appearance)
            let prepared = try PublishingDocumentBuilder(database: db, attachmentStore: store).prepare(documentID: target.id, owner: .apple("fixture"))
            let payload: [String: Any] = ["sourceLibraryID": prepared.sourceLibraryID, "sourceDocumentID": prepared.sourceDocumentID,
                "document": try JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared.document)),
                "files": prepared.files.mapValues { $0.base64EncodedString() }]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE"))
            try data.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
        }
        let linked = try PublishingDocumentBuilder(database: db, attachmentStore: store).prepare(documentID: child.id, owner: .apple("fixture"))
        try JSONSerialization.data(withJSONObject: ["sourceLibraryID": linked.sourceLibraryID, "sourceDocumentID": linked.sourceDocumentID,
            "document": JSONSerialization.jsonObject(with: JSONEncoder().encode(linked.document)), "files": linked.files.mapValues { $0.base64EncodedString() }])
            .write(to: directory.appendingPathComponent("linked.json"), options: .atomic)
    }
}
