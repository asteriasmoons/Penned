//
//  AppState.swift
//  Penned
//

import Foundation
import Combine
import SwiftData
import AuthenticationServices

@MainActor
final class AppState: ObservableObject {
    
    enum SessionStatus {
        case checking
        case signedOut
        case signedIn(AuthUser)
        case deletionPending(AuthUser)
    }
    
    @Published private(set) var status: SessionStatus = .checking
    @Published var isPopupPresented: Bool = false
    @Published var hideTabBar: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var isWorking = false
    @Published private(set) var syncState = ""
    @Published private(set) var savedAccounts: [AuthUser] = []
    private(set) var accountContainer: ModelContainer?
    private let auth: AuthService
    private let cloud: any AccountCloudStoring
    private var syncTask: Task<Void, Never>?
    private var syncRequest = UUID()

    init(container: ModelContainer? = nil, auth: AuthService? = nil,
         cloud: (any AccountCloudStoring)? = nil) {
        self.auth = auth ?? .shared
        self.cloud = cloud ?? AccountCloudStore()
        do {
            accountContainer = try container ?? AccountPersistence.makeContainer()
            reloadAccounts()
        } catch {
            errorMessage = AccountError.storageUnavailable.localizedDescription
            status = .signedOut
        }
    }
    
    var currentUser: AuthUser? {
        switch status {
        case .signedIn(let user), .deletionPending(let user): return user
        default: return nil
        }
    }

    var currentAppleUserId: String? {
        guard currentUser?.isApple == true else { return nil }
        return currentUser?.appleUserId
    }

    var currentAccountIdentity: AccountIdentity? { currentUser?.identity }
    
    private var bootstrapTask: Task<Void, Never>?
    private var hasBootstrapped = false
    
    @discardableResult
    func bootstrap(force: Bool = false) -> Task<Void, Never>? {
        guard !isWorking else { return nil }
        if hasBootstrapped && !force { return nil }
        guard let modelContext = accountContainer?.mainContext else { return nil }

        bootstrapTask?.cancel()
        if currentUser == nil { status = .checking }
        hasBootstrapped = true

        bootstrapTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                let user = try await self.auth.fetchMeWithAutoRefresh(modelContext: modelContext)
                guard !Task.isCancelled else { return }
                self.setSignedIn(user)
            } catch {
                guard !Task.isCancelled else { return }
                if let authError = error as? AuthService.AuthServiceError {
                    self.status = .signedOut
                    self.syncRequest = UUID(); self.syncTask?.cancel(); self.syncState = ""
                    if authError == .notSignedIn { return }
                } else if error as? EmailAuthError == .sessionExpired {
                    self.status = .signedOut
                    self.syncRequest = UUID(); self.syncTask?.cancel(); self.syncState = ""
                } else if self.currentUser == nil { self.status = .signedOut }
                self.errorMessage = error.localizedDescription
            }
        }
        return bootstrapTask
    }

    func setSignedIn(_ user: AuthUser) {
        bootstrapTask?.cancel()
        syncRequest = UUID(); syncTask?.cancel()
        hasBootstrapped = true
        status = user.remoteAuthDeleted ? .deletionPending(user) : .signedIn(user)
        errorMessage = nil
        reloadAccounts()
        refreshProfile()
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential, existingUsers: [AuthUser], modelContext: ModelContext, nonce: PublishingAppleNonce? = nil) throws {
        let user = try auth.signInWithApple(credential: credential, existingUsers: existingUsers, modelContext: modelContext, nonce: nonce)
        setSignedIn(user)
    }

    func publishingAccessToken() async throws -> String {
        guard !isWorking else { throw CancellationError() }
        guard let identity = currentAccountIdentity, currentUser?.remoteAuthDeleted == false else { throw PublishingFailure.authenticationRequired }
        let token = try await auth.publishingAccessToken(for: identity)
        guard !isWorking, currentAccountIdentity == identity, currentUser?.remoteAuthDeleted == false else { throw CancellationError() }
        return token
    }

    func requestEmailCode(_ address: String, attempt: UUID) async throws -> String {
        try await auth.requestEmailCode(address, attempt: attempt)
    }

    func verifyEmailCode(_ address: String, code: String, attempt: UUID) async throws {
        guard !isWorking, let context = accountContainer?.mainContext else { throw AccountError.storageUnavailable }
        isWorking = true
        defer { isWorking = false; refreshProfile() }
        bootstrapTask?.cancel()
        let user = try await auth.verifyEmailCode(address, code: code, attempt: attempt, modelContext: context)
        setSignedIn(user)
    }

    func cancelEmailSignIn(attempt: UUID) { auth.cancelEmailSignIn(attempt: attempt) }

    func handleAppleCredentialRevoked() async {
        guard currentUser?.isApple == true else { return }
        await signOut()
    }

    func signOut() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        bootstrapTask?.cancel()
        syncRequest = UUID()
        syncTask?.cancel()
        do {
            try await auth.signOutActive()
            hasBootstrapped = true
            status = .signedOut
            syncState = ""
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func reloadAccounts() {
        do { savedAccounts = try accountContainer?.mainContext.fetch(FetchDescriptor<AuthUser>(sortBy: [SortDescriptor(\.createdAt)])) ?? [] }
        catch { errorMessage = error.localizedDescription }
    }

    func retryStorage() {
        do {
            accountContainer = try AccountPersistence.makeContainer()
            errorMessage = nil
            reloadAccounts()
            bootstrap(force: true)
        } catch { errorMessage = AccountError.storageUnavailable.localizedDescription }
    }

    func activate(_ user: AuthUser) async throws {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false; refreshProfile() }
        bootstrapTask?.cancel()
        try await auth.activate(user)
        setSignedIn(user)
    }

    func updateCurrentUserDisplayName(_ newName: String) throws {
        let name = try AccountValidation.name(newName)
        try editProfile { $0.displayName = name }
    }

    func updateEmail(_ value: String) throws {
        let email = try AccountValidation.email(value)
        try editProfile { $0.email = email }
    }

    func updateImage(_ data: Data?) throws {
        guard data == nil || data!.count <= 5 * 1_024 * 1_024 else { throw AccountError.invalidImage }
        try editProfile { $0.profileImageData = data; $0.profileImagePath = nil }
    }

    private func editProfile(_ edit: (AuthUser) -> Void) throws {
        guard !isWorking, let user = currentUser, !user.remoteAuthDeleted,
              let context = accountContainer?.mainContext else {
            throw AccountError.storageUnavailable
        }
        edit(user)
        user.profileNeedsUpload = true
        user.profileRevision += 1
        do { try context.save() } catch { context.rollback(); throw error }
        objectWillChange.send()
        refreshProfile()
    }

    func refreshProfile() {
        guard !isWorking, let user = currentUser, !user.remoteAuthDeleted, let id = user.identity else { return }
        let previous = syncTask
        previous?.cancel()
        let request = UUID()
        syncRequest = request
        syncTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.currentAccountIdentity == id else { return }
            self.syncState = "Syncing account details"
            let revision = user.profileRevision
            do {
                let owner = try await self.cloud.accountID()
                if let bound = user.cloudAccountRecordName, bound != owner { throw AccountError.differentCloudAccount }
                let remote = try await self.cloud.fetch(identity: id, ownerID: owner)
                try Task.checkCancellation()
                guard self.syncRequest == request, self.currentAccountIdentity == id, user.profileRevision == revision else { return }
                // A missing previously-synced record means another device deleted the account.
                if remote == nil, user.cloudAccountRecordName != nil { throw AccountError.accountRemoved }
                if let remote, !user.profileNeedsUpload {
                    user.displayName = remote.name
                    user.email = remote.email
                    user.profileImageData = remote.imageData
                } else {
                    try await self.cloud.save(user.accountProfile, identity: id, ownerID: owner)
                }
                try Task.checkCancellation()
                guard self.syncRequest == request, self.currentAccountIdentity == id, user.profileRevision == revision else { return }
                user.cloudAccountRecordName = owner
                user.profileNeedsUpload = false
                try self.accountContainer?.mainContext.save()
                self.syncState = "Account details synced with iCloud"
                self.errorMessage = nil
                self.objectWillChange.send()
            } catch is CancellationError { return }
            catch {
                guard self.syncRequest == request, self.currentAccountIdentity == id else { return }
                self.accountContainer?.mainContext.rollback()
                self.syncState = "Account details saved on this device"
                self.errorMessage = error.localizedDescription
                if error as? AccountError == .accountRemoved {
                    do {
                        try self.auth.forgetEmailSession(id)
                        try self.auth.signOutLocal()
                        self.status = .signedOut
                        self.accountContainer?.mainContext.delete(user)
                        try self.accountContainer?.mainContext.save()
                        self.reloadAccounts()
                    } catch { self.errorMessage = error.localizedDescription; return }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func waitForProfileSync() async { await syncTask?.value }

    func deleteCurrentAccount() async throws {
        guard !isWorking, let user = currentUser, let id = user.identity,
              let context = accountContainer?.mainContext else { throw AccountError.storageUnavailable }
        isWorking = true
        defer { isWorking = false }
        bootstrapTask?.cancel()
        syncRequest = UUID()
        syncTask?.cancel()
        // Drain an in-flight upload before deletion so it cannot recreate the record afterwards.
        await syncTask?.value
        auth.cancelAccountConnection(for: id)
        let owner = try await cloud.accountID()
        if let bound = user.cloudAccountRecordName, bound != owner { throw AccountError.differentCloudAccount }
        if !user.remoteAuthDeleted {
            switch id {
            case .email: try await auth.deleteEmailAccount(id)
            case .apple: try await auth.deleteApplePublishingOwner(id)
            }
            // Retain a durable cleanup state if iCloud becomes unavailable after Supabase deletion.
            user.remoteAuthDeleted = true
            try context.save()
            status = .deletionPending(user)
            syncState = "Account deletion needs iCloud cleanup"
        }
        try await cloud.delete(identity: id, ownerID: owner)
        try auth.forgetEmailSession(id)
        try auth.forgetPublishingSession(id)
        try auth.signOutLocal()
        for account in savedAccounts where account.identity == id { context.delete(account) }
        do { try context.save() } catch { context.rollback(); status = .signedOut; throw error }
        status = .signedOut
        hasBootstrapped = true
        syncState = ""
        errorMessage = nil
        reloadAccounts()
    }
}
