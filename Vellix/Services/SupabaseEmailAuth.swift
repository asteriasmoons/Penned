import Foundation
import CryptoKit
import Security
import Supabase

private nonisolated struct EmailAccountDeletionResponse: Decodable {
    let deletedUserID: UUID
}

nonisolated final class EmailSessionMemoryStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) { lock.withLock { values[key] = value } }
    func retrieve(key: String) -> Data? { lock.withLock { values[key] } }
    func remove(key: String) { lock.withLock { values[key] = nil } }
}

// SDK migration probes read/delete absent keys. Normalize only errSecItemNotFound;
// its KeychainLocalStorage throws for that status as well as actual access failures.
nonisolated struct PennedAuthKeychainStorage: AuthLocalStorage {
    private let service: String
    private let storage: any AuthLocalStorage
    private let copyMatching: @Sendable ([String: Any]) -> (OSStatus, Data?)
    private let deleteItem: @Sendable ([String: Any]) -> OSStatus

    init(service: String, storage: (any AuthLocalStorage)? = nil,
         copyMatching: @escaping @Sendable ([String: Any]) -> (OSStatus, Data?) = { query in
             var result: CFTypeRef?
             let status = SecItemCopyMatching(query as CFDictionary, &result)
             return (status, result as? Data)
         },
         deleteItem: @escaping @Sendable ([String: Any]) -> OSStatus = { query in
             SecItemDelete(query as CFDictionary)
         }) {
        self.service = service
        self.storage = storage ?? KeychainLocalStorage(service: service)
        self.copyMatching = copyMatching
        self.deleteItem = deleteItem
    }

    func store(key: String, value: Data) throws {
        try storage.store(key: key, value: value)
    }

    func retrieve(key: String) throws -> Data? {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else { throw AccountError.keychainUnavailable }
        return data
    }

    func remove(key: String) throws {
        let status = deleteItem(query(for: key))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccountError.keychainUnavailable
        }
    }

    private func query(for key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
}

// The SDK logs storage failures internally. Retain them so activation cannot report
// success after a failed secure write or mistake an inaccessible Keychain for logout.
nonisolated final class CheckedAuthStorage: AuthLocalStorage, @unchecked Sendable {
    let base: any AuthLocalStorage
    private let lock = NSLock()
    private var failed = false
    init(_ base: any AuthLocalStorage) { self.base = base }
    func store(key: String, value: Data) throws {
        do { try base.store(key: key, value: value) } catch { recordFailure(); throw error }
    }
    func retrieve(key: String) throws -> Data? {
        do { return try base.retrieve(key: key) } catch { recordFailure(); throw error }
    }
    func remove(key: String) throws {
        do { try base.remove(key: key) } catch { recordFailure(); throw error }
    }
    private func recordFailure() { lock.withLock { failed = true } }
    func check() throws {
        if lock.withLock({ failed }) { throw AccountError.keychainUnavailable }
    }
}

@MainActor
final class SupabaseEmailAuth: EmailAuthenticating {
    private struct Entry {
        let client: SupabaseClient
        let storage: CheckedAuthStorage
    }
    private struct Draft {
        let id = UUID()
        let email: String
        let configuration: SupabaseConfiguration
        let client: SupabaseClient
    }
    private let configuration: () throws -> SupabaseConfiguration
    private let storageFactory: (String) -> any AuthLocalStorage
    private let urlSession: URLSession
    private var clients: [AccountIdentity: Entry] = [:]
    private var drafts: [UUID: Draft] = [:]
    static let sessionKey = "penned.session"

    init(configuration: (() throws -> SupabaseConfiguration)? = nil,
         storageFactory: @escaping (String) -> any AuthLocalStorage = { PennedAuthKeychainStorage(service: $0) },
         urlSession: URLSession = .shared) {
        self.configuration = configuration ?? { try .load() }
        self.storageFactory = storageFactory
        self.urlSession = urlSession
    }

    static func storageNamespace(for identity: AccountIdentity) -> String {
        let hash = SHA256.hash(data: Data(identity.cloudIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "com.penned.supabase.\(hash)"
    }

    private func client(configuration: SupabaseConfiguration, storage: any AuthLocalStorage) -> SupabaseClient {
        SupabaseClient(supabaseURL: configuration.url, supabaseKey: configuration.publishableKey,
            options: .init(auth: .init(storage: storage, storageKey: Self.sessionKey,
                autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(session: urlSession, logger: nil)))
    }

    private func entry(for identity: AccountIdentity) throws -> Entry {
        let config = try configuration()
        guard case .email(let project, _) = identity, project == config.projectID else { throw EmailAuthError.wrongProject }
        if let existing = clients[identity] {
            if (try? existing.storage.check()) != nil { return existing }
            clients[identity] = nil
        }
        let storage = CheckedAuthStorage(storageFactory(Self.storageNamespace(for: identity)))
        let entry = Entry(client: client(configuration: config, storage: storage), storage: storage)
        clients[identity] = entry
        return entry
    }

    func sendCode(email: String, attempt: UUID) async throws {
        let config = try configuration()
        let draft: Draft
        if let existing = drafts[attempt], existing.email == email, existing.configuration == config { draft = existing }
        else {
            draft = Draft(email: email, configuration: config,
                client: client(configuration: config, storage: EmailSessionMemoryStorage()))
            drafts[attempt] = draft
        }
        do {
            try await draft.client.auth.signInWithOTP(email: email, shouldCreateUser: true)
            try Task.checkCancellation()
            guard drafts[attempt]?.id == draft.id else { throw CancellationError() }
        } catch { throw Self.translate(error, verification: false) }
    }

    func verifyCode(email: String, code: String, attempt: UUID) async throws -> VerifiedEmailAccount {
        guard let draft = drafts[attempt], draft.email == email else { throw EmailAuthError.codeNotRequested }
        do {
            let response = try await draft.client.auth.verifyOTP(email: email, token: code, type: .email)
            try Task.checkCancellation()
            guard drafts[attempt]?.id == draft.id else { throw CancellationError() }
            guard let session = response.session, let verifiedEmail = session.user.email,
                  session.user.emailConfirmedAt != nil, verifiedEmail.lowercased() == email.lowercased() else {
                throw EmailAuthError.unexpectedResponse
            }
            let identity = AccountIdentity.email(project: draft.configuration.projectID, userID: session.user.id)
            let account = try entry(for: identity)
            let stored = try await account.client.auth.setSession(accessToken: session.accessToken, refreshToken: session.refreshToken)
            try Task.checkCancellation()
            guard drafts[attempt]?.id == draft.id else { throw CancellationError() }
            try ensurePersisted(stored, entry: account, identity: identity)
            // The draft and stored session share server tokens. Discard, never sign out, the draft.
            drafts[attempt] = nil
            return VerifiedEmailAccount(identity: identity, email: verifiedEmail)
        } catch { throw Self.translate(error, verification: true) }
    }

    func cancel(attempt: UUID) { drafts[attempt] = nil }

    func restore(_ identity: AccountIdentity) async throws -> VerifiedEmailAccount {
        let account = try entry(for: identity)
        do {
            try account.storage.check()
            if let data = try account.storage.retrieve(key: Self.sessionKey) {
                guard (try? JSONDecoder().decode(Session.self, from: data)) != nil else { throw AccountError.keychainUnavailable }
            } else { throw EmailAuthError.sessionExpired }
            // session refreshes an expired access token, persisting rotated tokens through the SDK.
            let session = try await account.client.auth.session
            let user = try await account.client.auth.user(jwt: session.accessToken)
            try Task.checkCancellation()
            guard case .email(_, let id) = identity, user.id == id, user.emailConfirmedAt != nil,
                  let email = user.email else { throw EmailAuthError.sessionExpired }
            try ensurePersisted(session, entry: account, identity: identity)
            return VerifiedEmailAccount(identity: identity, email: email)
        } catch {
            do { try account.storage.check() } catch { clients[identity] = nil; throw error }
            throw Self.translate(error, verification: false)
        }
    }

    private func ensurePersisted(_ session: Session, entry: Entry, identity: AccountIdentity) throws {
        try entry.storage.check()
        guard case .email(_, let id) = identity, session.user.id == id,
              let bytes = try entry.storage.retrieve(key: Self.sessionKey),
              let saved = try? JSONDecoder().decode(Session.self, from: bytes),
              saved.user.id == id, saved.refreshToken == session.refreshToken,
              saved.accessToken == session.accessToken else { throw AccountError.keychainUnavailable }
    }

    func signOut(_ identity: AccountIdentity) async throws {
        let account: Entry
        do { account = try entry(for: identity) }
        catch EmailAuthError.configurationMissing { try forget(identity); return }
        catch EmailAuthError.wrongProject { try forget(identity); return }
        do {
            _ = try await account.client.auth.session
            try await account.client.auth.signOut(scope: .local)
        }
        catch {
            let mapped = Self.translate(error, verification: false)
            // Device logout must work offline. Remote session revocation is best effort then.
            if mapped as? EmailAuthError != .network, mapped as? EmailAuthError != .sessionExpired { throw mapped }
        }
        try forget(identity)
    }

    func forget(_ identity: AccountIdentity) throws {
        let storage = storageFactory(Self.storageNamespace(for: identity))
        for key in [Self.sessionKey, Self.sessionKey + "-code-verifier", "supabase.session", "supabase.auth.token"] {
            try storage.remove(key: key)
        }
        clients[identity] = nil
    }

    func deleteAccount(_ identity: AccountIdentity) async throws {
        _ = try await restore(identity)
        let account = try entry(for: identity)
        do {
            let session = try await account.client.auth.session
            let result: EmailAccountDeletionResponse = try await account.client.functions.invoke("penned-delete-account",
                options: .init(method: .post, headers: ["Authorization": "Bearer \(session.accessToken)"]))
            guard case .email(_, let id) = identity, result.deletedUserID == id else { throw EmailAuthError.deletionFailed }
        } catch let FunctionsError.httpError(code, _) where code == 404 { throw EmailAuthError.deletionUnavailable }
        catch let error as EmailAuthError { throw error }
        catch { throw EmailAuthError.deletionFailed }
    }

    static func translate(_ error: Error, verification: Bool) -> Error {
        if error is CancellationError { return error }
        if let url = error as? URLError { return url.code == .cancelled ? CancellationError() : EmailAuthError.network }
        guard let auth = error as? AuthError else { return error }
        switch auth {
        case .sessionMissing: return EmailAuthError.sessionExpired
        case .refreshDiscarded: return CancellationError()
        case .api(_, let code, _, let response):
            if response.statusCode == 429 { return EmailAuthError.rateLimited }
            if response.statusCode >= 500 { return EmailAuthError.network }
            switch code {
            case .otpExpired: return EmailAuthError.expiredCode
            case .overRequestRateLimit, .overEmailSendRateLimit: return EmailAuthError.rateLimited
            case .invalidCredentials, .validationFailed: return verification ? EmailAuthError.invalidCode : auth
            case .userNotFound, .userBanned, .badJWT, .invalidJWT, .sessionExpired,
                 .sessionNotFound, .refreshTokenNotFound, .refreshTokenAlreadyUsed: return EmailAuthError.sessionExpired
            default: return auth
            }
        default: return auth
        }
    }
}
