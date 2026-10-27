import Foundation
import CryptoKit
import Security
import Supabase

nonisolated struct PublishingAppleNonce: Codable {
    let rawValue: String
    var hashedValue: String { SHA256.hash(data: Data(rawValue.utf8)).map { String(format: "%02x", $0) }.joined() }
    init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PublishingFailure.unavailable("Secure randomness is unavailable.") }
        rawValue = bytes.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class PublishingAppleAuth {
    nonisolated private struct StoredSession: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: String
        var subject: String
    }
    nonisolated private struct PendingSession: Codable {
        var identityToken: Data
        var nonce: PublishingAppleNonce
        var createdAt: Date
    }
    private let configuration: () throws -> SupabaseConfiguration
    private let storageFactory: (String) -> any AuthLocalStorage
    private let session: URLSession
    private struct Refresh {
        let id: UUID
        let task: Task<String, Error>
    }
    private var refreshes: [AccountIdentity: Refresh] = [:]
    private var generations: [AccountIdentity: UUID] = [:]

    init(configuration: (() throws -> SupabaseConfiguration)? = nil,
         storageFactory: @escaping (String) -> any AuthLocalStorage = { PennedAuthKeychainStorage(service: $0) }, session: URLSession = .shared) {
        self.configuration = configuration ?? { try .load() }
        self.storageFactory = storageFactory
        self.session = session
    }

    private func storage(_ identity: AccountIdentity) throws -> any AuthLocalStorage {
        let project = try configuration().projectID
        let digest = SHA256.hash(data: Data((project + "|" + identity.cloudIdentity).utf8)).map { String(format: "%02x", $0) }.joined()
        return storageFactory("com.penned.publishing.apple." + digest)
    }

    func authorize(identity: AccountIdentity, identityToken: Data, nonce: PublishingAppleNonce) async throws {
        guard case .apple(let subject) = identity, let token = String(data: identityToken, encoding: .utf8) else { throw PublishingFailure.appleAuthorizationRequired }
        let generation = UUID(); generations[identity] = generation
        refreshes.removeValue(forKey: identity)?.task.cancel()
        let client = PublishingClient(configuration: try configuration(), session: session)
        let result: StoredSession = try await client.request(path: "auth/apple", method: "POST", body: JSONEncoder().encode(["identityToken": token, "nonce": nonce.rawValue]))
        guard generations[identity] == generation, !Task.isCancelled, result.subject == subject else { throw CancellationError() }
        try storage(identity).store(key: "session", value: JSONEncoder().encode(result))
        try storage(identity).remove(key: "pending")
    }

    func stage(identity: AccountIdentity, identityToken: Data, nonce: PublishingAppleNonce) throws {
        guard case .apple = identity, !identityToken.isEmpty else { throw PublishingFailure.appleAuthorizationRequired }
        try storage(identity).store(key: "pending", value: JSONEncoder().encode(PendingSession(identityToken: identityToken, nonce: nonce, createdAt: Date())))
        generations[identity] = UUID()
        refreshes.removeValue(forKey: identity)?.task.cancel()
    }

    func accessToken(for identity: AccountIdentity) async throws -> String {
        guard case .apple(let subject) = identity else { throw PublishingFailure.authenticationRequired }
        if let existing = refreshes[identity] { return try await existing.task.value }
        let store = try storage(identity)
        let stored = try store.retrieve(key: "session").flatMap { try? JSONDecoder().decode(StoredSession.self, from: $0) }
        let pending = try store.retrieve(key: "pending").flatMap { try? JSONDecoder().decode(PendingSession.self, from: $0) }
        guard stored == nil || stored?.subject == subject else { throw PublishingFailure.appleAuthorizationRequired }
        let freshPending = pending.flatMap { Date().timeIntervalSince($0.createdAt) < 300 ? $0 : nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if freshPending == nil, let stored,
           let expiry = formatter.date(from: stored.expiresAt) ?? ISO8601DateFormatter().date(from: stored.expiresAt),
           expiry.timeIntervalSinceNow > 60 { return stored.accessToken }
        guard stored != nil || freshPending != nil else { throw PublishingFailure.appleAuthorizationRequired }
        let generation = generations[identity] ?? UUID(); generations[identity] = generation
        let refreshID = UUID()
        let task = Task { @MainActor in
            let client = PublishingClient(configuration: try self.configuration(), session: self.session)
            let result: StoredSession
            if freshPending == nil, let stored {
                result = try await client.request(path: "auth/refresh", method: "POST", body: JSONEncoder().encode(["refreshToken": stored.refreshToken]))
            } else {
                guard let freshPending else { throw PublishingFailure.appleAuthorizationRequired }
                try Task.checkCancellation()
                result = try await self.exchange(client: client, token: freshPending.identityToken, nonce: freshPending.nonce)
            }
            guard self.generations[identity] == generation, !Task.isCancelled, result.subject == subject else { throw CancellationError() }
            try self.storage(identity).store(key: "session", value: JSONEncoder().encode(result))
            try self.storage(identity).remove(key: "pending")
            return result.accessToken
        }
        refreshes[identity] = Refresh(id: refreshID, task: task)
        defer { if refreshes[identity]?.id == refreshID { refreshes[identity] = nil } }
        return try await task.value
    }

    private func exchange(client: PublishingClient, token: Data, nonce: PublishingAppleNonce) async throws -> StoredSession {
        guard let value = String(data: token, encoding: .utf8) else { throw PublishingFailure.appleAuthorizationRequired }
        return try await client.request(path: "auth/apple", method: "POST", body: JSONEncoder().encode(["identityToken": value, "nonce": nonce.rawValue]))
    }

    func cancelPendingConnection(for identity: AccountIdentity) {
        generations[identity] = UUID()
        refreshes.removeValue(forKey: identity)?.task.cancel()
    }

    func forget(_ identity: AccountIdentity) throws {
        guard case .apple = identity else { return }
        cancelPendingConnection(for: identity)
        do { try storage(identity).remove(key: "session"); try storage(identity).remove(key: "pending") }
        catch EmailAuthError.configurationMissing { return }
    }

    func signOut(_ identity: AccountIdentity) async throws {
        guard case .apple = identity else { return }
        if let data = try storage(identity).retrieve(key: "session"), let stored = try? JSONDecoder().decode(StoredSession.self, from: data) {
            let client = PublishingClient(configuration: try configuration(), session: session)
            let token = (try? await accessToken(for: identity)) ?? stored.accessToken
            let _: [String: Bool]? = try? await client.request(path: "auth/revoke", method: "DELETE", token: token)
        }
        try forget(identity)
    }
}
