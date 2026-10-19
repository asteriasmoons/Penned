import Foundation
import SwiftUI
import Testing
import WebKit
#if os(macOS)
import AppKit
#endif
@testable import Vellix

@Suite @MainActor
struct PadWorkspaceTests {
    private func environment(_ database: AppDatabase? = nil) throws -> AppEnvironment {
        let app = AppEnvironment(database: try database ?? AppDatabase.makeInMemory(),
            attachmentStore: AttachmentStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        try app.bootstrap()
        return app
    }

    @Test func sidebarPolicyUsesWindowProportionsAndAvailableWidth() {
        #expect(PadWorkspaceMetrics(width: 889, height: 1280).overlaysSidebar)
        #expect(!PadWorkspaceMetrics(width: 1280, height: 889).overlaysSidebar)
        #expect(PadWorkspaceMetrics(width: 900, height: 600).overlaysSidebar)
        #expect(PadWorkspaceMetrics(width: 1100, height: 1400).overlaysSidebar)
        #expect(PadWorkspaceMetrics(width: 1280, height: 889).sidebarWidth == 336)
    }

    @Test func initializationDoesNotPublishNavigationChangesWhileSwiftUIBuildsTheView() throws {
        let app = try environment()
        let original = app.selectedDestination
        let tabs = PadWorkspaceModel(environment: app)
        #expect(app.selectedDestination == original)
        tabs.start()
        #expect(app.selectedDestination == .allDocuments)
        app.selectedDestination = .favorites
        let requested = PadWorkspaceModel(environment: app)
        #expect(app.selectedDestination == .favorites)
        requested.start()
        #expect(app.selectedDestination == .favorites)
    }

    @Test func smallerGalleryCardsUseAvailableColumnsWithoutStretching() {
        let portrait = PadWorkspaceMetrics(width: 889, height: 1280)
        let landscape = PadWorkspaceMetrics(width: 1280, height: 889)
        #expect(PadWorkspaceMetrics.galleryColumns(width: 857, preferred: portrait.preferredColumns) == 3)
        #expect(PadWorkspaceMetrics.galleryColumns(width: 912, preferred: landscape.preferredColumns) == 3)
        #expect(PadWorkspaceMetrics.galleryColumns(width: 1248, preferred: landscape.preferredColumns) == 5)
        #expect(PadWorkspaceMetrics.galleryColumns(width: 857, preferred: portrait.preferredColumns + 1, compact: true) == 4)
        #expect(PadWorkspaceMetrics.galleryColumns(width: 300, preferred: 4) == 1)
        #expect(PadWorkspaceMetrics(width: 1920, height: 1080).preferredColumns > 4)
    }

    @Test func galleryAddsTenPercentWidthThenFivePercentProportionalEnlargement() {
        let phoneWidth: CGFloat = 430
        let phoneCardWidth = (phoneWidth - 16 * 2 - 10) / 2
        #expect(PadWorkspaceMetrics.phoneGalleryCardWidth == phoneCardWidth)
        let enlarged = phoneCardWidth * 1.1 * 1.05
        #expect(abs(PadWorkspaceMetrics.galleryPreferredCardWidth - enlarged) < 0.001)
        #expect(PadWorkspaceMetrics.galleryCardWidth(available: phoneWidth, columns: 2) == phoneCardWidth)
        for (width, columns): (CGFloat, Int) in [(1280, 5), (889, 3), (944, 3), (300, 1)] {
            #expect(abs(PadWorkspaceMetrics.galleryCardWidth(available: width, columns: columns) - enlarged) < 0.001)
        }
        let oldHeight = phoneCardWidth * 740 / 360 * 0.8
        let newHeight = enlarged * 740 / 360 * PadWorkspaceMetrics.galleryPreviewHeightFraction
        #expect(abs(newHeight / oldHeight - 1.05) < 0.001)
        #expect(PadWorkspaceMetrics.galleryCardWidth(available: 889, columns: 5, compact: true) == 144)
        #expect(PadWorkspaceMetrics.galleryCardWidth(available: 150, columns: 1) == 118)
    }

    @Test func tabsCreateSelectCloseAndKeepOneUsableDestination() async throws {
        let app = try environment(), tabs = PadWorkspaceModel(environment: app)
        let original = tabs.activeID
        try await tabs.newTab(PadWorkspaceLocation(destination: .tasks))
        let tasks = tabs.activeID
        #expect(tabs.tabs.count == 2 && tabs.activeTab.location.destination == .tasks)
        try await tabs.selectTab(original)
        #expect(app.selectedDestination == .allDocuments)
        try await tabs.selectTab(tasks)
        #expect(tabs.activeTab.location.destination == .tasks)
        try await tabs.closeTab(tasks)
        #expect(tabs.activeID == original && tabs.tabs.count == 1)
        try await tabs.closeTab(original)
        #expect(tabs.tabs.count == 1 && tabs.activeTab.location == PadWorkspaceLocation())
    }

    @Test func eachTabKeepsItsFolderTagsAndNavigationHistory() async throws {
        let app = try environment()
        let folder = try app.folders.create(title: "Projects")
        let tag = try app.tags.resolve("journals")
        app.refresh()
        let tabs = PadWorkspaceModel(environment: app)
        let first = tabs.activeID
        try await tabs.navigate(.library(.allDocuments), folderID: folder.id)
        try await tabs.navigate(.library(.tags), tags: [tag.id])
        let path = tabs.activeTab.history
        try await tabs.newTab()
        try await tabs.navigate(.collections)
        try await tabs.selectTab(first)
        #expect(tabs.activeTab.history == path && app.selectedTagIDs == [tag.id])
        try await tabs.travel(-1)
        #expect(app.selectedFolderID == folder.id && app.selectedTagIDs.isEmpty)
        try await tabs.travel(1)
        #expect(app.selectedDestination == .tags && app.selectedTagIDs == [tag.id])
        #expect(tabs.title(for: tabs.activeTab) == "#journals")
    }

    @Test func switchingAndClosingTabsSavePendingTextWithoutReplacingEditorModels() async throws {
        let app = try environment()
        let page = try app.documents.create(DocumentDraft(title: "Keep edits", appearanceJSON: DocumentAppearance.plain.encodedJSON()))
        let model = app.editorCache.prepare(page)
        app.selectedDocumentID = page.id
        let tabs = PadWorkspaceModel(environment: app)
        let first = tabs.activeID
        model.session.onEvent?(.documentChanged(TipTapContentAnalyzer.starterDocument(title: "", lines: ["Pending tab text"])))
        try await tabs.newTab()
        #expect(try app.documents.requireDocument(id: page.id).tipTapJSON.contains("Pending tab text"))
        #expect(app.editorCache.model(for: page.id) === model)
        #expect(try app.documents.requireDocument(id: page.id).appearanceJSON == page.appearanceJSON)
        try await tabs.selectTab(first)
        #expect(tabs.activeTab.location.documentID == page.id && app.editorCache.model(for: page.id) === model)
        model.session.onEvent?(.documentChanged(TipTapContentAnalyzer.starterDocument(title: "", lines: ["Save on close too"])))
        try await tabs.closeTab(first)
        #expect(try app.documents.requireDocument(id: page.id).tipTapJSON.contains("Save on close too"))
    }

    @Test func failedSaveDoesNotChangeTabsOrDiscardTheCurrentEditor() async throws {
        let app = try environment(), tabs = PadWorkspaceModel(environment: app)
        let page = try app.documents.create(DocumentDraft(title: "Unsaved"))
        let model = app.editorCache.prepare(page)
        let original = tabs.activeID
        model.prepareForSpaceChange = { throw VellixError.database("Test save failure") }
        await #expect(throws: VellixError.self) { try await tabs.newTab() }
        await #expect(throws: VellixError.self) { try await tabs.closeTab(original) }
        #expect(tabs.tabs.count == 1 && tabs.activeID == original && !tabs.isBusy)
        #expect(app.editorCache.model(for: page.id) === model && !app.isSwitchingSpace)
        model.prepareForSpaceChange = nil
    }

    @Test func duplicateDocumentOpenSelectsItsExistingTabInsteadOfReplacingAnother() async throws {
        let app = try environment(), tabs = PadWorkspaceModel(environment: app)
        let page = try app.documents.create(DocumentDraft(title: "Open once"))
        try await tabs.openDocument(page, newTab: true)
        let documentTab = tabs.activeID
        try await tabs.newTab()
        try await tabs.openDocument(page, newTab: true)
        #expect(tabs.activeID == documentTab && tabs.tabs.count == 3)
        #expect(tabs.tabs.filter { $0.location.documentID == page.id }.count == 1)
    }

    @Test func foreignAccountDocumentsAndFoldersCannotEnterATab() async throws {
        let root = try AppDatabase.makeInMemory(), libraries = LibraryRepository(database: root)
        let a = try libraries.accountLibrary(ownerKey: "apple:pad-a")
        let b = try libraries.accountLibrary(ownerKey: "apple:pad-b")
        let other = root.scoped(to: b.id)
        let page = try DocumentRepository(database: other).create(DocumentDraft(title: "Private B"))
        let folder = try FolderRepository(database: other).create(title: "B folder")
        let app = try environment(root.scoped(to: a.id)), tabs = PadWorkspaceModel(environment: app)
        await #expect(throws: LibraryError.wrongOwner) { try await tabs.openDocument(page) }
        await #expect(throws: LibraryError.wrongOwner) { try await tabs.newTab(PadWorkspaceLocation(documentID: page.id)) }
        await #expect(throws: LibraryError.wrongOwner) { try await tabs.navigate(.library(.allDocuments), folderID: folder.id) }
        #expect(tabs.tabs.count == 1 && app.selectedDocumentID == nil)
        #expect(try DocumentRepository(database: other).requireDocument(id: page.id).title == "Private B")
    }

    @Test func spaceChangesFlushPendingEditsAndIsolateOldTabs() async throws {
        let app = try environment(), tabs = PadWorkspaceModel(environment: app)
        let page = try app.documents.create(DocumentDraft(title: "First Space"))
        let originalSpace = app.selectedSpaceID
        let model = app.editorCache.prepare(page)
        model.session.onEvent?(.documentChanged(TipTapContentAnalyzer.starterDocument(title: "", lines: ["Keep before Space change"])))
        try await tabs.openDocument(page)
        let oldTab = tabs.activeID
        let other = try app.spaces.create(title: "Other Space")
        try await app.switchSpace(to: other.id)
        tabs.resetForSpaceChange()
        #expect(tabs.tabs.count == 1 && tabs.spaceID == other.id && tabs.activeID != oldTab)
        #expect(tabs.activeTab.location.documentID == nil && app.selectedDocumentID == nil)
        await #expect(throws: LibraryError.wrongOwner) { try await tabs.openDocument(page) }
        try await app.switchSpace(to: originalSpace!)
        #expect(try app.documents.requireDocument(id: page.id).tipTapJSON.contains("Keep before Space change"))
    }

    @Test func oldAccountWorkspaceCannotNavigateAfterItsDatabaseHandleCloses() async throws {
        let root = try AppDatabase.makeInMemory()
        let app = try environment(root.scoped(to: LibraryRecord.localID)), tabs = PadWorkspaceModel(environment: app)
        let page = try app.documents.create(DocumentDraft(title: "Do not lose"))
        try await app.closeLibrary()
        await #expect(throws: LibraryError.staleWorkspace) { try await tabs.newTab() }
        #expect(tabs.tabs.count == 1)
        #expect(try DocumentRepository(database: root).requireDocument(id: page.id).title == "Do not lose")
    }

    @Test func accountChangesRejectAnOldCoordinatorEvenWhenTheLocalDatabaseIsShared() async throws {
        let app = try environment(), tabs = PadWorkspaceModel(environment: app)
        var activeOwner: String? = "apple:first"
        tabs.bindAccount(activeOwner) { activeOwner }
        let original = tabs.activeID
        activeOwner = "email:second"
        await #expect(throws: LibraryError.wrongOwner) { try await tabs.newTab() }
        #expect(tabs.activeID == original && tabs.tabs.count == 1)
    }

    @Test func settingsRemainSelectedAcrossTabsAndSpaceChanges() async throws {
        let app = try environment(), tabs = PadWorkspaceModel(environment: app)
        try await tabs.navigate(.settings)
        let settings = tabs.activeID
        try await tabs.newTab()
        #expect(!app.isSettingsPresented)
        try await tabs.selectTab(settings)
        #expect(app.isSettingsPresented && tabs.activeTab.location.destination == .settings)
        let other = try app.spaces.create(title: "New settings context")
        try await app.switchSpace(to: other.id)
        tabs.resetForSpaceChange()
        #expect(app.isSettingsPresented && tabs.activeTab.location.destination == .settings && tabs.tabs.count == 1)
    }

    @Test func externalFolderNavigationIsCapturedWithoutDuplicatingUnchangedHistory() throws {
        let app = try environment(), tabs = PadWorkspaceModel(environment: app)
        tabs.start()
        let folder = try app.folders.create(title: "External navigation")
        app.refresh(); app.openFolder(folder.id); tabs.capture()
        #expect(tabs.activeTab.location.folderID == folder.id)
        let history = tabs.activeTab.history
        tabs.capture()
        #expect(tabs.activeTab.history == history)
    }

    @Test func trashedDocumentsArePrunedWithoutDeletingTheirStoredContent() async throws {
        let app = try environment(), tabs = PadWorkspaceModel(environment: app)
        let page = try app.documents.create(DocumentDraft(title: "Trash recoverable"))
        try await tabs.openDocument(page)
        _ = try app.documents.trash(id: page.id)
        app.refresh(); tabs.reconcile()
        #expect(tabs.activeTab.location.documentID == nil)
        #expect(try app.documents.requireDocument(id: page.id).isTrashed)
    }

    @Test func ordinaryDocumentOpensAndBackNavigationNeverCreateTabs() async throws {
        let app = try environment(), tabs = PadWorkspaceModel(environment: app)
        let page = try app.documents.create(DocumentDraft(title: "Stay in this tab"))
        tabs.start()
        let original = tabs.activeID
        for _ in 0..<5 {
            try await tabs.openDocument(page)
            tabs.capture()
            #expect(tabs.activeID == original && tabs.tabs.count == 1)
            #expect(tabs.activeTab.location.documentID == page.id)
            try await tabs.travel(-1)
            tabs.capture()
            #expect(tabs.activeTab.location.documentID == nil && tabs.tabs.count == 1)
        }
        try await tabs.newTab()
        #expect(tabs.tabs.count == 2)
    }

    @Test func galleryCropsOnlyTheBottomFifthAtTheSamePixelScale() throws {
        let app = try environment()
        let page = try app.documents.create(DocumentDraft(title: "Crop fixture"))
        let context = try #require(CGContext(data: nil, width: 360, height: 740, bitsPerComponent: 8,
            bytesPerRow: 360 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<740 {
            context.setFillColor(CGColor(red: CGFloat(y) / 740, green: 0.3, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: 360, height: 1))
        }
        let snapshot = try #require(context.makeImage())
        _ = app.documentPreviews.presentationImage(for: page) { snapshot }
        func render(_ fraction: CGFloat, width: CGFloat = 194) throws -> CGImage {
            let renderer = ImageRenderer(content: LibraryDocumentPreview(document: page, visibleHeightFraction: fraction)
                .environmentObject(app).frame(width: width))
            renderer.scale = 2
            return try #require(renderer.cgImage)
        }
        let original = try render(1), cropped = try render(0.8)
        #expect(original.width == cropped.width && cropped.width == 388)
        #expect(abs(CGFloat(cropped.height) / CGFloat(original.height) - 0.8) < 0.002)
        let enlarged = try render(PadWorkspaceMetrics.galleryPreviewHeightFraction,
                                  width: PadWorkspaceMetrics.galleryPreferredCardWidth)
        #expect(abs(CGFloat(enlarged.width) / CGFloat(cropped.width) - 1.1 * 1.05) < 0.003)
        #expect(abs(CGFloat(enlarged.height) / CGFloat(cropped.height) - 1.05) < 0.003)
        let originalBytes = try #require(original.dataProvider?.data) as Data
        let croppedBytes = try #require(cropped.dataProvider?.data) as Data
        #expect(original.bitsPerPixel == cropped.bitsPerPixel)
        for y in stride(from: 40, to: cropped.height - 40, by: 40) {
            let x = original.width / 2, bytes = original.bitsPerPixel / 8
            let a = y * original.bytesPerRow + x * bytes, b = y * cropped.bytesPerRow + x * bytes
            #expect(Array(originalBytes[a..<(a + bytes)]) == Array(croppedBytes[b..<(b + bytes)]))
        }
    }

    @Test func startupSnapshotsCannotReplaceSavedDocumentContent() async throws {
        let app = try environment()
        let saved = TipTapContentAnalyzer.starterDocument(title: "", lines: ["Never replace this saved body"])
        let page = try app.documents.create(DocumentDraft(title: "Saved body", tipTapJSON: saved))
        let model = app.editorCache.prepare(page)
        let empty: [String: Any] = ["document": ["type": "doc", "content": [["type": "paragraph"]]]]
        for kind in ["update", "snapshot", "tableSnapshot", "taskSnapshot"] {
            model.session.handleRawMessage(["kind": kind, "payload": empty])
        }
        #expect(try await model.session.currentJSON() == nil)
        try model.saveCurrentContent()
        #expect(try app.documents.requireDocument(id: page.id).tipTapJSON.contains("Never replace this saved body"))
    }

    @Test func modelRecoveryUsesPendingTextNotAnOlderDatabaseSnapshot() throws {
        let app = try environment()
        let page = try app.documents.create(DocumentDraft(title: "Recover latest"))
        let model = app.editorCache.prepare(page)
        let pending = TipTapContentAnalyzer.starterDocument(title: "", lines: ["Not yet written when WebKit exits"])
        model.session.onEvent?(.documentChanged(pending))
        let recovery = try #require(model.session.documentForRecovery?())
        #expect(recovery.id == page.id && recovery.json == pending)
        model.session.markNavigationStarted()
        #expect(!model.session.isReady && !model.session.isPresentationReady && model.session.isLoadingDocument)
        try model.saveCurrentContent()
        #expect(try app.documents.requireDocument(id: page.id).tipTapJSON.contains("Not yet written when WebKit exits"))
    }

    @Test func actualTipTapLoadsSavedBodyAndRecoversTheSameWebViewAfterProcessExit() async throws {
        let original = try TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "paragraph", "attrs": ["id": "saved-block"],
            "content": [["type": "text", "text": "Existing saved rich text", "marks": [["type": "bold"]]]]]])
        let fixture = try NativeEditorFixture(documentID: "recovery-fixture", json: original)
        defer { fixture.close() }
        try await fixture.waitUntilLoaded()
        let loadedJSON = try await fixture.session.currentJSON()
        let loadedBody = try await fixture.webView.evaluateJavaScript("document.querySelector('.tiptap-editor').textContent") as? String
        #expect(loadedJSON?.contains("Existing saved rich text") == true, "Loaded JSON: \(loadedJSON ?? "nil")")
        #expect(loadedJSON?.contains("\"type\":\"bold\"") == true && loadedJSON?.contains("saved-block") == true)
        #expect(loadedBody == "Existing saved rich text", "Loaded body: \(loadedBody ?? "nil")")
        #expect(try await fixture.webView.evaluateJavaScript("document.querySelector('.tiptap-editor strong').textContent") as? String == "Existing saved rich text")
        let pending = TipTapContentAnalyzer.starterDocument(title: "", lines: ["Latest unsaved recovery text"])
        fixture.session.setEditable(false)
        fixture.session.documentForRecovery = { ("recovery-fixture", pending) }
        let webViewID = ObjectIdentifier(fixture.webView)
        fixture.coordinator.webViewWebContentProcessDidTerminate(fixture.webView)
        #expect(!fixture.session.isReady && !fixture.session.isPresentationReady)
        // A SwiftUI update still carrying the saved row must not replace the recovery payload.
        fixture.session.load(documentID: "recovery-fixture", canonicalJSON: original)
        try await fixture.waitUntilLoaded()
        #expect(ObjectIdentifier(fixture.webView) == webViewID && fixture.loads == 2)
        #expect(try await fixture.session.currentJSON()?.contains("Latest unsaved recovery text") == true)
        #expect(try await fixture.webView.evaluateJavaScript("document.querySelector('.tiptap-editor').textContent") as? String == "Latest unsaved recovery text")
        #expect(try await fixture.webView.evaluateJavaScript("document.querySelector('.tiptap-editor').isContentEditable") as? Bool == false)
    }

    @Test func outgoingWebViewHostCannotReclaimOrDetachItsReplacement() {
        let session = TipTapEditorSession()
        let store = TipTapEditorWebViewStore(session: session, loadEditor: { _, _ in })
        defer { store.coordinator.cleanUp(store.webView) }
        let outgoing = TipTapWebViewContainer(), replacement = TipTapWebViewContainer()
        store.claimHost(outgoing)
        #expect(store.ownsHost(outgoing) && store.webView.superview === outgoing)
        store.claimHost(replacement)
        #expect(store.ownsHost(replacement) && !store.ownsHost(outgoing))

        // Replay the device trace: replacement mounts, old host updates, then old host dismantles.
        outgoing.host(store.webView)
        outgoing.unhost()
        #expect(store.webView.superview === replacement && store.ownsHost(replacement))
        replacement.host(store.webView)
        #expect(store.webView.superview === replacement)

        replacement.unhost()
        #expect(store.webView.superview == nil && !store.ownsHost(replacement))
        outgoing.host(store.webView)
        replacement.host(store.webView)
        #expect(store.webView.superview == nil)

        let reopened = TipTapWebViewContainer()
        store.claimHost(reopened)
        replacement.unhost()
        #expect(store.webView.superview === reopened && store.ownsHost(reopened))
        reopened.unhost()
    }

    @Test func webViewHostHandoffPreservesLiveRichTextAndDoesNotReload() async throws {
        let saved = TipTapContentAnalyzer.starterDocument(title: "", lines: ["Saved body"])
        let fixture = try NativeEditorFixture(documentID: "host-handoff", json: saved)
        defer { fixture.close() }
        try await fixture.waitUntilLoaded()
        let pending = TipTapContentAnalyzer.starterDocument(title: "", lines: ["Live text not yet saved to a document repository"])
        let command = TipTapEditorCommand.loadDocument(canonicalJSON: pending)
        _ = try await fixture.webView.callAsyncJavaScript("await window.tiptapCommand(name, args)",
            arguments: ["name": command.name, "args": command.args], in: nil, contentWorld: .page)
        let before = try await fixture.session.currentJSON()
        let originalWebView = fixture.webView, loads = fixture.loads
        let outgoing = TipTapWebViewContainer(), replacement = TipTapWebViewContainer()
        fixture.store.claimHost(outgoing)
        fixture.store.claimHost(replacement)
        outgoing.host(fixture.webView)
        outgoing.unhost()
        #expect(fixture.webView === originalWebView && fixture.webView.superview === replacement)
        #expect(fixture.loads == loads)
        #expect(try await fixture.session.currentJSON() == before)
        #expect(before?.contains("Live text not yet saved") == true)
        replacement.unhost()
    }

    @Test func reloadingOneRetainedEditorDoesNotBlankAnotherEditor() async throws {
        let a = try NativeEditorFixture(documentID: "a", json: TipTapContentAnalyzer.starterDocument(title: "", lines: ["Tab A body"]))
        let b = try NativeEditorFixture(documentID: "b", json: TipTapContentAnalyzer.starterDocument(title: "", lines: ["Tab B body"]))
        defer { a.close(); b.close() }
        try await a.waitUntilLoaded(); try await b.waitUntilLoaded()
        a.coordinator.webViewWebContentProcessDidTerminate(a.webView)
        try await a.waitUntilLoaded()
        #expect(try await a.session.currentJSON()?.contains("Tab A body") == true)
        let jsonB = try await b.session.currentJSON()
        #expect(jsonB?.contains("Tab B body") == true, "Tab B JSON: \(jsonB ?? "nil")")
        #expect(a.loads == 2 && b.loads == 1)
    }

    @Test func loadingWaitsForTheAsyncJavaScriptCommandBeforeAllowingContentCapture() async throws {
        let fixture = try NativeEditorFixture(documentID: "await-load", json: TipTapContentAnalyzer.starterDocument(title: "", lines: ["Original body"]))
        defer { fixture.close() }
        try await fixture.waitUntilLoaded()
        _ = try await fixture.webView.callAsyncJavaScript("""
            const command = window.tiptapCommand;
            window.tiptapCommand = async function(name, args) {
                if (name === 'setContent') {
                    await new Promise(resolve => { window.resumeDocumentLoad = resolve; });
                }
                return await command(name, args);
            };
            """, arguments: [:], in: nil, contentWorld: .page)
        let replacement = TipTapContentAnalyzer.starterDocument(title: "", lines: ["Fully loaded replacement"])
        fixture.session.load(documentID: "await-load", canonicalJSON: replacement, force: true)
        let deadline = Date().addingTimeInterval(10)
        while try await fixture.webView.evaluateJavaScript("typeof window.resumeDocumentLoad === 'function'") as? Bool != true {
            if Date() > deadline { throw VellixError.editorBridge("The test load command never reached its gate.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.session.isLoadingDocument)
        #expect(try await fixture.session.currentJSON() == nil)
        _ = try await fixture.webView.evaluateJavaScript("window.resumeDocumentLoad();")
        try await fixture.waitUntilLoaded()
        let json = try await fixture.session.currentJSON()
        #expect(json?.contains("Fully loaded replacement") == true)
    }

    #if os(macOS)
    @Test(arguments: [false, true]) func diagnosticHostedEditorMustPaintSavedBodyWithProductionReadinessEnabled(hiddenUntilReady: Bool) async throws {
        let json = TipTapContentAnalyzer.starterDocument(title: "", lines: ["VISIBLE SAVED DOCUMENT BODY", "Second diagnostic paragraph"])
        let fixture = try NativeEditorFixture(documentID: "paint-diagnostic", json: json, interactive: true)
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 820, height: 1100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: DiagnosticEditorSurface(session: fixture.session, store: fixture.store, json: json, hiddenUntilReady: hiddenUntilReady))
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; fixture.close() }
        let deadline = Date().addingTimeInterval(15)
        while !fixture.session.isPresentationReady {
            if Date() > deadline {
                let dom = try await fixture.webView.evaluateJavaScript("JSON.stringify({text:document.querySelector('.tiptap-editor')?.textContent,fonts:document.fonts.status,images:[...document.images].map(x=>({src:x.src,complete:x.complete})),visibility:document.visibilityState,frames:window.diagnosticFrames})")
                throw VellixError.editorBridge("Paint readiness timed out: hidden=\(hiddenUntilReady) ready=\(fixture.session.isReady) loading=\(fixture.session.isLoadingDocument) bounds=\(fixture.webView.bounds) state=\(fixture.session.presentationDiagnostics) DOM=\(dom ?? "nil") error=\(fixture.session.bridgeErrorMessage ?? "none")")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let body = try await fixture.webView.evaluateJavaScript("document.querySelector('.tiptap-editor').textContent") as? String
        #expect(body?.contains("VISIBLE SAVED DOCUMENT BODY") == true)
        let snapshot = try await fixture.webView.takeSnapshot(configuration: nil)
        let image = try #require(snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let painted = (0..<(image.width * image.height)).filter { bytes[$0 * 4 + 3] > 0 && bytes[$0 * 4] > 80 && bytes[$0 * 4 + 1] > 80 }.count
        #expect(painted > 100, "Loaded DOM but no painted text: pixels=\(painted), bounds=\(fixture.webView.bounds)")
    }
    #endif
}

#if os(macOS)
@MainActor private struct DiagnosticEditorSurface: View {
    @ObservedObject var session: TipTapEditorSession
    let store: TipTapEditorWebViewStore
    let json: String
    let hiddenUntilReady: Bool
    var body: some View {
        ScrollView {
            VStack {
                Color.gray.frame(height: 350)
                TipTapWebView(session: session, store: store, documentID: "paint-diagnostic", canonicalJSON: json)
                    .frame(height: max(320, session.editorContentHeight))
                    .opacity(!hiddenUntilReady || session.isPresentationReady ? 1 : 0)
            }.frame(width: 680)
        }.frame(width: 820, height: 1100).background(Color.black)
    }
}
#endif

@MainActor
private final class NativeEditorFixture {
    let session = TipTapEditorSession()
    let store: TipTapEditorWebViewStore
    var coordinator: Coordinator { store.coordinator }
    var webView: WKWebView { store.webView }
    private let loadCount: () -> Int
    var loads: Int { loadCount() }

    init(documentID: String, json: String, interactive: Bool = false) throws {
        let directory = ProcessInfo.processInfo.environment["PENNED_EDITOR_ASSET_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "VellixEditor", withExtension: "bundle")
        let assets = try #require(directory)
        let document = try TipTapEditorAssetCache.document(in: assets)
        #expect(!document.html.contains("<script src=\"./"))
        let editorHTML = document.html + """
            <script>
            window.diagnosticFrames = {requested: 0, delivered: 0};
            const originalFrame = window.requestAnimationFrame.bind(window);
            window.requestAnimationFrame = callback => {
                window.diagnosticFrames.requested += 1;
                return originalFrame(timestamp => { window.diagnosticFrames.delivered += 1; callback(timestamp); });
            };
            const originalCommand = window.tiptapCommand;
            window.tiptapCommand = async function(...args) {
                try { return await originalCommand(...args); }
                catch (error) { window.lastCommandError = String(error) + '\\n' + String(error.stack || ''); throw error; }
            };
            </script>
            """
        var count = 0
        loadCount = { count }
        store = TipTapEditorWebViewStore(session: session, loadEditor: { webView, _ in
            count += 1
            webView.loadHTMLString(editorHTML, baseURL: assets)
        })
        webView.frame = CGRect(x: 0, y: 0, width: 680, height: 500)
        session.preparesInteractivePresentation = interactive
        session.attach(webView: webView)
        session.load(documentID: documentID, canonicalJSON: json)
    }

    func waitUntilLoaded() async throws {
        let deadline = Date().addingTimeInterval(15)
        while !session.isReady || session.isLoadingDocument {
            if Date() > deadline { throw VellixError.editorBridge("Timed out loading the real TipTap fixture: \(session.bridgeErrorMessage ?? "no bridge error")") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let commandError = try await webView.evaluateJavaScript("window.lastCommandError || ''") as? String
        #expect(session.bridgeErrorMessage == nil, "\(commandError ?? "No JavaScript error details")")
    }

    func close() { webView.stopLoading(); coordinator.cleanUp(webView) }
}
