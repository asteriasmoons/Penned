//
//  AuthService.swift
//  Penned
//

import Foundation
import AuthenticationServices
import SwiftData

@MainActor
protocol AccountSessionStoring {
    func currentIdentity() throws -> AccountIdentity?
    func setCurrentIdentity(_ identity: AccountIdentity) throws
    func clear() throws
}

@MainActor
final class KeychainAccountSessionStore: AccountSessionStoring {
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    func currentIdentity() throws -> AccountIdentity? {
        if let stored = try KeychainHelper.read(.currentAccountIdentity) {
            guard let data = stored.data(using: .utf8) else { throw AccountError.keychainUnavailable }
            return try JSONDecoder().decode(AccountIdentity.self, from: data)
        }
        guard let legacy = try KeychainHelper.read(.currentAppleUserID) ?? preferences.string(forKey: "auth.currentAppleUserId"),
              !legacy.isEmpty else { return nil }
        let identity = AccountIdentity.apple(legacy)
        try setCurrentIdentity(identity)
        return identity
    }

    func setCurrentIdentity(_ identity: AccountIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        guard let value = String(data: data, encoding: .utf8),
              KeychainHelper.save(value, for: .currentAccountIdentity) else { throw AccountError.keychainUnavailable }
        // Remove the legacy key only after the provider-aware pointer is durable.
        guard KeychainHelper.delete(.currentAppleUserID) else { throw AccountError.keychainUnavailable }
        clearLegacySession()
    }

    func clear() throws {
        guard KeychainHelper.delete(.currentAppleUserID), KeychainHelper.delete(.currentAccountIdentity) else {
            throw AccountError.keychainUnavailable
        }
        KeychainHelper.clearAll()
        clearLegacySession()
    }

    private func clearLegacySession() {
        for key in ["auth.currentAppleUserId", "auth.currentEmail", "auth.currentDisplayName", "auth.currentProvider"] {
            preferences.removeObject(forKey: key)
        }
    }
}

struct AppleAccountIdentity {
    let userID: String
    var email: String?
    var displayName: String?
}

@MainActor
final class AuthService {
    static let shared = AuthService()
    private let session: any AccountSessionStoring
    private let credentialState: (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState
    private let email: any EmailAuthenticating
    private let publishingApple: PublishingAppleAuth
    private let publishingOwnerDeletion: ((AccountIdentity) async throws -> Void)?

    init(session: (any AccountSessionStoring)? = nil,
         email: (any EmailAuthenticating)? = nil,
         publishingOwnerDeletion: ((AccountIdentity) async throws -> Void)? = nil,
         publishingApple: PublishingAppleAuth? = nil,
         credentialState: @escaping (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState = {
             try await ASAuthorizationAppleIDProvider().credentialState(forUserID: $0)
         }) {
        self.session = session ?? KeychainAccountSessionStore()
        self.email = email ?? SupabaseEmailAuth()
        self.publishingOwnerDeletion = publishingOwnerDeletion
        self.publishingApple = publishingApple ?? PublishingAppleAuth()
        self.credentialState = credentialState
    }

    enum AuthServiceError: LocalizedError, Equatable {
        case notSignedIn
        case invalidCredential
        case credentialRevoked
        case credentialNotFound
        case failedToSaveUser
        case unsupportedCredentialState

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "No signed-in account was found."
            case .invalidCredential:
                return "Apple Sign In returned an invalid credential."
            case .credentialRevoked:
                return "Your Apple Sign In session was revoked. Please sign in again."
            case .credentialNotFound:
                return "Your Apple Sign In session could not be found. Please sign in again."
            case .failedToSaveUser:
                return "Your account could not be saved locally."
            case .unsupportedCredentialState:
                return "Your Apple Sign In credential is in an unsupported state. Please sign in again."
            }
        }
    }

    // MARK: - Public API

    func signInWithApple(
        credential: ASAuthorizationAppleIDCredential,
        existingUsers: [AuthUser],
        modelContext: ModelContext,
        nonce: PublishingAppleNonce? = nil
    ) throws -> AuthUser {
        if let nonce, let token = credential.identityToken {
            try publishingApple.stage(identity: .apple(credential.user), identityToken: token, nonce: nonce)
        }
        let fullNameParts = [
            credential.fullName?.givenName,
            credential.fullName?.familyName
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }

        let resolvedDisplayName: String? =
            fullNameParts.isEmpty ? nil : fullNameParts.joined(separator: " ")

        return try signIn(identity: AppleAccountIdentity(userID: credential.user, email: credential.email,
            displayName: resolvedDisplayName), existingUsers: existingUsers, modelContext: modelContext)
    }

    func signIn(identity: AppleAccountIdentity, existingUsers: [AuthUser], modelContext: ModelContext) throws -> AuthUser {
        let appleUserID = identity.userID
        guard !appleUserID.isEmpty else { throw AuthServiceError.invalidCredential }

        let matchingExisting = existingUsers.first { candidate in
            candidate.identity == .apple(appleUserID)
        }

        let signedInUser: AuthUser
        if let existing = matchingExisting {
            if existing.email?.isEmpty != false { existing.email = identity.email }
            if existing.displayName?.isEmpty != false { existing.displayName = identity.displayName }
            existing.appleUserId = appleUserID
            existing.authProvider = .apple
            if let email = identity.email { existing.authenticationEmail = email }
            signedInUser = existing
        } else {
            let newUser = AuthUser(
                email: identity.email,
                displayName: identity.displayName,
                authProvider: .apple,
                appleUserId: appleUserID,
                googleUserId: nil,
                serverId: nil
            )
            modelContext.insert(newUser)
            newUser.authenticationEmail = identity.email
            signedInUser = newUser
        }

        let duplicateUsers = existingUsers.filter {
            $0 !== signedInUser && $0.identity == .apple(appleUserID)
        }

        for duplicate in duplicateUsers {
            modelContext.delete(duplicate)
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw AuthServiceError.failedToSaveUser
        }

        try session.setCurrentIdentity(.apple(appleUserID))

        return signedInUser
    }

    func validateStoredAppleSession() async throws {
        guard case .apple(let appleUserId) = try session.currentIdentity() else {
            throw AuthServiceError.notSignedIn
        }

        try await validateAppleCredentialState(for: appleUserId)
    }

    func fetchMeWithAutoRefresh(modelContext: ModelContext) async throws -> AuthUser {
        guard let identity = try session.currentIdentity() else {
            throw AuthServiceError.notSignedIn
        }

        guard let user = try modelContext.fetch(FetchDescriptor<AuthUser>()).first(where: { $0.identity == identity }) else {
            throw AuthServiceError.notSignedIn
        }
        if !user.remoteAuthDeleted { try await validate(user, clearSessionOnRevocation: true) }
        try Task.checkCancellation()
        return user
    }

    func activate(_ user: AuthUser) async throws {
        guard let identity = user.identity else { throw AuthServiceError.invalidCredential }
        if let previous = try session.currentIdentity(), previous != identity { publishingApple.cancelPendingConnection(for: previous) }
        if !user.remoteAuthDeleted { try await validate(user, clearSessionOnRevocation: false) }
        try Task.checkCancellation()
        try session.setCurrentIdentity(identity)
    }

    func signOutLocal() throws {
        try session.clear()
    }

    func signOutActive() async throws {
        guard let identity = try session.currentIdentity() else { return }
        publishingApple.cancelPendingConnection(for: identity)
        if case .email = identity { try await email.signOut(identity) }
        if case .apple = identity { try? await publishingApple.signOut(identity) }
        if try session.currentIdentity() == identity { try session.clear() }
    }

    func authorizePublishing(credential: ASAuthorizationAppleIDCredential, nonce: PublishingAppleNonce) async throws {
        let identity = AccountIdentity.apple(credential.user)
        guard try session.currentIdentity() == identity, let token = credential.identityToken else { throw PublishingFailure.appleAuthorizationRequired }
        try await publishingApple.authorize(identity: identity, identityToken: token, nonce: nonce)
        guard try session.currentIdentity() == identity else {
            try publishingApple.forget(identity)
            throw CancellationError()
        }
    }

    func publishingAccessToken(for identity: AccountIdentity) async throws -> String {
        guard try session.currentIdentity() == identity else { throw PublishingFailure.authenticationRequired }
        let token: String
        switch identity {
        case .apple(let subject):
            try await validateAppleCredentialState(for: subject)
            token = try await publishingApple.accessToken(for: identity)
        case .email: token = try await email.publishingAccessToken(identity)
        }
        guard try session.currentIdentity() == identity else { throw CancellationError() }
        return token
    }

    func cancelAccountConnection(for identity: AccountIdentity) { publishingApple.cancelPendingConnection(for: identity) }

    func deleteApplePublishingOwner(_ identity: AccountIdentity) async throws {
        guard case .apple = identity, try session.currentIdentity() == identity else { throw PublishingFailure.authenticationRequired }
        if let publishingOwnerDeletion { try await publishingOwnerDeletion(identity); return }
        let token = try await publishingAccessToken(for: identity)
        let client = PublishingClient(configuration: try .load())
        try await client.revokeOwner(token: token)
    }

    func forgetPublishingSession(_ identity: AccountIdentity) throws {
        try publishingApple.forget(identity)
    }

    func requestEmailCode(_ address: String, attempt: UUID) async throws -> String {
        let address = try AccountValidation.email(address).lowercased()
        try await email.sendCode(email: address, attempt: attempt)
        try Task.checkCancellation()
        return address
    }

    func cancelEmailSignIn(attempt: UUID) { email.cancel(attempt: attempt) }

    func verifyEmailCode(_ address: String, code: String, attempt: UUID, modelContext: ModelContext) async throws -> AuthUser {
        let address = try AccountValidation.email(address).lowercased()
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...10).contains(code.count), code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw EmailAuthError.invalidCode }
        let verified = try await email.verifyCode(email: address, code: code, attempt: attempt)
        try Task.checkCancellation()
        guard case .email(let project, let id) = verified.identity,
              verified.email.lowercased() == address else { throw EmailAuthError.unexpectedResponse }
        let users = try modelContext.fetch(FetchDescriptor<AuthUser>())
        let user: AuthUser
        if let existing = users.first(where: { $0.identity == verified.identity }) {
            user = existing
            user.authenticationEmail = verified.email
            if user.email == nil { user.email = verified.email }
        } else {
            user = AuthUser(email: verified.email, authProvider: .email)
            user.supabaseUserID = id.uuidString.lowercased()
            user.supabaseProjectURL = project
            user.authenticationEmail = verified.email
            modelContext.insert(user)
        }
        do { try modelContext.save() } catch { modelContext.rollback(); throw AuthServiceError.failedToSaveUser }
        try session.setCurrentIdentity(verified.identity)
        return user
    }

    func deleteEmailAccount(_ identity: AccountIdentity) async throws { try await email.deleteAccount(identity) }
    func forgetEmailSession(_ identity: AccountIdentity) throws {
        if case .email = identity { try email.forget(identity) }
    }

    private func validate(_ user: AuthUser, clearSessionOnRevocation: Bool) async throws {
        guard let identity = user.identity else { throw AuthServiceError.invalidCredential }
        switch identity {
        case .apple(let id): try await validateAppleCredentialState(for: id, clearSessionOnRevocation: clearSessionOnRevocation)
        case .email:
            do {
                let verified = try await email.restore(identity)
                try Task.checkCancellation()
                guard verified.identity == identity else { throw EmailAuthError.unexpectedResponse }
                user.authenticationEmail = verified.email
                try user.modelContext?.save()
            } catch EmailAuthError.sessionExpired {
                try email.forget(identity)
                if clearSessionOnRevocation, try session.currentIdentity() == identity { try session.clear() }
                throw EmailAuthError.sessionExpired
            }
        }
    }

    // MARK: - Private

    private func validateAppleCredentialState(for appleUserId: String, clearSessionOnRevocation: Bool = true) async throws {
        let credentialState = try await credentialState(appleUserId)
        try Task.checkCancellation()
        var mayClearSession = false
        if clearSessionOnRevocation {
            mayClearSession = try session.currentIdentity() == .apple(appleUserId)
        }

        switch credentialState {
        case .authorized:
            return

        case .revoked:
            if mayClearSession { try signOutLocal() }
            throw AuthServiceError.credentialRevoked

        case .notFound, .transferred:
            if mayClearSession { try signOutLocal() }
            throw AuthServiceError.credentialNotFound

        @unknown default:
            if mayClearSession { try signOutLocal() }
            throw AuthServiceError.unsupportedCredentialState
        }
    }

}
