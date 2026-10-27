import Foundation
import SwiftData
import AuthenticationServices
import CryptoKit
import Testing
@testable import Vellix

@MainActor
private final class TestAccountSession: AccountSessionStoring {
    var identity: AccountIdentity?
    var id: String? {
        get { if case .apple(let id) = identity { return id }; return nil }
        set { identity = newValue.map(AccountIdentity.apple) }
    }
    var fails = false
    func currentIdentity() throws -> AccountIdentity? { identity }
    func setCurrentIdentity(_ identity: AccountIdentity) throws {
        if fails { throw AccountError.keychainUnavailable }
        self.identity = identity
    }
    func clear() throws {
        if fails { throw AccountError.keychainUnavailable }
        identity = nil
    }
}

@MainActor
private final class TestAccountCloud: AccountCloudStoring {
    var owner = "cloud-owner"
    var profiles: [String: AccountProfile] = [:]
    var fails = false
    var deletionFails = false
    var saved: [String] = []
    var deleted: [String] = []
    var suspended: CheckedContinuation<Void, Never>?
    var suspendFetch = false
    func accountID() async throws -> String {
        if fails { throw AccountError.iCloudUnavailable }
        return owner
    }
    func fetch(identity: AccountIdentity, ownerID: String) async throws -> AccountProfile? {
        if suspendFetch {
            suspendFetch = false
            await withCheckedContinuation { suspended = $0 }
        }
        return profiles[identity.cloudIdentity]
    }
    func save(_ profile: AccountProfile, identity: AccountIdentity, ownerID: String) async throws {
        if fails { throw AccountError.iCloudUnavailable }
        profiles[identity.cloudIdentity] = profile
        saved.append(identity.cloudIdentity)
    }
    func delete(identity: AccountIdentity, ownerID: String) async throws {
        if fails || deletionFails { throw AccountError.iCloudUnavailable }
        profiles[identity.cloudIdentity] = nil
        deleted.append(identity.cloudIdentity)
    }
}

@MainActor
private final class TestEmailAuth: EmailAuthenticating {
    var next: VerifiedEmailAccount?
    var sessions: [AccountIdentity: VerifiedEmailAccount] = [:]
    var sent: [String] = []
    var signedOut: [AccountIdentity] = []
    var forgotten: [AccountIdentity] = []
    var deleted: [AccountIdentity] = []
    var sendError: EmailAuthError?
    var verifyError: EmailAuthError?
    var deleteError: EmailAuthError?
    var restoreErrors: [AccountIdentity: EmailAuthError] = [:]
    var suspendVerification = false
    var verificationGate: CheckedContinuation<Void, Never>?
    func sendCode(email: String, attempt: UUID) async throws {
        if let sendError { throw sendError }
        sent.append(email)
    }
    func verifyCode(email: String, code: String, attempt: UUID) async throws -> VerifiedEmailAccount {
        if suspendVerification {
            await withCheckedContinuation { verificationGate = $0 }
        }
        if let verifyError { throw verifyError }
        guard let next else { throw EmailAuthError.invalidCode }
        sessions[next.identity] = next
        return next
    }
    func cancel(attempt: UUID) {}
    func restore(_ identity: AccountIdentity) async throws -> VerifiedEmailAccount {
        if let error = restoreErrors[identity] { throw error }
        guard let account = sessions[identity] else { throw EmailAuthError.sessionExpired }
        return account
    }
    func signOut(_ identity: AccountIdentity) async throws { signedOut.append(identity); try forget(identity) }
    func forget(_ identity: AccountIdentity) throws { forgotten.append(identity); sessions[identity] = nil }
    func deleteAccount(_ identity: AccountIdentity) async throws {
        if let deleteError { throw deleteError }
        deleted.append(identity)
        sessions[identity] = nil
    }
}

@Suite @MainActor
struct AccountTests {
    private func fixture(publishingDeletion: @escaping (AccountIdentity) async throws -> Void = { _ in }) throws -> (ModelContainer, TestAccountSession, AuthService, TestAccountCloud, AppState) {
        let container = try AccountPersistence.makeContainer(inMemory: true)
        let session = TestAccountSession()
        let auth = AuthService(session: session, publishingOwnerDeletion: publishingDeletion, credentialState: { _ in .authorized })
        let cloud = TestAccountCloud()
        let state = AppState(container: container, auth: auth, cloud: cloud)
        return (container, session, auth, cloud, state)
    }

    private func signIn(_ id: String, container: ModelContainer, auth: AuthService) throws -> AuthUser {
        try auth.signIn(identity: AppleAccountIdentity(userID: id, email: "\(id)@example.com", displayName: id),
            existingUsers: container.mainContext.fetch(FetchDescriptor<AuthUser>()), modelContext: container.mainContext)
    }

    @Test func repeatingAppleSignInReusesAccountAndPreservesCustomProfile() throws {
        let (container, session, auth, _, _) = try fixture()
        let user = try signIn("first", container: container, auth: auth)
        user.displayName = "Custom name"; user.email = "contact@example.com"; user.profileImageData = Data([1, 2, 3])
        try container.mainContext.save()
        let again = try signIn("first", container: container, auth: auth)
        #expect(again === user)
        #expect(again.displayName == "Custom name")
        #expect(again.email == "contact@example.com")
        #expect(again.profileImageData == Data([1, 2, 3]))
        #expect(try container.mainContext.fetchCount(FetchDescriptor<AuthUser>()) == 1)
        #expect(session.id == "first")
    }

    @Test func restoringSessionChecksCredentialAndReturnsPersistedUser() async throws {
        let (container, _, auth, _, _) = try fixture()
        let user = try signIn("first", container: container, auth: auth)
        let restored = try await auth.fetchMeWithAutoRefresh(modelContext: container.mainContext)
        #expect(restored === user)
    }

    @Test func revokedAppleCredentialClearsOnlyTheSession() async throws {
        let (container, session, auth, _, _) = try fixture()
        _ = try signIn("first", container: container, auth: auth)
        let revoked = AuthService(session: session, credentialState: { _ in .revoked })
        await #expect(throws: AuthService.AuthServiceError.credentialRevoked) {
            try await revoked.fetchMeWithAutoRefresh(modelContext: container.mainContext)
        }
        #expect(session.id == nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<AuthUser>()) == 1)
    }

    @Test func localProfilePersistenceSurvivesClosingAndReopeningTheStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func save() throws {
            let container = try AccountPersistence.makeContainer(directory: directory)
            let user = AuthUser(displayName: "Saved name", appleUserId: "saved")
            user.profileImageData = Data([7, 8, 9]); user.profileNeedsUpload = true
            user.cloudAccountRecordName = "cloud-owner"
            container.mainContext.insert(user); try container.mainContext.save()
        }
        try save()
        let reopened = try AccountPersistence.makeContainer(directory: directory)
        let user = try #require(reopened.mainContext.fetch(FetchDescriptor<AuthUser>()).first)
        #expect(user.displayName == "Saved name")
        #expect(user.profileImageData == Data([7, 8, 9]))
        #expect(user.profileNeedsUpload)
        #expect(user.cloudAccountRecordName == "cloud-owner")
    }

    @Test func cloudProfileWinsOverFirstSignInDefaultsOnANewDevice() async throws {
        let (container, _, auth, cloud, state) = try fixture()
        let profile = AccountProfile(name: "Cloud name", email: "cloud@example.com", imageData: Data([3]))
        cloud.profiles["first"] = profile
        let user = try signIn("first", container: container, auth: auth)
        state.setSignedIn(user); await state.waitForProfileSync()
        #expect(user.accountProfile == profile)
        #expect(cloud.saved.isEmpty)
        #expect(user.cloudAccountRecordName == "cloud-owner")
    }

    @Test func offlineEditsStayPersistentAndUploadOnRetry() async throws {
        let (container, _, auth, cloud, state) = try fixture()
        cloud.fails = true
        let user = try signIn("first", container: container, auth: auth)
        state.setSignedIn(user); await state.waitForProfileSync()
        try state.updateCurrentUserDisplayName(" Offline edit ")
        try state.updateEmail("contact@example.com")
        await state.waitForProfileSync()
        #expect(user.displayName == "Offline edit")
        #expect(user.profileNeedsUpload)
        #expect(state.errorMessage != nil)
        cloud.fails = false
        state.refreshProfile(); await state.waitForProfileSync()
        #expect(cloud.profiles["first"]?.name == "Offline edit")
        #expect(cloud.profiles["first"]?.email == "contact@example.com")
        #expect(!user.profileNeedsUpload)
        #expect(state.errorMessage == nil)
    }

    @Test func invalidEditsDoNotMutateSavedFields() async throws {
        let (container, _, auth, _, state) = try fixture()
        let user = try signIn("first", container: container, auth: auth)
        state.setSignedIn(user); await state.waitForProfileSync()
        let before = user.accountProfile
        #expect(throws: AccountError.invalidName) { try state.updateCurrentUserDisplayName("   ") }
        #expect(throws: AccountError.invalidEmail) { try state.updateEmail("not an email") }
        #expect(user.accountProfile == before)
    }

    @Test func switchingICloudAccountsNeverUploadsToTheWrongPrivateDatabase() async throws {
        let (container, _, auth, cloud, state) = try fixture()
        let user = try signIn("first", container: container, auth: auth)
        user.cloudAccountRecordName = "original-cloud-owner"; user.profileNeedsUpload = true
        try container.mainContext.save()
        state.setSignedIn(user); await state.waitForProfileSync()
        #expect(cloud.saved.isEmpty)
        #expect(user.profileNeedsUpload)
        #expect(state.currentUser === user)
        #expect(state.errorMessage == AccountError.differentCloudAccount.localizedDescription)
    }

    @Test func accountSwitchDiscardsStaleInFlightProfileResults() async throws {
        let (container, _, auth, cloud, state) = try fixture()
        cloud.profiles["first"] = AccountProfile(name: "First cloud", email: nil, imageData: nil)
        let first = try signIn("first", container: container, auth: auth)
        let second = try signIn("second", container: container, auth: auth)
        cloud.suspendFetch = true
        state.setSignedIn(first)
        for _ in 0..<1_000 where cloud.suspended == nil { await Task.yield() }
        #expect(cloud.suspended != nil)
        state.setSignedIn(second)
        cloud.suspended?.resume(); cloud.suspended = nil
        await state.waitForProfileSync()
        #expect(state.currentUser === second)
        #expect(first.displayName == "first")
        #expect(cloud.profiles["second"]?.name == "second")
    }

    @Test func logoutKeepsSavedAccountsAndCloudData() async throws {
        let (container, session, auth, cloud, state) = try fixture()
        let user = try signIn("first", container: container, auth: auth)
        state.setSignedIn(user); await state.waitForProfileSync()
        await state.signOut()
        #expect(state.currentUser == nil)
        #expect(session.id == nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<AuthUser>()) == 1)
        #expect(cloud.profiles["first"] != nil)
    }

    @Test func accountDeletionRemovesOnlyTheSelectedLocalAndCloudProfile() async throws {
        let (container, session, auth, cloud, state) = try fixture()
        let first = try signIn("first", container: container, auth: auth)
        _ = try signIn("second", container: container, auth: auth)
        try await auth.activate(first)
        state.setSignedIn(first); await state.waitForProfileSync()
        cloud.profiles["second"] = AccountProfile(name: "Other", email: nil, imageData: nil)
        try await state.deleteCurrentAccount()
        #expect(state.currentUser == nil)
        #expect(session.id == nil)
        #expect(cloud.deleted == ["first"])
        #expect(cloud.profiles["second"]?.name == "Other")
        #expect(try container.mainContext.fetch(FetchDescriptor<AuthUser>()).map(\.appleUserId) == ["second"])
    }

    @Test func failedCloudDeletionDoesNotPretendTheAccountWasDeleted() async throws {
        let (container, session, auth, cloud, state) = try fixture()
        let user = try signIn("first", container: container, auth: auth)
        state.setSignedIn(user); await state.waitForProfileSync()
        cloud.fails = true
        await #expect(throws: AccountError.iCloudUnavailable) { try await state.deleteCurrentAccount() }
        #expect(state.currentUser === user)
        #expect(session.id == "first")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<AuthUser>()) == 1)
    }

    @Test func failedPublishingRevocationKeepsTheAppleAccountAndCloudProfile() async throws {
        let (container, session, auth, cloud, state) = try fixture(publishingDeletion: { _ in throw PublishingFailure.unavailable("Server unavailable") })
        let user = try signIn("first", container: container, auth: auth)
        state.setSignedIn(user); await state.waitForProfileSync()
        await #expect(throws: (any Error).self) { try await state.deleteCurrentAccount() }
        #expect(state.currentUser === user)
        #expect(session.id == "first")
        #expect(cloud.deleted.isEmpty)
        #expect(!user.remoteAuthDeleted)
    }

    @Test func applePublishingRevocationIsDurableAcrossCloudCleanupRetries() async throws {
        var revoked: [AccountIdentity] = []
        let (container, _, auth, cloud, state) = try fixture(publishingDeletion: { revoked.append($0) })
        let user = try signIn("first", container: container, auth: auth)
        state.setSignedIn(user); await state.waitForProfileSync()
        cloud.deletionFails = true
        await #expect(throws: AccountError.iCloudUnavailable) { try await state.deleteCurrentAccount() }
        #expect(user.remoteAuthDeleted)
        let restored = AppState(container: container, auth: auth, cloud: cloud)
        await restored.bootstrap()?.value
        cloud.deletionFails = false
        try await restored.deleteCurrentAccount()
        #expect(revoked == [.apple("first")])
        #expect(restored.currentUser == nil)
    }

    @Test func deletionOnAnotherDeviceCannotBeResurrectedByCachedProfileSync() async throws {
        let (container, session, auth, cloud, state) = try fixture()
        let user = try signIn("first", container: container, auth: auth)
        state.setSignedIn(user); await state.waitForProfileSync()
        cloud.profiles["first"] = nil
        state.refreshProfile(); await state.waitForProfileSync()
        #expect(state.currentUser == nil)
        #expect(session.id == nil)
        #expect(cloud.saved.count == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<AuthUser>()) == 0)
    }

    @Test func keychainFailureDoesNotReplaceThePreviousSession() throws {
        let (container, session, auth, _, _) = try fixture()
        _ = try signIn("first", container: container, auth: auth)
        session.fails = true
        #expect(throws: AccountError.keychainUnavailable) { try signIn("second", container: container, auth: auth) }
        #expect(session.id == "first")
    }

    @Test func cloudRecordIdentifiersAreStableDistinctAndDoNotExposeTheAppleIdentifier() {
        let first = AccountCloudStore.recordID(for: "private-apple-id").recordName
        #expect(first == AccountCloudStore.recordID(for: "private-apple-id").recordName)
        #expect(first != AccountCloudStore.recordID(for: "another-id").recordName)
        #expect(!first.contains("private-apple-id"))
    }

    @Test func activatingSavedAccountValidatesItAndStartsProfileSync() async throws {
        let (container, session, auth, cloud, state) = try fixture()
        _ = try signIn("first", container: container, auth: auth)
        let second = try signIn("second", container: container, auth: auth)
        try await state.activate(second)
        await state.waitForProfileSync()
        #expect(state.currentUser === second)
        #expect(session.id == "second")
        #expect(cloud.profiles["second"]?.name == "second")
    }

    @Test func revokedSavedAccountCannotSignOutTheCurrentlyActiveDifferentAccount() async throws {
        let (container, session, auth, _, _) = try fixture()
        let revokedUser = try signIn("revoked", container: container, auth: auth)
        _ = try signIn("active", container: container, auth: auth)
        let switching = AuthService(session: session, credentialState: { _ in .revoked })
        await #expect(throws: AuthService.AuthServiceError.credentialRevoked) { try await switching.activate(revokedUser) }
        #expect(session.id == "active")
    }

    @Test func appBootstrapRestoresSessionAndSyncsWithoutBlockingTheLibraryOnICloudFailure() async throws {
        let (container, _, auth, cloud, state) = try fixture()
        let user = try signIn("first", container: container, auth: auth)
        cloud.fails = true
        await state.bootstrap()?.value
        await state.waitForProfileSync()
        #expect(state.currentUser === user)
        #expect(state.errorMessage == AccountError.iCloudUnavailable.localizedDescription)
    }
}

@Suite @MainActor
struct AccountEmailTests {
    private func fixture() throws -> (ModelContainer, TestAccountSession, TestEmailAuth, AuthService, TestAccountCloud, AppState) {
        let container = try AccountPersistence.makeContainer(inMemory: true)
        let session = TestAccountSession()
        let email = TestEmailAuth()
        let auth = AuthService(session: session, email: email, credentialState: { _ in .authorized })
        let cloud = TestAccountCloud()
        return (container, session, email, auth, cloud, AppState(container: container, auth: auth, cloud: cloud))
    }

    private func login(_ address: String, id: UUID = UUID(), email: TestEmailAuth, state: AppState) async throws -> AuthUser {
        email.next = VerifiedEmailAccount(identity: .email(project: "https://auth.example.com", userID: id), email: address)
        let attempt = UUID()
        _ = try await state.requestEmailCode(address, attempt: attempt)
        try await state.verifyEmailCode(address, code: "12345678", attempt: attempt)
        await state.waitForProfileSync()
        return try #require(state.currentUser)
    }

    @Test func requestsAndResendsNormalizeOnlyTheAddress() async throws {
        let (_, session, email, _, _, state) = try fixture()
        let attempt = UUID()
        #expect(try await state.requestEmailCode(" User@Example.com \n", attempt: attempt) == "user@example.com")
        _ = try await state.requestEmailCode("user@example.com", attempt: attempt)
        #expect(email.sent == ["user@example.com", "user@example.com"])
        #expect(session.identity == nil)
        #expect(state.savedAccounts.isEmpty)
    }

    @Test func requestNetworkErrorsNeverCreateAnAccount() async throws {
        let (_, session, email, _, _, state) = try fixture()
        email.sendError = .network
        await #expect(throws: EmailAuthError.network) { try await state.requestEmailCode("user@example.com", attempt: UUID()) }
        #expect(state.savedAccounts.isEmpty)
        #expect(session.identity == nil)
    }

    @Test func appleAndEmailAccountsWithTheSameAddressDoNotMerge() async throws {
        let (container, _, email, auth, _, state) = try fixture()
        let apple = try auth.signIn(identity: AppleAccountIdentity(userID: "native", email: "user@example.com"),
            existingUsers: [], modelContext: container.mainContext)
        let other = try await login("user@example.com", email: email, state: state)
        #expect(other !== apple)
        #expect(other.isEmail && apple.isApple)
        #expect(state.savedAccounts.count == 2)
        #expect(other.appleUserId == nil)
        #expect(other.supabaseUserID != nil)
    }

    @Test func uuidIdentityRestoresTheSameAccountWithoutReplacingContactDetails() async throws {
        let (_, _, email, _, _, state) = try fixture()
        let id = UUID()
        let first = try await login("login@example.com", id: id, email: email, state: state)
        try state.updateEmail("contact@example.com")
        try state.updateCurrentUserDisplayName("Custom name")
        await state.waitForProfileSync()
        let second = try await login("new-login@example.com", id: id, email: email, state: state)
        #expect(first === second)
        #expect(second.authenticationEmail == "new-login@example.com")
        #expect(second.email == "contact@example.com")
        #expect(second.displayName == "Custom name")
        #expect(state.savedAccounts.count == 1)
    }

    @Test func invalidAndExpiredCodesLeaveTheActiveAccountAlone() async throws {
        let (container, session, email, auth, _, state) = try fixture()
        let apple = try auth.signIn(identity: AppleAccountIdentity(userID: "active"), existingUsers: [], modelContext: container.mainContext)
        state.setSignedIn(apple); await state.waitForProfileSync()
        for error in [EmailAuthError.invalidCode, .expiredCode, .network, .rateLimited] {
            email.verifyError = error
            await #expect(throws: error) { try await state.verifyEmailCode("new@example.com", code: "123456", attempt: UUID()) }
            #expect(state.currentUser === apple)
            #expect(session.identity == .apple("active"))
            #expect(state.savedAccounts.count == 1)
        }
    }

    @Test func malformedCodesAreRejectedBeforeContactingTheProvider() async throws {
        let (_, _, email, _, _, state) = try fixture()
        email.verifyError = .network
        for code in ["12", "12a456", "12345678901", "１２３４５６"] {
            await #expect(throws: EmailAuthError.invalidCode) { try await state.verifyEmailCode("user@example.com", code: code, attempt: UUID()) }
        }
    }

    @Test func cancelledVerificationCannotSwitchTheAccount() async throws {
        let (container, session, email, auth, _, state) = try fixture()
        let apple = try auth.signIn(identity: AppleAccountIdentity(userID: "active"), existingUsers: [], modelContext: container.mainContext)
        state.setSignedIn(apple); await state.waitForProfileSync()
        email.next = VerifiedEmailAccount(identity: .email(project: "https://auth.example.com", userID: UUID()), email: "new@example.com")
        email.suspendVerification = true
        let task = Task { try await state.verifyEmailCode("new@example.com", code: "123456", attempt: UUID()) }
        for _ in 0..<1_000 where email.verificationGate == nil { await Task.yield() }
        let gate = try #require(email.verificationGate)
        task.cancel(); gate.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(state.currentUser === apple)
        #expect(session.identity == .apple("active"))
        #expect(state.savedAccounts.count == 1)
    }

    @Test func emailSessionRestoresThroughTheExistingBootstrap() async throws {
        let (container, session, email, auth, cloud, state) = try fixture()
        let user = try await login("restore@example.com", email: email, state: state)
        let restored = AppState(container: container, auth: auth, cloud: cloud)
        await restored.bootstrap()?.value; await restored.waitForProfileSync()
        #expect(restored.currentUser === user)
        #expect(session.identity == user.identity)
    }

    @Test func switchingBetweenAppleAndEmailRetainsTheEmailSession() async throws {
        let (container, session, email, auth, _, state) = try fixture()
        let apple = try auth.signIn(identity: AppleAccountIdentity(userID: "native"), existingUsers: [], modelContext: container.mainContext)
        let user = try await login("email@example.com", email: email, state: state)
        try await state.activate(apple); await state.waitForProfileSync()
        #expect(session.identity == apple.identity)
        try await state.activate(user); await state.waitForProfileSync()
        #expect(session.identity == user.identity)
        #expect(email.signedOut.isEmpty)
    }

    @Test func twoEmailAccountsRestoreIndependently() async throws {
        let (_, session, email, _, _, state) = try fixture()
        let first = try await login("first@example.com", email: email, state: state)
        let second = try await login("second@example.com", email: email, state: state)
        try await state.activate(first); await state.waitForProfileSync()
        #expect(session.identity == first.identity)
        try await state.activate(second); await state.waitForProfileSync()
        #expect(session.identity == second.identity)
        #expect(email.sessions.count == 2)
    }

    @Test func expiredSavedSessionCannotLogOutADifferentActiveAccount() async throws {
        let (_, session, email, _, _, state) = try fixture()
        let first = try await login("first@example.com", email: email, state: state)
        let second = try await login("second@example.com", email: email, state: state)
        let identity = try #require(first.identity)
        email.restoreErrors[identity] = .sessionExpired
        await #expect(throws: EmailAuthError.sessionExpired) { try await state.activate(first) }
        #expect(state.currentUser === second)
        #expect(session.identity == second.identity)
        #expect(email.forgotten == [identity])
    }

    @Test func revokedActiveEmailSessionClearsOnlyItsSessionNotTheAccountCache() async throws {
        let (_, session, email, _, _, state) = try fixture()
        let user = try await login("first@example.com", email: email, state: state)
        email.restoreErrors[try #require(user.identity)] = .sessionExpired
        await state.bootstrap(force: true)?.value
        #expect(state.currentUser == nil)
        #expect(session.identity == nil)
        #expect(state.savedAccounts.count == 1)
    }

    @Test func networkFailureDuringRestorationDoesNotClearSecureSession() async throws {
        let (_, session, email, _, _, state) = try fixture()
        let user = try await login("first@example.com", email: email, state: state)
        email.restoreErrors[try #require(user.identity)] = .network
        await state.bootstrap(force: true)?.value
        #expect(state.currentUser === user)
        #expect(session.identity == user.identity)
        #expect(email.forgotten.isEmpty)
    }

    @Test func contactEmailEditsDoNotChangeVerifiedAuthenticationEmail() async throws {
        let (_, _, email, _, _, state) = try fixture()
        let user = try await login("verified@example.com", email: email, state: state)
        try state.updateEmail("contact@example.com"); await state.waitForProfileSync()
        #expect(user.email == "contact@example.com")
        #expect(user.authenticationEmail == "verified@example.com")
    }

    @Test func profileSyncAndCloudRecordNamesAreSeparatedByProvider() async throws {
        let (container, _, email, auth, cloud, state) = try fixture()
        let uuid = UUID()
        let apple = try auth.signIn(identity: AppleAccountIdentity(userID: uuid.uuidString.lowercased()), existingUsers: [], modelContext: container.mainContext)
        state.setSignedIn(apple); await state.waitForProfileSync()
        let user = try await login("email@example.com", id: uuid, email: email, state: state)
        try state.updateCurrentUserDisplayName("Email name"); await state.waitForProfileSync()
        try await state.activate(apple); await state.waitForProfileSync()
        #expect(apple.displayName != "Email name")
        #expect(cloud.profiles.count == 2)
        #expect(AccountCloudStore.recordID(for: try #require(apple.identity)) != AccountCloudStore.recordID(for: try #require(user.identity)))
        #expect(AccountCloudStore.recordID(for: uuid.uuidString.lowercased()) == AccountCloudStore.recordID(for: try #require(apple.identity)))
    }

    @Test func emailAccountCannotUploadUnderADifferentICloudOwner() async throws {
        let (_, _, email, _, cloud, state) = try fixture()
        let user = try await login("email@example.com", email: email, state: state)
        let before = cloud.saved.count
        cloud.owner = "different-owner"
        try state.updateCurrentUserDisplayName("Local pending name"); await state.waitForProfileSync()
        #expect(user.profileNeedsUpload)
        #expect(cloud.saved.count == before)
        #expect(state.errorMessage == AccountError.differentCloudAccount.localizedDescription)
    }

    @Test func logoutRemovesOnlyTheSelectedEmailSession() async throws {
        let (_, session, email, _, cloud, state) = try fixture()
        let first = try await login("first@example.com", email: email, state: state)
        let second = try await login("second@example.com", email: email, state: state)
        await state.signOut()
        #expect(session.identity == nil)
        #expect(email.sessions[try #require(first.identity)] != nil)
        #expect(email.sessions[try #require(second.identity)] == nil)
        #expect(cloud.profiles.count == 2)
        #expect(state.savedAccounts.count == 2)
    }

    @Test func secureEmailDeletionRemovesOnlyTheSelectedAccount() async throws {
        let (_, session, email, _, cloud, state) = try fixture()
        let first = try await login("first@example.com", email: email, state: state)
        let second = try await login("second@example.com", email: email, state: state)
        try await state.deleteCurrentAccount()
        #expect(email.deleted == [try #require(second.identity)])
        #expect(cloud.profiles[try #require(first.identity).cloudIdentity] != nil)
        #expect(state.savedAccounts.count == 1)
        #expect(session.identity == nil)
    }

    @Test func missingDeletionBackendDoesNotDeleteTheCloudProfileOrLocalAccount() async throws {
        let (_, session, email, _, cloud, state) = try fixture()
        let user = try await login("email@example.com", email: email, state: state)
        email.deleteError = .deletionUnavailable
        await #expect(throws: EmailAuthError.deletionUnavailable) { try await state.deleteCurrentAccount() }
        #expect(state.currentUser === user)
        #expect(session.identity == user.identity)
        #expect(cloud.deleted.isEmpty)
        #expect(!user.remoteAuthDeleted)
    }

    @Test func confirmedEmailDeletionCanResumeICloudCleanupAfterRelaunch() async throws {
        let (container, _, email, auth, cloud, state) = try fixture()
        let user = try await login("email@example.com", email: email, state: state)
        cloud.deletionFails = true
        await #expect(throws: AccountError.iCloudUnavailable) { try await state.deleteCurrentAccount() }
        #expect(user.remoteAuthDeleted)
        if case .deletionPending = state.status {} else { Issue.record("Must not claim a remotely deleted account is authenticated") }
        let restored = AppState(container: container, auth: auth, cloud: cloud)
        await restored.bootstrap()?.value
        #expect(restored.currentUser === user)
        cloud.deletionFails = false
        try await restored.deleteCurrentAccount()
        #expect(email.deleted.count == 1)
        #expect(restored.currentUser == nil)
        #expect(restored.savedAccounts.isEmpty)
    }

    @Test func appleRevocationNotificationCannotLogOutAnEmailAccount() async throws {
        let (_, session, email, _, _, state) = try fixture()
        let user = try await login("email@example.com", email: email, state: state)
        await state.handleAppleCredentialRevoked()
        #expect(state.currentUser === user)
        #expect(session.identity == user.identity)
        #expect(email.signedOut.isEmpty)
    }

    @Test func providerAwareIdentityRoundTripsWithoutUsingEmailAsTheKey() throws {
        let id = UUID()
        for identity in [AccountIdentity.apple(id.uuidString), .email(project: "https://auth.example.com", userID: id)] {
            #expect(try JSONDecoder().decode(AccountIdentity.self, from: JSONEncoder().encode(identity)) == identity)
        }
        #expect(AccountIdentity.apple(id.uuidString) != .email(project: "https://auth.example.com", userID: id))
        let email = AccountIdentity.email(project: "https://auth.example.com", userID: id)
        #expect(AccountIdentity.apple(email.cloudIdentity).libraryOwnerKey != email.libraryOwnerKey)
        #expect(AccountIdentity.apple("existing-user").cloudIdentity == "existing-user")
        #expect(AccountIdentity.apple("existing-user").libraryOwnerKey == "apple:existing-user")
    }

    @Test func existingAppleCloudKitRecordNamesRetainTheOriginalHashInputAndPrefix() {
        let rawID = "legacy-native-id"
        let digest = SHA256.hash(data: Data(rawID.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(AccountCloudStore.recordID(for: .apple(rawID)).recordName == "account-" + digest)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PENNED_LEGACY_ACCOUNT_STORE"] != nil))
    func existingAppleOnlyStoreMigratesWithoutChangingItsProfileOrIdentity() throws {
        let source = try #require(ProcessInfo.processInfo.environment["PENNED_LEGACY_ACCOUNT_STORE"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: directory)
        let container = try AccountPersistence.makeContainer(directory: directory)
        let users = try container.mainContext.fetch(FetchDescriptor<AuthUser>())
        let user = try #require(users.first)
        #expect(users.count == 1)
        #expect(user.identity == .apple("legacy-native-id"))
        #expect(user.email == "contact@example.com")
        #expect(user.displayName == "Existing Apple Account")
        #expect(user.profileImageData == Data([1, 2, 3]))
        #expect(user.cloudAccountRecordName == "legacy-cloud-owner")
        #expect(user.profileNeedsUpload && user.profileRevision == 4)
        #expect(user.supabaseUserID == nil && user.supabaseProjectURL == nil)
        #expect(!user.remoteAuthDeleted)
    }
}
