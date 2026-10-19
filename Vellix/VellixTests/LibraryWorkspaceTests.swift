import Foundation
import GRDB
import Testing
@testable import Vellix

@Suite @MainActor
struct LibraryWorkspaceTests {
    private func workspace(_ database: AppDatabase, preferences: UserDefaults? = nil) -> LibraryWorkspace {
        LibraryWorkspace(database: database,
            attachmentStore: AttachmentStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            preferences: preferences ?? UserDefaults(suiteName: "Penned.LibraryWorkspaceTests.\(UUID().uuidString)")!)
    }

    @Test func repeatedSignOutAndRestoreDoNotAdoptGeneratedPersonalSpaces() async throws {
        let root = try AppDatabase.makeInMemory(), workspace = workspace(root)
        let account = AccountIdentity.apple("no-generated-personal")
        var active: AccountIdentity? = account
        workspace.currentOwner = { active?.libraryOwnerKey }
        await workspace.activate(account)
        let app = try #require(workspace.environment)
        #expect(app.selectedSpaceID == nil && app.overview.spaces.isEmpty)
        let authored = try app.spaces.create(title: "Writing")
        try await app.switchSpace(to: authored.id)
        for _ in 0..<3 {
            active = nil; await workspace.activate(nil)
            #expect(workspace.environment?.activeSpace?.title == "Personal")
            active = account; await workspace.activate(account)
            #expect(try workspace.environment?.spaces.all().map(\.id) == [authored.id])
        }
        #expect(try SpaceRepository(database: root).all().count == 1)
    }

    @Test func emptyAccountWaitsForIncomingSpacesWithoutPublishingAPersonal() async throws {
        let root = try AppDatabase.makeInMemory(), workspace = workspace(root)
        let account = AccountIdentity.apple("new-sync-device")
        workspace.currentOwner = { account.libraryOwnerKey }
        await workspace.activate(account)
        let app = try #require(workspace.environment)
        #expect(app.selectedSpaceID == nil && app.overview.all.isEmpty)
        try await app.importLibraryChanges { [] }
        #expect(try app.spaces.all().isEmpty && app.selectedSpaceID == nil)
        var remote = SpaceRecord(id: "remote-existing", title: "Existing on iPhone")
        remote.libraryID = app.database.libraryID
        try await app.importLibraryChanges {
            try app.database.write { try remote.insert($0) }
            return []
        }
        #expect(app.selectedSpaceID == remote.id && app.overview.spaces.map(\.id) == [remote.id])
        try await app.importLibraryChanges { [] }
        #expect(try app.spaces.all().map(\.id) == [remote.id])
    }

    @Test func deliberateCreationInEmptyAccountSelectsItsNewSpaceAndKeepsTheDocument() async throws {
        let root = try AppDatabase.makeInMemory(), workspace = workspace(root)
        let account = AccountIdentity.apple("new-account-creation")
        workspace.currentOwner = { account.libraryOwnerKey }
        await workspace.activate(account)
        let app = try #require(workspace.environment)
        let page = try #require(app.createDocument(title: "First page"))
        #expect(page.spaceID == app.selectedSpaceID && app.activeSpace?.title == "Personal")
        await workspace.activate(account, force: true)
        #expect(workspace.environment?.overview.all.map(\.id) == [page.id])
        #expect(try workspace.environment?.spaces.all().count == 1)
    }

    @Test func restoredSignInClaimsLegacySpacesDocumentsTemplatesAndKeepsSelectedSpaceVisible() async throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.vellixMigrator.migrate(queue, upTo: "v19_document_tags")
        let json = TipTapContentAnalyzer.starterDocument(title: "Existing", lines: ["Keep this content"])
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO spaces(id,title,createdAt,updatedAt) VALUES ('legacy-space','Writing',?,?)", arguments: [Date(), Date()])
            try db.execute(sql: "INSERT INTO documents(id,title,tipTapJSON,spaceID,createdAt,updatedAt) VALUES ('legacy-document','Existing',?,'legacy-space',?,?)", arguments: [json, Date(), Date()])
            let template = TemplateRecord(id: "legacy-template", title: "Existing template", templateDescription: "", tipTapJSON: json, category: "Mine", isBuiltIn: false, spaceID: "legacy-space")
            try template.insert(db)
        }
        let root = try AppDatabase(queue, isInMemory: true)
        let preferences = UserDefaults(suiteName: "Penned.LibraryWorkspaceTests.\(UUID().uuidString)")!
        preferences.set("legacy-space", forKey: "penned.activeSpaceID")
        let spacesBefore = try SpaceRepository(database: root).includingArchived()
        let identity = AccountIdentity.apple("restored-apple-account")
        let workspace = workspace(root, preferences: preferences)
        workspace.currentOwner = { identity.libraryOwnerKey }
        await workspace.activate(identity)
        let environment = try #require(workspace.environment)
        let libraryID = LibraryRecord.accountID(ownerKey: identity.libraryOwnerKey)
        #expect(workspace.matches(identity) && !workspace.usesLocalLibrary && !workspace.syncEnabled)
        #expect(environment.selectedSpaceID == "legacy-space")
        let claimedSpaces = try environment.spaces.includingArchived()
        #expect(claimedSpaces.map(\.id) == spacesBefore.map(\.id))
        #expect(claimedSpaces.allSatisfy { $0.libraryID == libraryID })
        #expect(try SpaceRepository(database: root).includingArchived().isEmpty)
        #expect(environment.overview.all.map(\.id) == ["legacy-document"])
        #expect(environment.overview.templates.map(\.id) == ["legacy-template"])
        #expect(try environment.documents.requireDocument(id: "legacy-document").tipTapJSON == json)
        #expect(try workspace.libraries?.library(id: libraryID)?.ownerKey == identity.libraryOwnerKey)
        let relaunched = self.workspace(root, preferences: preferences)
        relaunched.currentOwner = { identity.libraryOwnerKey }
        await relaunched.activate(identity)
        #expect(!relaunched.usesLocalLibrary && relaunched.environment?.selectedSpaceID == "legacy-space")
        #expect(try relaunched.environment?.spaces.includingArchived().map(\.id) == spacesBefore.map(\.id))
        #expect(relaunched.environment?.overview.templates.map(\.id) == ["legacy-template"])
    }

    @Test func anAutomaticallyCreatedEmptyAccountLibraryDoesNotHideLocalContent() async throws {
        let root = try AppDatabase.makeInMemory()
        let local = try DocumentRepository(database: root).create(DocumentDraft(title: "Still local"))
        let identity = AccountIdentity.email(project: "https://example.com", userID: UUID())
        let accountLibrary = try LibraryRepository(database: root).accountLibrary(ownerKey: identity.libraryOwnerKey)
        let accountDatabase = root.scoped(to: accountLibrary.id)
        _ = try accountDatabase.write { try SpaceOwnership.defaultSpace(in: $0) }
        let preferences = UserDefaults(suiteName: "Penned.LibraryWorkspaceTests.\(UUID().uuidString)")!
        let workspace = workspace(root, preferences: preferences)
        workspace.currentOwner = { identity.libraryOwnerKey }
        await workspace.activate(identity)
        #expect(!workspace.usesLocalLibrary)
        #expect(workspace.environment?.overview.all.map(\.id) == [local.id])
        await workspace.activate(identity, local: false)
        let accountPage = try #require(workspace.environment).documents.create(DocumentDraft(title: "Keep account content too"))
        let relaunched = self.workspace(root, preferences: preferences)
        relaunched.currentOwner = { identity.libraryOwnerKey }
        await relaunched.activate(identity)
        #expect(!relaunched.usesLocalLibrary)
        #expect(Set(relaunched.environment?.overview.all.map(\.id) ?? []) == [local.id, accountPage.id])
        #expect(try relaunched.environment?.documents.requireDocument(id: local.id).title == local.title)
        #expect(try DocumentRepository(database: root).document(id: local.id) == nil)
    }

    @Test func signInClaimsLocalContentAndSwitchingNeverReassignsAnotherAccountsDocuments() async throws {
        let root = try AppDatabase.makeInMemory()
        let local = try DocumentRepository(database: root).create(DocumentDraft(title: "Local-only page"))
        let workspace = workspace(root)
        let a = AccountIdentity.apple("account-a"), b = AccountIdentity.email(project: "https://example.com", userID: UUID())
        var active: AccountIdentity? = a
        workspace.currentOwner = { active?.libraryOwnerKey }
        active = nil
        await workspace.activate(nil)
        let localEnvironment = try #require(workspace.environment)
        localEnvironment.editorCache.prepare(local).session.onEvent?(.documentChanged(TipTapContentAnalyzer.starterDocument(title: "", lines: ["Pending local text"])))
        active = a
        await workspace.activate(a)
        let first = try #require(workspace.environment)
        #expect(first.overview.all.map(\.id) == [local.id] && !workspace.usesLocalLibrary && !workspace.syncEnabled)
        #expect(!localEnvironment.database.isAccessible)
        #expect(try first.documents.requireDocument(id: local.id).tipTapJSON.contains("Pending local text"))
        let page = try first.documents.create(DocumentDraft(title: "Account A page"))
        first.editorCache.prepare(page).session.onEvent?(.documentChanged(TipTapContentAnalyzer.starterDocument(title: "", lines: ["Pending A text"])))
        active = b; await workspace.activate(b, local: false)
        #expect(workspace.matches(b))
        #expect(workspace.environment?.overview.all.isEmpty == true)
        #expect(!first.database.isAccessible)
        let aDatabase = root.scoped(to: LibraryRecord.accountID(ownerKey: a.libraryOwnerKey))
        #expect(try DocumentRepository(database: aDatabase).requireDocument(id: page.id).tipTapJSON.contains("Pending A text"))
        active = a; await workspace.activate(a)
        #expect(Set(workspace.environment?.overview.all.map(\.id) ?? []) == [local.id, page.id])
        active = nil; await workspace.activate(nil)
        #expect(workspace.usesLocalLibrary)
        #expect(workspace.environment?.overview.all.isEmpty == true)
        #expect(try DocumentRepository(database: aDatabase).requireDocument(id: local.id).tipTapJSON.contains("Pending local text"))
    }

    @Test func failedLocalSavePreventsOwnershipAssignmentUntilTheSaveSucceeds() async throws {
        let root = try AppDatabase.makeInMemory(), workspace = workspace(root)
        let page = try DocumentRepository(database: root).create(DocumentDraft(title: "Local unsaved page"))
        var active: AccountIdentity?
        workspace.currentOwner = { active?.libraryOwnerKey }
        await workspace.activate(nil)
        let local = try #require(workspace.environment)
        let model = local.editorCache.prepare(page)
        model.prepareForSpaceChange = { throw VellixError.database("Test save failure") }
        let account = AccountIdentity.apple("new-owner")
        active = account
        await workspace.activate(account)
        #expect(!workspace.matches(account) && workspace.errorMessage != nil)
        #expect(local.database.isAccessible)
        #expect(try SpaceRepository(database: root).space(id: page.spaceID!)?.libraryID == LibraryRecord.localID)
        #expect(try workspace.libraries?.library(id: LibraryRecord.accountID(ownerKey: account.libraryOwnerKey)) == nil)
        model.prepareForSpaceChange = nil
        await workspace.activate(account)
        #expect(workspace.matches(account) && !workspace.usesLocalLibrary)
        #expect(try workspace.environment?.documents.requireDocument(id: page.id).id == page.id)
    }

    @Test func ownerChangeDuringLocalSaveCannotAssignContentToTheOldAccount() async throws {
        let root = try AppDatabase.makeInMemory(), workspace = workspace(root)
        let page = try DocumentRepository(database: root).create(DocumentDraft(title: "Keep ownership correct"))
        let a = AccountIdentity.apple("a"), b = AccountIdentity.apple("b")
        var active: AccountIdentity?
        workspace.currentOwner = { active?.libraryOwnerKey }
        await workspace.activate(nil)
        let model = try #require(workspace.environment).editorCache.prepare(page)
        let operation = model.beginPersistentOperation()
        active = a
        let firstSignIn = Task { await workspace.activate(a) }
        await Task.yield()
        active = b
        model.endPersistentOperation(operation)
        await firstSignIn.value
        #expect(!workspace.matches(a))
        #expect(try DocumentRepository(database: root).document(id: page.id) != nil)
        await workspace.activate(b)
        #expect(workspace.matches(b))
        #expect(try workspace.environment?.documents.requireDocument(id: page.id).id == page.id)
        #expect(try workspace.libraries?.library(id: LibraryRecord.accountID(ownerKey: a.libraryOwnerKey)) == nil)
    }

    @Test func explicitLocalOnlyModeDoesNotAssignContentUntilAccountLibraryIsChosen() async throws {
        let root = try AppDatabase.makeInMemory()
        let page = try DocumentRepository(database: root).create(DocumentDraft(title: "Intentionally local"))
        let preferences = UserDefaults(suiteName: "Penned.LibraryWorkspaceTests.\(UUID().uuidString)")!
        let account = AccountIdentity.apple("local-only-choice")
        let workspace = workspace(root, preferences: preferences)
        workspace.currentOwner = { account.libraryOwnerKey }
        await workspace.activate(account, local: true)
        #expect(workspace.usesLocalLibrary)
        #expect(try DocumentRepository(database: root).document(id: page.id) != nil)
        let relaunched = self.workspace(root, preferences: preferences)
        relaunched.currentOwner = { account.libraryOwnerKey }
        await relaunched.activate(account)
        #expect(relaunched.usesLocalLibrary)
        await relaunched.activate(account, local: false)
        #expect(!relaunched.usesLocalLibrary)
        #expect(relaunched.environment?.overview.all.map(\.id) == [page.id])
    }

    @Test func returningToAnAdoptedAccountKeepsItsSelectionWhenTheSignedOutLibraryIsEmpty() async throws {
        let root = try AppDatabase.makeInMemory(), workspace = workspace(root)
        let account = AccountIdentity.apple("already-adopted")
        var active: AccountIdentity? = account
        workspace.currentOwner = { active?.libraryOwnerKey }
        await workspace.activate(account)
        let environment = try #require(workspace.environment)
        let chosen = try environment.spaces.create(title: "My existing account Space")
        try await environment.switchSpace(to: chosen.id)
        let page = try environment.documents.create(DocumentDraft(title: "Already adopted"))
        active = nil
        await workspace.activate(nil)
        #expect(workspace.environment?.overview.all.isEmpty == true)
        active = account
        await workspace.activate(account)
        #expect(workspace.environment?.selectedSpaceID == chosen.id)
        #expect(workspace.environment?.overview.all.map(\.id) == [page.id])
    }

    @Test func optionalSelectiveAdoptionDoesNotImplicitlyAssignUnselectedSpaces() async throws {
        let root = try AppDatabase.makeInMemory(), workspace = workspace(root)
        let spaces = SpaceRepository(database: root)
        let selected = try spaces.create(title: "Selected")
        let remaining = try spaces.create(title: "Not selected")
        let account = AccountIdentity.apple("selective-adoption")
        workspace.currentOwner = { account.libraryOwnerKey }
        await workspace.activate(account, local: true)
        try await workspace.adopt(spaceIDs: [selected.id], includeSavedStyles: false, identity: account)
        #expect(!workspace.usesLocalLibrary)
        #expect(try workspace.environment?.spaces.space(id: selected.id) != nil)
        #expect(try workspace.environment?.spaces.space(id: remaining.id) == nil)
        #expect(try spaces.space(id: remaining.id)?.libraryID == LibraryRecord.localID)
    }

    @Test func localModeAndSpacePreferencesRemainIndependentForTwoEmailAccounts() async throws {
        let root = try AppDatabase.makeInMemory(), workspace = workspace(root)
        let a = AccountIdentity.email(project: "https://example.com", userID: UUID())
        let b = AccountIdentity.email(project: "https://example.com", userID: UUID())
        var active = a
        workspace.currentOwner = { active.libraryOwnerKey }
        await workspace.activate(a, local: false)
        let first = try #require(workspace.environment)
        let chosen = try first.spaces.create(title: "Chosen")
        try await first.switchSpace(to: chosen.id)
        active = b; await workspace.activate(b, local: false)
        #expect(workspace.environment?.selectedSpaceID != chosen.id)
        active = a; await workspace.activate(a)
        #expect(workspace.environment?.selectedSpaceID == chosen.id)
        await workspace.activate(a, local: true)
        #expect(workspace.usesLocalLibrary)
        active = b; await workspace.activate(b)
        #expect(!workspace.usesLocalLibrary)
        active = a; await workspace.activate(a)
        #expect(workspace.usesLocalLibrary)
    }

    @Test func failedSaveKeepsTheOldEditorButDoesNotExposeItToTheNewAccount() async throws {
        let root = try AppDatabase.makeInMemory(), workspace = workspace(root)
        let a = AccountIdentity.apple("a"), b = AccountIdentity.apple("b")
        var active = a; workspace.currentOwner = { active.libraryOwnerKey }
        await workspace.activate(a, local: false)
        let first = try #require(workspace.environment)
        let page = try #require(first.createDocument(title: "Keep this editor"))
        let model = first.editorCache.prepare(page)
        model.prepareForSpaceChange = { throw VellixError.database("Test save failure") }
        active = b; await workspace.activate(b, local: false)
        #expect(workspace.errorMessage != nil && !workspace.matches(b))
        #expect(workspace.environment === first && first.database.isAccessible)
        #expect(first.editorCache.model(for: page.id) === model)
        active = a; await workspace.activate(a)
        #expect(workspace.matches(a) && first.editorCache.model(for: page.id) === model)
        model.prepareForSpaceChange = nil
        active = b
        await workspace.activate(b, local: false)
        #expect(workspace.matches(b) && !first.database.isAccessible)
    }

    @Test func rapidAccountChangesSerializeBehindAnInFlightEditorOperation() async throws {
        let root = try AppDatabase.makeInMemory(), workspace = workspace(root)
        let a = AccountIdentity.apple("a"), b = AccountIdentity.apple("b"), c = AccountIdentity.apple("c")
        var active = a; workspace.currentOwner = { active.libraryOwnerKey }
        await workspace.activate(a, local: false)
        let first = try #require(workspace.environment)
        let page = try #require(first.createDocument(title: "Pending operation"))
        let model = first.editorCache.prepare(page)
        let operation = model.beginPersistentOperation()
        active = b
        let switching = Task { await workspace.activate(b, local: false) }
        await Task.yield()
        active = c
        let newest = Task { await workspace.activate(c, local: false) }
        await Task.yield()
        model.endPersistentOperation(operation)
        await switching.value; await newest.value
        #expect(workspace.matches(c))
        #expect(workspace.environment?.database.libraryID == LibraryRecord.accountID(ownerKey: c.libraryOwnerKey))
        #expect(try DocumentRepository(database: root.scoped(to: LibraryRecord.accountID(ownerKey: a.libraryOwnerKey))).requireDocument(id: page.id).title == page.title)
    }
}
