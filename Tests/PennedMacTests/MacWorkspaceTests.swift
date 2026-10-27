import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Vellix

@Suite @MainActor struct MacWorkspaceTests {
    private func fixture(_ root: AppDatabase? = nil, owner: String? = nil, scene: String = UUID().uuidString,
                         preferences: UserDefaults? = nil) throws -> (AppEnvironment, MacWorkspaceModel) {
        let preferences = preferences ?? UserDefaults(suiteName: "PennedMacTests." + UUID().uuidString)!
        let environment = AppEnvironment(database: try root ?? AppDatabase.makeInMemory(),
            attachmentStore: AttachmentStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), preferences: preferences)
        try environment.bootstrap()
        return (environment, MacWorkspaceModel(environment: environment, ownerKey: owner, sceneID: scene,
            preferences: preferences, currentOwner: { owner }))
    }

    @Test func startsWithOneTabAndDoesNotAddTabsDuringRefresh() throws {
        let (app, workspace) = try fixture()
        let id = workspace.activeID
        for _ in 0..<5 { workspace.start(); app.refresh(); workspace.acceptEnvironmentNavigation(); workspace.reconcile() }
        #expect(workspace.tabs.count == 1 && workspace.activeID == id)
    }

    @Test func tabsCreateSwitchCloseAndRetainOneUsableDestination() async throws {
        let (_, workspace) = try fixture()
        let first = workspace.activeID
        try await workspace.newTab(.init(destination: .tasks))
        let second = workspace.activeID
        #expect(workspace.tabs.count == 2)
        try await workspace.selectTab(first)
        #expect(workspace.activeTab.location.destination == .allDocuments)
        try await workspace.selectTab(second)
        #expect(workspace.activeTab.location.destination == .tasks)
        try await workspace.closeTab(second)
        try await workspace.closeTab(first)
        #expect(workspace.tabs.count == 1 && workspace.activeTab.location == MacWorkspaceLocation())
    }

    @Test func tabsRetainIndependentBrowserAndHistoryState() async throws {
        let (app, workspace) = try fixture()
        let folder = try app.folders.create(title: "Projects")
        let tag = try app.tags.resolve("writing")
        app.refresh()
        let first = workspace.activeID
        try await workspace.navigate(.allDocuments, folderID: folder.id)
        workspace.activeTab.browser.query = "Draft"
        workspace.activeTab.browser.sort = .title
        workspace.activeTab.browser.showsList = true
        try await workspace.navigate(.tags, tags: [tag.id])
        let history = workspace.activeTab.history
        try await workspace.newTab(.init(destination: .calendar))
        try await workspace.selectTab(first)
        #expect(workspace.activeTab.history == history)
        #expect(workspace.activeTab.browser.query == "Draft" && workspace.activeTab.browser.sort == .title)
        #expect(workspace.activeTab.browser.showsList)
        try await workspace.travel(-1)
        #expect(app.selectedFolderID == folder.id)
        try await workspace.travel(1)
        #expect(app.selectedTagIDs == [tag.id])
    }

    @Test func openingADocumentTwiceSelectsItsExistingTab() async throws {
        let (app, workspace) = try fixture()
        let page = try app.documents.create(DocumentDraft(title: "Once"))
        try await workspace.open(page, newTab: true)
        let id = workspace.activeID
        try await workspace.newTab()
        try await workspace.open(page, newTab: true)
        #expect(workspace.activeID == id && workspace.tabs.count == 3)
        #expect(workspace.tabs.filter { $0.location.documentID == page.id }.count == 1)
    }

    @Test func navigatingDocumentsAndHistoryNeverCreatesTabs() async throws {
        let (app, workspace) = try fixture()
        let first = try app.documents.create(DocumentDraft(title: "First"))
        let second = try app.documents.create(DocumentDraft(title: "Second"))
        try await workspace.open(first)
        try await workspace.open(second)
        try await workspace.travel(-1)
        try await workspace.travel(1)
        #expect(workspace.tabs.count == 1)
    }

    @Test(arguments: ["page", "card", "collection"])
    func directlyOpenedChildPagesReturnToTheirParentAndForwardToTheSameEditor(_ kind: String) async throws {
        let (app, workspace) = try fixture()
        let parent = try app.documents.create(DocumentDraft(title: "Parent"))
        let child: DocumentRecord
        if kind == "collection" {
            let collection = try app.collections.repository.create(ownerID: parent.id, name: "Entries", viewName: "Main", kind: .gallery)
            child = try app.collections.repository.addEntry(collectionID: collection.record.id, title: "Entry")
        } else {
            child = try app.documents.create(DocumentDraft(title: "Child", parentDocumentID: parent.id,
                cardStyleJSON: kind == "card" ? PageCardStyle().encodedJSON() : nil))
        }
        try await workspace.open(child, newTab: true)
        let tabID = workspace.activeID
        let editor = try #require(workspace.activeEditor)
        editor.session.onEvent?(.documentChanged(TipTapContentAnalyzer.starterDocument(title: "", lines: ["Keep pending edits"])))
        #expect(workspace.canGoBack)
        try await workspace.travel(-1)
        #expect(workspace.activeID == tabID && workspace.activeTab.location.documentID == parent.id)
        #expect(workspace.canGoForward)
        #expect(try app.documents.requireDocument(id: child.id).plainText.contains("Keep pending edits"))
        try await workspace.travel(1)
        #expect(workspace.activeTab.location.documentID == child.id && workspace.activeEditor === editor)
        #expect(!workspace.canGoForward)
    }

    @Test func nestedBackReachesTheParentBeforeTheBrowserAndKeepsExistingTabs() async throws {
        let (app, workspace) = try fixture()
        let parent = try app.documents.create(DocumentDraft(title: "Parent"))
        let child = try app.documents.create(DocumentDraft(title: "Child", parentDocumentID: parent.id))
        try await workspace.open(parent, newTab: true)
        try await workspace.newTab()
        try await workspace.open(child)
        let count = workspace.tabs.count
        try await workspace.open(parent)
        try await workspace.open(child)
        try await workspace.travel(-1)
        #expect(workspace.activeTab.location.documentID == parent.id && workspace.tabs.count == count)
        try await workspace.travel(-1)
        #expect(workspace.activeTab.location.documentID == nil)
        try await workspace.travel(1)
        #expect(workspace.activeTab.location.documentID == parent.id)
        try await workspace.travel(1)
        #expect(workspace.activeTab.location.documentID == child.id)
    }

    @Test func failedSaveDoesNotInsertAParentOrMoveTheNavigationCursor() async throws {
        let (app, workspace) = try fixture()
        let parent = try app.documents.create(DocumentDraft(title: "Parent"))
        let child = try app.documents.create(DocumentDraft(title: "Child", parentDocumentID: parent.id))
        try await workspace.open(child, newTab: true)
        let editor = try #require(workspace.activeEditor)
        let history = workspace.activeTab.history
        let index = workspace.activeTab.historyIndex
        editor.prepareForSpaceChange = { throw VellixError.database("Intentional save failure") }
        await #expect(throws: VellixError.self) { try await workspace.travel(-1) }
        #expect(workspace.activeTab.location.documentID == child.id)
        #expect(workspace.activeTab.history == history && workspace.activeTab.historyIndex == index)
        editor.prepareForSpaceChange = nil
    }

    @Test func tabReorderingKeepsIdentityAndActiveSelection() async throws {
        let (_, workspace) = try fixture()
        let first = workspace.activeID
        try await workspace.newTab(.init(destination: .tasks))
        let second = workspace.activeID
        workspace.moveTab(second, before: first)
        #expect(workspace.tabs.map(\.id) == [second, first] && workspace.activeID == second)
    }

    @Test func switchingTabsSavesPendingJSONWithoutReplacingTheEditor() async throws {
        let (app, workspace) = try fixture()
        let page = try app.documents.create(DocumentDraft(title: "Keep", appearanceJSON: DocumentAppearance.plain.encodedJSON()))
        try await workspace.open(page)
        let editor = try #require(workspace.activeEditor)
        editor.session.onEvent?(.documentChanged(TipTapContentAnalyzer.starterDocument(title: "", lines: ["Unsaved Mac edit"])))
        let first = workspace.activeID
        try await workspace.newTab()
        #expect(try app.documents.requireDocument(id: page.id).tipTapJSON.contains("Unsaved Mac edit"))
        try await workspace.selectTab(first)
        #expect(workspace.activeEditor === editor)
        #expect(try app.documents.requireDocument(id: page.id).appearanceJSON == page.appearanceJSON)
    }

    @Test func failedSavePreventsTabClosureOrSwitching() async throws {
        let (app, workspace) = try fixture()
        let page = try app.documents.create(DocumentDraft(title: "Pending"))
        try await workspace.open(page)
        let editor = try #require(workspace.activeEditor), first = workspace.activeID
        editor.prepareForSpaceChange = { throw VellixError.database("Intentional save failure") }
        await #expect(throws: VellixError.self) { try await workspace.newTab() }
        await #expect(throws: VellixError.self) { try await workspace.closeTab(first) }
        #expect(workspace.activeID == first && workspace.tabs.count == 1 && workspace.activeEditor === editor)
        editor.prepareForSpaceChange = nil
    }

    @Test func accountBoundariesRejectForeignDocumentsAndFolders() async throws {
        let root = try AppDatabase.makeInMemory(), libraries = LibraryRepository(database: root)
        let a = try libraries.accountLibrary(ownerKey: "apple:mac-a"), b = try libraries.accountLibrary(ownerKey: "apple:mac-b")
        let foreign = root.scoped(to: b.id)
        let page = try DocumentRepository(database: foreign).create(DocumentDraft(title: "Private"))
        let folder = try FolderRepository(database: foreign).create(title: "Private Folder")
        let (_, workspace) = try fixture(root.scoped(to: a.id), owner: "apple:mac-a")
        await #expect(throws: LibraryError.wrongOwner) { try await workspace.open(page) }
        await #expect(throws: LibraryError.wrongOwner) { try await workspace.newTab(.init(documentID: page.id)) }
        await #expect(throws: LibraryError.wrongOwner) { try await workspace.navigate(.folders, folderID: folder.id) }
        #expect(workspace.tabs.count == 1)
        #expect(try DocumentRepository(database: foreign).requireDocument(id: page.id).title == "Private")
    }

    @Test func changedAccountCannotReuseAnOldWorkspaceEvenForLocalLibrary() async throws {
        let (app, _) = try fixture()
        var owner: String? = "apple:old"
        let workspace = MacWorkspaceModel(environment: app, ownerKey: owner, sceneID: UUID().uuidString, currentOwner: { owner })
        owner = "apple:new"
        await #expect(throws: LibraryError.wrongOwner) { try await workspace.newTab() }
        #expect(workspace.tabs.count == 1)
    }

    @Test func restorationIsScopedByAccountWindowAndSpace() async throws {
        let preferences = UserDefaults(suiteName: "PennedMacTests." + UUID().uuidString)!
        let (app, workspace) = try fixture(scene: "main", preferences: preferences)
        try await workspace.newTab(.init(destination: .tasks))
        workspace.activeTab.browser.query = "saved query"; workspace.saveTabs()
        let restored = MacWorkspaceModel(environment: app, ownerKey: nil, sceneID: "main", preferences: preferences)
        #expect(restored.tabs.count == 2 && restored.activeID == workspace.activeID)
        #expect(restored.activeTab.browser.query == "saved query")
        let other = MacWorkspaceModel(environment: app, ownerKey: nil, sceneID: "another", preferences: preferences)
        #expect(other.tabs.count == 1)
        let foreign = MacWorkspaceModel(environment: app, ownerKey: "apple:other", sceneID: "main", preferences: preferences, currentOwner: { "apple:other" })
        #expect(foreign.tabs.count == 1)
    }

    @Test func switchingSpacesClearsUnrestorableTabsAndSavesEdits() async throws {
        let (app, workspace) = try fixture()
        let page = try app.documents.create(DocumentDraft(title: "First Space"))
        try await workspace.open(page)
        let oldSpace = try #require(app.selectedSpaceID)
        let editor = try #require(workspace.activeEditor)
        editor.session.onEvent?(.documentChanged(TipTapContentAnalyzer.starterDocument(title: "", lines: ["Keep across Spaces"])))
        let second = try app.spaces.create(title: "Second")
        try await workspace.switchSpace(second.id)
        #expect(workspace.spaceID == second.id && workspace.tabs.count == 1 && workspace.activeTab.location.documentID == nil)
        await #expect(throws: LibraryError.wrongOwner) { try await workspace.open(page) }
        try await workspace.switchSpace(oldSpace)
        #expect(try app.documents.requireDocument(id: page.id).tipTapJSON.contains("Keep across Spaces"))
    }

    @Test func sidebarInspectorAndThemeChangesDoNotReplaceEditorOrSaveDocument() async throws {
        let (app, workspace) = try fixture()
        let page = try app.documents.create(DocumentDraft(title: "Stable"))
        try await workspace.open(page)
        let editor = try #require(workspace.activeEditor)
        let original = try app.documents.requireDocument(id: page.id)
        for _ in 0..<3 {
            workspace.sidebarVisible.toggle(); workspace.inspectorVisible.toggle(); workspace.inspector = .format
            editor.session.setApplicationColorScheme(.light); editor.session.setApplicationColorScheme(.dark)
        }
        let after = try app.documents.requireDocument(id: page.id)
        #expect(workspace.activeEditor === editor && original.tipTapJSON == after.tipTapJSON)
        #expect(original.appearanceJSON == after.appearanceJSON && original.revision == after.revision)
    }

    @Test func inspectorIsDocumentOnlyAndRemembersItsVisibilityAcrossBrowsing() async throws {
        let (app, workspace) = try fixture()
        workspace.inspectorVisible = true
        #expect(!workspace.canShowInspector && !workspace.showsInspector)
        let page = try app.documents.create(DocumentDraft(title: "Inspector"))
        let browserTab = workspace.activeID
        try await workspace.open(page, newTab: true)
        let documentTab = workspace.activeID
        let editor = workspace.activeEditor
        #expect(workspace.canShowInspector && workspace.showsInspector)
        try await workspace.selectTab(browserTab)
        #expect(!workspace.canShowInspector && !workspace.showsInspector && workspace.inspectorVisible)
        for destination in MacDestination.allCases {
            try await workspace.navigate(destination)
            #expect(!workspace.canShowInspector && !workspace.showsInspector)
        }
        try await workspace.selectTab(documentTab)
        #expect(workspace.showsInspector && workspace.activeEditor === editor)
        workspace.inspectorVisible = false
        #expect(workspace.canShowInspector && !workspace.showsInspector)
    }

    @Test func macEditorReceivesNonzeroLayoutWithoutAPresetWebViewFrame() async throws {
        let assets = try #require(ProcessInfo.processInfo.environment["PENNED_EDITOR_ASSET_DIRECTORY"])
        let source = try TipTapEditorAssetCache.document(in: URL(fileURLWithPath: assets))
        let session = TipTapEditorSession()
        let store = TipTapEditorWebViewStore(session: session, loadEditor: { webView, _ in
            webView.loadHTMLString(source.html, baseURL: source.baseURL)
        })
        let json = TipTapContentAnalyzer.starterDocument(title: "", lines: ["VISIBLE MAC DOCUMENT BODY"])
        session.load(documentID: "mac-layout", canonicalJSON: json)
        let surface = MacInitialEditorLayout(session: session, store: store, json: json)
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1100, height: 850),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: surface)
        window.orderBack(nil)
        defer {
            window.orderOut(nil); window.contentView = nil
            store.webView.stopLoading(); store.coordinator.cleanUp(store.webView)
        }
        let deadline = Date().addingTimeInterval(15)
        while !session.isPresentationReady {
            if Date() > deadline {
                throw VellixError.editorBridge("Mac initial layout stalled: bounds=\(store.webView.bounds) host=\(String(describing: store.webView.superview?.bounds)) state=\(session.presentationDiagnostics)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.webView.bounds.width > 600)
        #expect(try await store.webView.evaluateJavaScript("document.querySelector('.tiptap-editor').textContent") as? String == "VISIBLE MAC DOCUMENT BODY")
    }

    @Test func successfulColdAndCachedDocumentOpensCancelTheirFailureTimeout() async throws {
        let (app, workspace) = try fixture()
        let json = TipTapContentAnalyzer.starterDocument(title: "", lines: ["KEEP THE EXISTING SAVED BODY"])
        let page = try app.documents.create(DocumentDraft(title: "Complete opening", tipTapJSON: json))
        let assets = try #require(ProcessInfo.processInfo.environment["PENNED_EDITOR_ASSET_DIRECTORY"])
        let source = try TipTapEditorAssetCache.document(in: URL(fileURLWithPath: assets))
        try await workspace.open(page)
        let model = try #require(workspace.activeEditor)
        let store = model.webViewStore
        store.webView.loadHTMLString(source.html, baseURL: source.baseURL)
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1100, height: 850),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MacInitialEditorLayout(session: model.session, store: store, json: json, documentID: page.id))
        window.orderBack(nil)
        defer {
            window.orderOut(nil); window.contentView = nil
            store.webView.stopLoading(); store.coordinator.cleanUp(store.webView)
        }
        let deadline = Date().addingTimeInterval(15)
        while app.selectedDocumentID != page.id {
            guard Date() < deadline else { throw VellixError.editorBridge("Document opening did not complete: \(model.session.presentationDiagnostics)") }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(app.pendingDocumentID == nil)
        app.select(page)
        #expect(app.selectedDocumentID == page.id && app.pendingDocumentID == nil)
        try await Task.sleep(for: .seconds(13))
        #expect(app.errorMessage == nil && model.session.bridgeErrorMessage == nil)
        #expect(workspace.activeEditor === model && store.webView.superview != nil)
        #expect(try app.documents.requireDocument(id: page.id).tipTapJSON == page.tipTapJSON)
        #expect(try await model.session.currentJSON()?.contains("KEEP THE EXISTING SAVED BODY") == true)
    }

    @Test func deletingCollectionPreservesPendingTextAndTheLiveEditor() async throws {
        let (app, workspace) = try fixture()
        var page = try app.documents.create(DocumentDraft(title: "Delete collection safely"))
        let collection = try app.collections.repository.create(ownerID: page.id, name: "Delete me", viewName: "Main", kind: .gallery)
        let entry = try app.collections.repository.addEntry(collectionID: collection.record.id, title: "Retain entry")
        page = try app.documents.saveEditorJSON(id: page.id, canonicalJSON: CollectionRepository.blockJSON(collectionID: collection.record.id, documentID: page.id))
        try await workspace.open(page)
        let model = try #require(workspace.activeEditor), store = model.webViewStore
        let source = try TipTapEditorAssetCache.document(in: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["PENNED_EDITOR_ASSET_DIRECTORY"])))
        store.webView.loadHTMLString(source.html, baseURL: source.baseURL)
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1100, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MacInitialEditorLayout(session: model.session, store: store, json: page.tipTapJSON, documentID: page.id))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; store.webView.stopLoading(); store.coordinator.cleanUp(store.webView) }
        let deadline = Date().addingTimeInterval(15)
        while !model.session.isPresentationReady {
            guard Date() < deadline else { throw VellixError.editorBridge("Collection editor did not become ready") }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await store.webView.evaluateJavaScript("document.querySelector('.tiptap-editor').editor.commands.insertContentAt(0, {type:'paragraph',content:[{type:'text',text:'Pending text survives'}]})")
        try await CollectionDeletion.delete(collection.record.id, in: app)
        #expect(workspace.activeEditor === model && model.webViewStore === store && model.session.isReady)
        let saved = try app.documents.requireDocument(id: page.id)
        #expect(saved.plainText.contains("Pending text survives") && TipTapContentAnalyzer.collectionIDs(in: saved.tipTapJSON).isEmpty)
        #expect(try app.documents.requireDocument(id: entry.id).isTrashed == false)
        #expect(try await model.session.currentJSON()?.contains("Pending text survives") == true)
        _ = try await store.webView.evaluateJavaScript("document.querySelector('.tiptap-editor').editor.commands.undo()")
        let undone = try #require(try await model.session.currentJSON())
        #expect(TipTapContentAnalyzer.collectionIDs(in: undone).isEmpty, "Undo must not resurrect a deleted collection with missing configuration")
    }

    @Test func windowsHaveIndependentStateOverTheSameWriter() async throws {
        let root = try AppDatabase.makeInMemory()
        let (app, first) = try fixture(root.scoped(to: LibraryRecord.localID))
        let (_, second) = try fixture(root.scoped(to: LibraryRecord.localID))
        let registry = MacWindowRegistry(); registry.register(first); registry.register(second)
        try await first.newTab(.init(destination: .tasks))
        #expect(second.tabs.count == 1 && second.activeTab.location.destination == .allDocuments)
        let page = try app.documents.create(DocumentDraft(title: "Shared"))
        second.environment.refresh()
        try await second.open(page)
        #expect(first.tabs.count == 2 && first.activeTab.location.destination == .tasks)
        #expect(registry.focusDocument(page.id, except: first))
        try await first.environment.closeLibrary()
        #expect(second.environment.database.isAccessible)
        #expect(try second.environment.documents.requireDocument(id: page.id).title == "Shared")
    }

    @Test func deletingADocumentPrunesItsTabWithoutRecreatingContent() async throws {
        let (app, workspace) = try fixture()
        let page = try app.documents.create(DocumentDraft(title: "Trash"))
        try await workspace.open(page)
        _ = app.trashDocuments([page.id]); workspace.reconcile()
        #expect(workspace.activeTab.location.documentID == nil && workspace.tabs.count == 1)
        #expect(try app.documents.requireDocument(id: page.id).isTrashed)
    }

    @Test func quickCommandsAreExecutedInOrderWithoutDroppingNavigation() async throws {
        let (_, workspace) = try fixture()
        let first = workspace.activeID
        workspace.perform { try await workspace.newTab(.init(destination: .tasks)) }
        workspace.perform { try await workspace.selectTab(first) }
        await workspace.waitForOperations()
        #expect(workspace.tabs.count == 2 && workspace.activeID == first && workspace.errorMessage == nil)
    }

    @Test func calendarAndTaskFiltersBelongToTheirTabs() async throws {
        let (_, workspace) = try fixture()
        let first = workspace.activeTab
        let firstCalendar = workspace.calendar(for: first)
        let selected = firstCalendar.selectedDate.addingTimeInterval(-86400 * 14)
        firstCalendar.select(selected)
        first.browser.showsCompletedTasks = true
        try await workspace.newTab(.init(destination: .calendar))
        let secondCalendar = workspace.calendar(for: workspace.activeTab)
        #expect(firstCalendar !== secondCalendar && firstCalendar.selectedDate != secondCalendar.selectedDate)
        #expect(!workspace.activeTab.browser.showsCompletedTasks)
        try await workspace.selectTab(first.id)
        #expect(workspace.calendar(for: first) === firstCalendar && first.browser.showsCompletedTasks)
    }

    @Test func documentScrollStateSurvivesHistoryAndTabChanges() async throws {
        let (app, workspace) = try fixture()
        let first = try app.documents.create(DocumentDraft(title: "Scroll A"))
        let second = try app.documents.create(DocumentDraft(title: "Scroll B"))
        let state = workspace.viewState(for: first.id)
        try await workspace.open(first)
        try await workspace.open(second)
        try await workspace.travel(-1)
        #expect(workspace.viewState(for: first.id) === state)
        #expect(workspace.viewState(for: second.id) !== state)
    }

    @Test func customStyleColorInputValidatesAndPreservesExactRGBValues() {
        #expect(MacColorValue.validatedHex(" abc123 ") == "#ABC123")
        #expect(MacColorValue.validatedHex("#123456") == "#123456")
        for invalid in ["#123", "#12345678", "zzzzzz", "#12345g", "#12 3456"] { #expect(MacColorValue.validatedHex(invalid) == nil) }
        #expect(MacColorValue.hex(Color(vellixHex: "#173B96")) == "#173B96")
        #expect(MacColorValue.hex(MacColorValue.color(red: 300, green: -20, blue: 127.6)) == "#FF0080")
        #expect(MacColorValue.hex(MacColorValue.color(red: .nan, green: .infinity, blue: 0)) == "#000000")
    }

    @Test func openingACustomStyleColorControlDoesNotWriteItsSelection() throws {
        var writes = 0
        let selection = Binding<Color>(get: { Color(vellixHex: "#173B96") }, set: { _ in writes += 1 })
        let view = CardThreeModeColorPicker(selection: selection, title: "Text Color", embedded: true).frame(width: 308)
        let renderer = ImageRenderer(content: view)
        #expect(renderer.nsImage != nil)
        #expect(writes == 0)
    }

    @Test func macSettingsRetainEveryCategoryInThePhoneReference() {
        let expected: Set<String> = ["Templates", "Published Content", "Stats", "On-device Folders", "Tags", "Space Settings", "Daily Notes", "Appearance & Sound", "Language & Spelling", "Security", "Advanced", "Account Settings", "My Subscription", "My Spaces", "My Team", "Integrations", "Assistant", "Notifications", "Diagnostics", "About"]
        #expect(expected.isSubset(of: Set(MacSettingsCategory.allCases.map(\.rawValue))))
        #expect(MacSettingsCategory.allCases.filter(\.requiresUnavailableService).count == 4)
        #expect(!MacSettingsCategory.templates.requiresUnavailableService && !MacSettingsCategory.library.requiresUnavailableService)
    }

    @Test func customControlsDoNotCommitBindingsWhileRendering() {
        var writes = 0
        let option = Binding<String>(get: { "a" }, set: { _ in writes += 1 })
        let value = Binding<Double>(get: { 0.4 }, set: { _ in writes += 1 })
        let date = Binding<Date>(get: { Date(timeIntervalSince1970: 1234567890) }, set: { _ in writes += 1 })
        let control = VStack {
            MacOptionPicker("Option", selection: option, options: ["a", "b"], label: { $0 })
            MacSegmentedControl("Mode", selection: option, options: ["a", "b"], label: { $0 })
            MacSlider(value: value, in: 0...1)
            MacDatePicker("Date", selection: date)
        }.frame(width: 360).macApplicationControls()
        #expect(ImageRenderer(content: control).nsImage != nil)
        #expect(writes == 0)
    }

    @Test func nativePageContentAndTheExistingHTMLBodyShareTheSameMaximumWidth() throws {
        let resource = ProcessInfo.processInfo.environment["PENNED_EDITOR_ASSET_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        let html = try String(contentsOf: #require(resource).appendingPathComponent("tiptap.html"), encoding: .utf8)
        #expect(html.contains("max-width: \(Int(MacDocumentLayout.maximumContentWidth))px"))
        #expect(MacDocumentLayout.maximumPageWidth - 2 * MacDocumentLayout.contentInset == MacDocumentLayout.maximumContentWidth)
        for available in [CGFloat(430), 588, 929, 1320, 1800] {
            let content = min(available, MacDocumentLayout.maximumPageWidth) - 2 * MacDocumentLayout.contentInset
            #expect(content <= MacDocumentLayout.maximumContentWidth)
        }
    }
}

@MainActor private struct MacInitialEditorLayout: View {
    @ObservedObject var session: TipTapEditorSession
    let store: TipTapEditorWebViewStore
    let json: String
    var documentID: String = "mac-layout"
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Untitled", text: .constant("Mac layout"), axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 26))
                    Rectangle().frame(height: 1)
                    TipTapWebView(session: session, store: store, documentID: documentID, canonicalJSON: json)
                        .frame(height: max(220, session.editorContentHeight))
                }
                .padding(MacDocumentLayout.contentInset)
                .frame(maxWidth: MacDocumentLayout.maximumPageWidth)
                .padding(.horizontal, max(24, min(56, geometry.size.width * 0.045)))
                .padding(.vertical, 30).frame(maxWidth: .infinity)
            }
        }
    }
}
