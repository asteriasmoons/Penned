//
//  AppState.swift
//  Penned
//

import Foundation
import Combine
import SwiftData
import AuthenticationServices
#if os(iOS)
import UIKit
#endif

@MainActor
final class AppState: ObservableObject {
    
    enum SessionStatus {
        case checking
        case signedOut
        case signedIn(AuthUser)
        case deletionPending(AuthUser)
    }
    
    let railwayAccount = RailwayNativeAccountBinding()
    private let cloudAuthenticationEnabled:Bool
    private var cloudAuthenticationTask:Task<Void,Never>?
    private var cloudAuthenticationOwner:String?
    private var pendingCloudAppleProof:PennedCloudAppleProof?
    private var cloudApplePromptAttempted=false
    private var cloudForeground=false

    @Published private(set) var status: SessionStatus = .checking {
        didSet {
            let selected:String?
            if case .signedIn(let user)=status,!user.remoteAuthDeleted {selected=user.identity?.libraryOwnerKey}
            else{selected=nil}
            if cloudAuthenticationOwner != selected {
                cloudAuthenticationTask?.cancel();cloudAuthenticationTask=nil
                cloudAuthenticationOwner=selected;cloudApplePromptAttempted=false
                if pendingCloudAppleProof?.ownerKey != selected{pendingCloudAppleProof=nil}
            }
            railwayAccount.select(ownerKey:selected)
            startCloudAuthentication()
            #if os(iOS)
            func owner(_ value: SessionStatus) -> AccountIdentity? {
                if case .signedIn(let user) = value, !user.remoteAuthDeleted { return user.identity }
                return nil
            }
            if owner(oldValue) != owner(status) { try? ClipperShared.disconnect() }
            #endif
        }
    }
    @Published var isPopupPresented: Bool = false
    @Published var hideTabBar: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var isWorking = false {
        didSet {
            #if os(iOS)
            if isWorking { try? ClipperShared.disconnect() }
            #endif
        }
    }
    @Published private(set) var syncState = ""
    @Published private(set) var savedAccounts: [AuthUser] = []
    private(set) var accountContainer: ModelContainer?
    private let auth: AuthService
    private let cloud: any AccountCloudStoring
    private var syncTask: Task<Void, Never>?
    private var syncRequest = UUID()

    private var needsInitialStorage = false

    init(container: ModelContainer? = nil, auth: AuthService? = nil,
         cloud: (any AccountCloudStoring)? = nil, deferStorageOpen: Bool = false) {
        cloudAuthenticationEnabled = container == nil && auth == nil && cloud == nil
        self.auth = auth ?? .shared
        self.cloud = cloud ?? AccountCloudStore()
        if deferStorageOpen && container == nil {
            needsInitialStorage = true
            return
        }
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
    private var bootstrapRequest = UUID()
    private var hasBootstrapped = false
    private var validationTask: Task<Void, Never>?
    
    @discardableResult
    func bootstrap(force: Bool = false) -> Task<Void, Never>? {
        guard !isWorking else { return nil }
        if let bootstrapTask, !bootstrapTask.isCancelled { return bootstrapTask }
        if hasBootstrapped && !force { return nil }
        guard accountContainer != nil || needsInitialStorage else { return nil }

        let request = UUID()
        bootstrapRequest = request
        if currentUser == nil { status = .checking }
        hasBootstrapped = true

        bootstrapTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer { if self.bootstrapRequest == request { self.bootstrapTask = nil } }
            let openedInitialStorage = self.needsInitialStorage
            if openedInitialStorage {
                let started = PennedDiagnostics.markStartup("account-store.start")
                do {
                    let container = try await Task.detached(priority: .userInitiated) {
                        try AccountPersistence.makeContainer()
                    }.value
                    try Task.checkCancellation()
                    self.accountContainer = container
                    self.needsInitialStorage = false
                } catch is CancellationError {
                    return
                } catch {
                    self.needsInitialStorage = false
                    self.errorMessage = AccountError.storageUnavailable.localizedDescription
                    self.status = .signedOut
                    _ = PennedDiagnostics.markStartup("account-store.failed", since: started)
                    return
                }
                _ = PennedDiagnostics.markStartup("account-store.ready", since: started)
            }
            guard let modelContext = self.accountContainer?.mainContext else { return }
            let started = PennedDiagnostics.markStartup("account-validation.start")

            do {
                // Mount the library from the locally-stored session immediately.
                // Remote verification (Supabase token refresh / Apple credential
                // state) is a network round-trip that previously held the loading
                // screen for the full network timeout when the backend was slow or
                // unreachable. It now runs in the background in startSessionValidation,
                // which signs out only on a genuine revocation/expiry — never on a
                // transient network failure.
                let user = try self.auth.restoreLocalUser(modelContext: modelContext)
                guard !Task.isCancelled else { return }
                _ = PennedDiagnostics.markStartup("account-validation.local", since: started)
                self.setSignedIn(user)
                self.startSessionValidation(for: user, started: started)
            } catch {
                _ = PennedDiagnostics.markStartup("account-validation.finished", since: started)
                guard !Task.isCancelled else { return }
                if openedInitialStorage { self.reloadAccounts() }
                if let authError = error as? AuthService.AuthServiceError {
                    self.status = .signedOut
                    self.syncRequest = UUID(); self.syncTask?.cancel(); self.syncState = ""
                    if authError == .notSignedIn { return }
                } else if self.currentUser == nil { self.status = .signedOut }
                self.errorMessage = error.localizedDescription
            }
        }
        return bootstrapTask
    }

    private func startSessionValidation(for user: AuthUser, started: TimeInterval) {
        let identity = user.identity
        validationTask?.cancel()
        validationTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { _ = PennedDiagnostics.markStartup("account-validation.finished", since: started) }
            do {
                try await self.auth.validateActiveSession(user)
            } catch is CancellationError {
                return
            } catch {
                // Only a genuine revocation/expiry signs the account out. A
                // transient network failure surfaces as EmailAuthError.network
                // (or a raw URLError) and leaves the optimistic session in place,
                // so a slow or offline backend never forces a sign-out at launch.
                guard !Task.isCancelled, self.currentUser?.identity == identity else { return }
                let revoked = error is AuthService.AuthServiceError || (error as? EmailAuthError) == .sessionExpired
                guard revoked else { return }
                self.status = .signedOut
                self.syncRequest = UUID(); self.syncTask?.cancel(); self.syncState = ""
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func setSignedIn(_ user: AuthUser) {
        bootstrapTask?.cancel()
        validationTask?.cancel()
        syncRequest = UUID(); syncTask?.cancel()
        hasBootstrapped = true
        status = user.remoteAuthDeleted ? .deletionPending(user) : .signedIn(user)
        errorMessage = nil
        reloadAccounts()
        refreshProfile()
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential, existingUsers: [AuthUser], modelContext: ModelContext, nonce: PublishingAppleNonce? = nil, cloudChallenge:RailwayAppleChallenge?=nil) throws {
        let user = try auth.signInWithApple(credential: credential, existingUsers: existingUsers, modelContext: modelContext, nonce: nonce)
        if let cloudChallenge,let token=credential.identityToken,nonce?.rawValue==cloudChallenge.nonce {
            pendingCloudAppleProof = .init(ownerKey:"apple:"+credential.user,challenge:cloudChallenge,token:token,createdAt:Date())
        }
        setSignedIn(user)
    }

    // Called at scene activation. Local account restoration and library opening
    // never await this task. Each selected account gets its own lifecycle.
    func setCloudForeground(_ active:Bool) {
        cloudForeground=active
        startCloudAuthentication()
    }

    private func startCloudAuthentication() {
        guard cloudAuthenticationEnabled,cloudAuthenticationTask==nil,let owner=cloudAuthenticationOwner else{return}
        cloudAuthenticationTask=Task(priority:.utility){[weak self] in
            while !Task.isCancelled{
                guard let self,self.cloudAuthenticationOwner==owner else{return}
                if !self.isWorking{
                    do{try await self.establishCloudSession(owner:owner)}
                    catch is CancellationError{}
                    catch{/* Local account and queued edits remain available. */}
                }
                do{try await Task.sleep(for:.seconds(30))}catch{return}
            }
        }
    }

    private func establishCloudSession(owner:String)async throws {
        guard !Task.isCancelled,cloudAuthenticationOwner==owner,
              let identity=currentAccountIdentity,identity.libraryOwnerKey==owner,
              currentUser?.remoteAuthDeleted==false else{throw CancellationError()}
        if try await railwayAccount.restoreOnline(){
            cloudApplePromptAttempted=false;pendingCloudAppleProof=nil;return
        }
        let client=try railwayAccount.client()
        #if os(macOS)
        let platform="macos"
        #else
        let platform=await MainActor.run {UIDevice.current.userInterfaceIdiom == .pad ? "ipados":"ios"}
        #endif
        let device=RailwayDevice(name:nil,platform:platform)
        switch identity {
        case .email:
            let token=try await auth.publishingAccessToken(for:identity)
            guard !Task.isCancelled,!isWorking,cloudAuthenticationOwner==owner,currentAccountIdentity==identity else{throw CancellationError()}
            _ = try await client.signInSupabase(accessToken:token,device:device,expectedOwner:owner)
        case .apple(let subject):
            if pendingCloudAppleProof?.isFresh != true {pendingCloudAppleProof=nil}
            if pendingCloudAppleProof==nil {
                guard cloudForeground,!cloudApplePromptAttempted,PennedCloudAppleAuthorization.activeAnchor != nil else{return}
                let challenge=try await client.appleChallenge()
                guard !Task.isCancelled,!isWorking,cloudAuthenticationOwner==owner,currentAccountIdentity==identity,cloudForeground else{throw CancellationError()}
                cloudApplePromptAttempted=true
                let token=try await PennedCloudAppleAuthorization().authorize(subject:subject,challenge:challenge)
                guard !Task.isCancelled,cloudAuthenticationOwner==owner,currentAccountIdentity==identity else{throw CancellationError()}
                pendingCloudAppleProof = .init(ownerKey:owner,challenge:challenge,token:token,createdAt:Date())
            }
            guard let proof=pendingCloudAppleProof,proof.ownerKey==owner,proof.isFresh,
                  !isWorking,!Task.isCancelled,cloudAuthenticationOwner==owner else{throw CancellationError()}
            do{
                _ = try await client.signInApple(identityToken:proof.token,challenge:proof.challenge,device:device,expectedOwner:owner)
                pendingCloudAppleProof=nil
            }catch RailwayError.http(401,_,_){pendingCloudAppleProof=nil;throw RailwayError.signedOut}
        }
        guard !Task.isCancelled,cloudAuthenticationOwner==owner,currentAccountIdentity==identity else{throw CancellationError()}
        _ = try await railwayAccount.verify(client,ownerKey:owner)
        cloudApplePromptAttempted=false
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
        #if os(iOS)
        try? ClipperShared.disconnect()
        #endif
        isWorking = true
        defer { isWorking = false;startCloudAuthentication() }
        cloudAuthenticationTask?.cancel();cloudAuthenticationTask=nil;pendingCloudAppleProof=nil
        bootstrapTask?.cancel()
        syncRequest = UUID()
        syncTask?.cancel()
        do {
            try await auth.signOutActive()
            // Do not block legacy sign-out on a Railway network failure. The
            // device revocation is retained in the account-specific keychain.
            try? await railwayAccount.disconnect()
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
        #if os(iOS)
        try? ClipperShared.disconnect()
        #endif
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
