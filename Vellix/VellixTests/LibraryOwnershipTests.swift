import Foundation
import GRDB
import Testing
@testable import Vellix

@Suite @MainActor
struct LibraryOwnershipTests {
    @Test func version22UpgradeNeverClassifiesAnExistingEmptyPersonalByItsName() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.vellixMigrator.migrate(queue, upTo: "v22_cloudkit_record_journal")
        let previous = try queue.read { try SpaceRecord.fetchAll($0) }
        let root = try AppDatabase(queue, isInMemory: true)
        #expect(try root.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bootstrapSpaces") } == 0)
        #expect(try SpaceRepository(database: root).all() == previous)
        let claim = try LibraryRepository(database: root).claimLocalLibrary(ownerKey: "apple:existing-empty")
        #expect(try SpaceRepository(database: root.scoped(to: claim.library.id)).all().map(\.id) == previous.map(\.id))
    }

    @Test func bootstrapProvenanceNeverGuessesFromSpaceNamesAndPromotesAuthoredContent() throws {
        let root = try AppDatabase.makeInMemory()
        let libraries = LibraryRepository(database: root)
        #expect(try !libraries.hasUnownedLocalContent())
        let bootstrapID = try #require(SpaceRepository(database: root).all().first?.id)
        _ = try DocumentRepository(database: root).create(DocumentDraft(title: "Local page", spaceID: bootstrapID))
        #expect(try libraries.hasUnownedLocalContent())
        let explicitEmpty = try SpaceRepository(database: root).create(title: "Personal")
        let claimed = try libraries.claimLocalLibrary(ownerKey: "apple:provenance")
        let scoped = root.scoped(to: claimed.library.id)
        #expect(Set(try SpaceRepository(database: scoped).all().map(\.id)) == [bootstrapID, explicitEmpty.id])
    }

    @Test func editingAnEmptyBootstrapSpaceMakesItEligibleForSignInOwnership() throws {
        let root = try AppDatabase.makeInMemory()
        let spaces = SpaceRepository(database: root)
        let id = try #require(spaces.all().first?.id)
        try spaces.rename(id: id, title: "My Personal")
        #expect(try LibraryRepository(database: root).hasUnownedLocalContent())
        let claimed = try LibraryRepository(database: root).claimLocalLibrary(ownerKey: "apple:edited-bootstrap")
        #expect(try SpaceRepository(database: root.scoped(to: claimed.library.id)).all().map(\.id) == [id])
    }

    @Test func upgradingVersion19RetainsTheExistingLibrary() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.vellixMigrator.migrate(queue, upTo: "v19_document_tags")
        try queue.write { db in
            let spaceID = try String.fetchOne(db, sql: "SELECT id FROM spaces LIMIT 1")!
            try db.execute(sql: "INSERT INTO documents(id,title,tipTapJSON,spaceID,createdAt,updatedAt) VALUES ('legacy-document','Existing','{\"type\":\"doc\",\"content\":[]}',?,?,?)",
                           arguments: [spaceID, Date(), Date()])
        }
        let database = try AppDatabase(queue)
        #expect(try DocumentRepository(database: database).requireDocument(id: "legacy-document").title == "Existing")
        #expect(try SpaceRepository(database: database).includingArchived().allSatisfy { $0.libraryID == "local" })
        #expect(try LibraryRepository(database: database).library(id: "local")?.syncEnabled == false)
    }

    @Test func migrationKeepsAllExistingIdentifiersAndContentLocal() throws {
        let db = try AppDatabase.makeInMemory()
        let spaces = SpaceRepository(database: db)
        let space = try spaces.create(title: "Unclaimed")
        let document = try DocumentRepository(database: db).create(DocumentDraft(title: "Existing", spaceID: space.id))
        #expect(try spaces.space(id: space.id)?.libraryID == LibraryRecord.localID)
        #expect(try DocumentRepository(database: db).requireDocument(id: document.id).tipTapJSON == document.tipTapJSON)
        #expect(try LibraryRepository(database: db).library(id: LibraryRecord.localID)?.syncEnabled == false)
    }

    @Test func adoptionRequiresConfirmationAndPreservesContentIDs() throws {
        let db = try AppDatabase.makeInMemory()
        let spaces = SpaceRepository(database: db)
        let space = try spaces.create(title: "Adopt me")
        let document = try DocumentRepository(database: db).create(DocumentDraft(title: "Existing", spaceID: space.id))
        let libraries = LibraryRepository(database: db)
        let library = try libraries.accountLibrary(ownerKey: "apple:test-user")
        #expect(throws: LibraryError.confirmationRequired) {
            try libraries.adopt(spaceIDs: [space.id], into: library.id, ownerKey: "apple:test-user", includeSavedStyles: false, confirmed: false)
        }
        #expect(try spaces.space(id: space.id)?.libraryID == "local")
        try libraries.adopt(spaceIDs: [space.id], into: library.id, ownerKey: "apple:test-user", includeSavedStyles: false, confirmed: true)
        let owned = db.scoped(to: library.id)
        #expect(try spaces.space(id: space.id) == nil)
        #expect(try SpaceRepository(database: owned).space(id: space.id)?.libraryID == library.id)
        #expect(try DocumentRepository(database: owned).requireDocument(id: document.id).spaceID == space.id)
        #expect(try libraries.library(id: library.id)?.syncEnabled == false)
    }

    @Test func signInClaimMovesTheWholeUnownedLibraryWithoutCopyingOrStealingContent() throws {
        let root = try AppDatabase.makeInMemory()
        let spaces = SpaceRepository(database: root)
        let space = try spaces.create(title: "Existing writing")
        var archived = try spaces.create(title: "Archived writing")
        archived.isArchived = true
        try spaces.save(archived)
        let folder = try FolderRepository(database: root).create(title: "Folder", spaceID: space.id)
        let page = try DocumentRepository(database: root).create(DocumentDraft(title: "Existing page", spaceID: space.id, folderID: folder.id))
        let templates = TemplateRepository(database: root)
        templates.spaceID = space.id
        let templatePage = try templates.create(title: "Existing template")
        let files = AttachmentStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let style = try DocumentStyleRepository(database: root, store: files).save(title: "Existing style", definition: DocumentStyleDefinition(appearance: .plain))
        let bootstrapIDs = Set(try root.read { try String.fetchAll($0, sql: "SELECT spaceID FROM bootstrapSpaces") })
        let localIDs = Set(try spaces.includingArchived().map(\.id)).subtracting(bootstrapIDs)
        try root.write { db in
            try db.execute(sql: "UPDATE librarySpaceDefaults SET spaceID=? WHERE libraryID='local'", arguments: [space.id])
        }
        let libraries = LibraryRepository(database: root)
        let claim = try libraries.claimLocalLibrary(ownerKey: "apple:first", preferredSpaceID: space.id)
        let account = root.scoped(to: claim.library.id)
        #expect(claim.selectedSpaceID == space.id && !claim.library.syncEnabled && claim.library.cloudAccountID == nil)
        #expect(Set(try spaces.includingArchived().map(\.id)) == bootstrapIDs)
        #expect(Set(try SpaceRepository(database: account).includingArchived().map(\.id)) == localIDs)
        #expect(try SpaceRepository(database: account).space(id: archived.id)?.isArchived == true)
        #expect(try DocumentRepository(database: account).requireDocument(id: page.id).tipTapJSON == page.tipTapJSON)
        #expect(try DocumentRepository(database: account).requireDocument(id: page.id).folderID == folder.id)
        #expect(try TemplateRepository(database: account).all().map(\.id) == [templatePage.templateID!])
        #expect(try DocumentStyleRepository(database: account, store: files).all().first { $0.id == style.id }?.libraryID == claim.library.id)
        #expect(try account.read { try String.fetchOne($0, sql: "SELECT spaceID FROM librarySpaceDefaults WHERE libraryID=?", arguments: [claim.library.id]) } == space.id)
        #expect(try libraries.claimLocalLibrary(ownerKey: "apple:first").selectedSpaceID == nil)
        let other = try libraries.claimLocalLibrary(ownerKey: "email:second")
        #expect(try SpaceRepository(database: root.scoped(to: other.library.id)).includingArchived().isEmpty)
        #expect(Set(try SpaceRepository(database: account).includingArchived().map(\.id)) == localIDs)
    }

    @Test func failedClaimRollsBackAllOwnershipAndDefaultSpaceChanges() throws {
        let root = try AppDatabase.makeInMemory()
        let page = try DocumentRepository(database: root).create(DocumentDraft(title: "Keep local on failure"))
        let files = AttachmentStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        _ = try DocumentStyleRepository(database: root, store: files).save(title: "Style", definition: DocumentStyleDefinition(appearance: .plain))
        let before = try SpaceRepository(database: root).includingArchived()
        try root.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_claim BEFORE UPDATE OF libraryID ON documentStyles BEGIN SELECT RAISE(ABORT,'Test claim failure'); END")
        }
        #expect(throws: (any Error).self) { try LibraryRepository(database: root).claimLocalLibrary(ownerKey: "apple:failed") }
        #expect(try SpaceRepository(database: root).includingArchived() == before)
        #expect(try DocumentRepository(database: root).requireDocument(id: page.id).tipTapJSON == page.tipTapJSON)
        #expect(try root.read { try String.fetchOne($0, sql: "SELECT spaceID FROM librarySpaceDefaults WHERE libraryID='local'") } == page.spaceID)
    }

    @Test func claimQueuesNewlyOwnedRecordsOnlyForAnAlreadyOptedInLibrary() throws {
        let root = try AppDatabase.makeInMemory(), libraries = LibraryRepository(database: root)
        let library = try libraries.accountLibrary(ownerKey: "apple:enabled")
        let sync = LibrarySyncStore(database: root, libraryID: library.id, ownerKey: "apple:enabled", cloudAccountID: "iCloud-owner")
        try sync.enable(confirmed: true)
        let page = try DocumentRepository(database: root).create(DocumentDraft(title: "New local work"))
        _ = try libraries.claimLocalLibrary(ownerKey: "apple:enabled")
        #expect(try sync.pending().contains { $0.row.table == "documents" && $0.row.values["id"]?.text == page.id })
        #expect(try libraries.library(id: library.id)?.cloudAccountID == "iCloud-owner")
        #expect(try libraries.library(id: library.id)?.syncEnabled == true)
    }

    @Test func libraryScopesProtectListsDirectIDsWritesSearchAndLateCallbacks() throws {
        let root = try AppDatabase.makeInMemory()
        let libraries = LibraryRepository(database: root)
        let a = try libraries.accountLibrary(ownerKey: "apple:a")
        let b = try libraries.accountLibrary(ownerKey: "email:b")
        let first = root.scoped(to: a.id), second = root.scoped(to: b.id)
        let space = try SpaceRepository(database: first).create(title: "Private")
        let docs = DocumentRepository(database: first)
        let document = try docs.create(DocumentDraft(title: "Secret", spaceID: space.id))
        #expect(try DocumentRepository(database: second).allDocuments().isEmpty)
        #expect(try SpaceRepository(database: second).includingArchived().isEmpty)
        #expect(try DocumentRepository(database: second).document(id: document.id) == nil)
        #expect(try DocumentSearchService(database: second).search("Secret").isEmpty)
        #expect(throws: (any Error).self) { try DocumentRepository(database: second).updateTitle(id: document.id, title: "Wrong") }
        #expect(throws: (any Error).self) { try second.write { try $0.execute(sql: "UPDATE documents SET title='Wrong' WHERE id=?", arguments: [document.id]) } }
        first.invalidate()
        #expect(throws: LibraryError.staleWorkspace) { try docs.create(DocumentDraft(title: "Late callback")) }
        #expect(try DocumentRepository(database: root.scoped(to: a.id)).requireDocument(id: document.id).title == "Secret")
    }

    @Test func foreignOwnershipCannotBeAdoptedAndAccountIDsAreStable() throws {
        let db = try AppDatabase.makeInMemory()
        let libraries = LibraryRepository(database: db)
        let a = try libraries.accountLibrary(ownerKey: "apple:user")
        let b = try libraries.accountLibrary(ownerKey: "email:user")
        #expect(a.id != b.id)
        #expect(try libraries.accountLibrary(ownerKey: "apple:user").id == a.id)
        let space = try SpaceRepository(database: db).create(title: "Local")
        #expect(throws: LibraryError.wrongOwner) {
            try libraries.adopt(spaceIDs: [space.id], into: a.id, ownerKey: b.ownerKey!, includeSavedStyles: true, confirmed: true)
        }
        #expect(try SpaceRepository(database: db).space(id: space.id)?.libraryID == "local")
    }
}
