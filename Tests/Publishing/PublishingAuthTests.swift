import Foundation
import CryptoKit
import Supabase
import Testing
@testable import Vellix

@MainActor
private final class PublishingTestAccountSession: AccountSessionStoring {
    var identity: AccountIdentity?
    func currentIdentity() -> AccountIdentity? { identity }
    func setCurrentIdentity(_ identity: AccountIdentity) { self.identity = identity }
    func clear() { identity = nil }
}

private final class PublishingTestStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var fails = false
    func store(key: String, value: Data) throws {
        try lock.withLock {
            if fails { throw PublishingFailure.unavailable("Keychain test failure") }
            values[key] = value
        }
    }
    func retrieve(key: String) -> Data? { lock.withLock { values[key] } }
    func remove(key: String) { lock.withLock { values[key] = nil } }
}

private final class PublishingAuthProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var schedule: ((URLRequest, @escaping (Int, Data) -> Void) -> Void)?
    private let lock = NSLock()
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "publishing-auth.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let schedule = Self.schedule {
            schedule(request) { [weak self] status, data in self?.complete(status, data) }
            return
        }
        do {
            guard let respond = Self.respond else { throw URLError(.unsupportedURL) }
            let (status, data) = try respond(request)
            complete(status, data)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func complete(_ status: Int, _ data: Data) {
        guard !lock.withLock({ cancelled }) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { lock.withLock { cancelled = true } }
}

@Suite(.serialized) @MainActor
struct PublishingAuthTests {
    private func fixture(storage: PublishingTestStorage) throws -> PublishingAppleAuth {
        let configuration = try SupabaseConfiguration(values: ["SUPABASE_URL": "https://publishing-auth.example.com", "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_fixture"])
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [PublishingAuthProtocol.self]
        return PublishingAppleAuth(configuration: { configuration }, storageFactory: { _ in storage }, session: URLSession(configuration: options))
    }

    private func response(subject: String, expired: Bool = false) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONSerialization.data(withJSONObject: ["accessToken": "ppa_" + String(repeating: "a", count: 64), "refreshToken": "ppr_" + String(repeating: "b", count: 64), "subject": subject,
            "expiresAt": formatter.string(from: Date().addingTimeInterval(expired ? -60 : 900))])
    }

    @Test func secureNonceAndSubjectBoundSessionSurviveServiceRecreation() async throws {
        let nonce = try PublishingAppleNonce()
        #expect(nonce.rawValue.count == 64)
        #expect(nonce.hashedValue == SHA256.hash(data: Data(nonce.rawValue.utf8)).map { String(format: "%02x", $0) }.joined())
        #expect(nonce.rawValue != (try PublishingAppleNonce()).rawValue)
        let data = try response(subject: "apple-owner")
        PublishingAuthProtocol.respond = { request in
            #expect(request.url?.path == "/functions/v1/penned-publishing/auth/apple")
            #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_fixture")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, data)
        }
        defer { PublishingAuthProtocol.respond = nil }
        let storage = PublishingTestStorage(), identity = AccountIdentity.apple("apple-owner")
        try await fixture(storage: storage).authorize(identity: identity, identityToken: Data("apple-token".utf8), nonce: nonce)
        let restored = try fixture(storage: storage)
        #expect(try await restored.accessToken(for: identity) == "ppa_" + String(repeating: "a", count: 64))
        await #expect(throws: (any Error).self) { try await restored.accessToken(for: .apple("other-owner")) }
        try restored.forget(identity)
        await #expect(throws: (any Error).self) { try await restored.accessToken(for: identity) }
    }

    @Test func wrongSubjectAndFailedSecureWritesNeverAuthorizePublishing() async throws {
        let storage = PublishingTestStorage(), identity = AccountIdentity.apple("owner")
        var data = try response(subject: "wrong-owner")
        PublishingAuthProtocol.respond = { _ in (200, data) }
        defer { PublishingAuthProtocol.respond = nil }
        let auth = try fixture(storage: storage)
        await #expect(throws: (any Error).self) { try await auth.authorize(identity: identity, identityToken: Data("token".utf8), nonce: PublishingAppleNonce()) }
        await #expect(throws: (any Error).self) { try await auth.accessToken(for: identity) }
        data = try response(subject: "owner")
        storage.fails = true
        await #expect(throws: (any Error).self) { try await auth.authorize(identity: identity, identityToken: Data("token".utf8), nonce: PublishingAppleNonce()) }
        await #expect(throws: (any Error).self) { try await auth.accessToken(for: identity) }
    }

    @Test func expirationRefreshesThePublishingSessionWithoutChangingAccountIdentity() async throws {
        let storage = PublishingTestStorage(), identity = AccountIdentity.apple("owner"), auth = try fixture(storage: storage)
        let expired = try response(subject: "owner", expired: true), refreshed = try response(subject: "owner")
        PublishingAuthProtocol.respond = { request in
            if request.url!.path.hasSuffix("/apple") { return (200, expired) }
            #expect(request.url!.path.hasSuffix("/refresh"))
            return (200, refreshed)
        }
        defer { PublishingAuthProtocol.respond = nil }
        try await auth.authorize(identity: identity, identityToken: Data("token".utf8), nonce: PublishingAppleNonce())
        #expect(try await auth.accessToken(for: identity).hasPrefix("ppa_"))
        #expect(identity == .apple("owner"))
    }

    @Test func simultaneousRefreshRequestsShareOneRotatingCredentialExchange() async throws {
        let storage = PublishingTestStorage(), identity = AccountIdentity.apple("owner"), auth = try fixture(storage: storage)
        let expired = try response(subject: "owner", expired: true), valid = try response(subject: "owner")
        PublishingAuthProtocol.respond = { _ in (200, expired) }
        defer { PublishingAuthProtocol.respond = nil; PublishingAuthProtocol.schedule = nil }
        try await auth.authorize(identity: identity, identityToken: Data("token".utf8), nonce: PublishingAppleNonce())
        var exchanges = 0
        PublishingAuthProtocol.schedule = { _, complete in
            exchanges += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { complete(200, valid) }
        }
        async let first = auth.accessToken(for: identity)
        async let second = auth.accessToken(for: identity)
        let values = try await [first, second]
        #expect(values[0] == values[1])
        #expect(exchanges == 1)
    }

    @Test func freshAuthorizationCancelsAnOlderRefreshWithoutLosingTheNewSession() async throws {
        let storage = PublishingTestStorage(), identity = AccountIdentity.apple("owner"), auth = try fixture(storage: storage)
        let expired = try response(subject: "owner", expired: true), valid = try response(subject: "owner")
        PublishingAuthProtocol.respond = { _ in (200, expired) }
        defer { PublishingAuthProtocol.respond = nil; PublishingAuthProtocol.schedule = nil }
        try await auth.authorize(identity: identity, identityToken: Data("token".utf8), nonce: PublishingAppleNonce())
        var refreshStarted: CheckedContinuation<Void, Never>?
        PublishingAuthProtocol.schedule = { request, complete in
            if request.url!.path.hasSuffix("/refresh") { refreshStarted?.resume(); refreshStarted = nil }
            else { complete(200, valid) }
        }
        var old: Task<String, Error>!
        await withCheckedContinuation { continuation in
            refreshStarted = continuation
            old = Task { try await auth.accessToken(for: identity) }
        }
        try await auth.authorize(identity: identity, identityToken: Data("fresh-token".utf8), nonce: PublishingAppleNonce())
        await #expect(throws: (any Error).self) { try await old.value }
        #expect(try await auth.accessToken(for: identity).hasPrefix("ppa_"))
    }

    @Test func forgettingAnAccountCancelsRefreshAndCannotRestoreItsCredentials() async throws {
        let storage = PublishingTestStorage(), identity = AccountIdentity.apple("owner"), auth = try fixture(storage: storage)
        let expired = try response(subject: "owner", expired: true)
        PublishingAuthProtocol.respond = { _ in (200, expired) }
        defer { PublishingAuthProtocol.respond = nil; PublishingAuthProtocol.schedule = nil }
        try await auth.authorize(identity: identity, identityToken: Data("token".utf8), nonce: PublishingAppleNonce())
        var refreshStarted: CheckedContinuation<Void, Never>?
        PublishingAuthProtocol.schedule = { _, _ in refreshStarted?.resume(); refreshStarted = nil }
        var old: Task<String, Error>!
        await withCheckedContinuation { continuation in
            refreshStarted = continuation
            old = Task { try await auth.accessToken(for: identity) }
        }
        try auth.forget(identity)
        await #expect(throws: (any Error).self) { try await old.value }
        await #expect(throws: PublishingFailure.appleAuthorizationRequired) { try await auth.accessToken(for: identity) }
    }

    @Test func mainSignInCredentialSurvivesDismissalAndServiceRecreationWithoutAnotherAppleRequest() async throws {
        let storage = PublishingTestStorage(), identity = AccountIdentity.apple("owner"), nonce = try PublishingAppleNonce()
        try fixture(storage: storage).stage(identity: identity, identityToken: Data("main-sign-in-token".utf8), nonce: nonce)
        let valid = try response(subject: "owner")
        PublishingAuthProtocol.respond = { request in
            #expect(request.url!.path.hasSuffix("/apple"))
            return (200, valid)
        }
        defer { PublishingAuthProtocol.respond = nil }
        let restored = try fixture(storage: storage)
        let token = try await restored.accessToken(for: identity)
        #expect(token.hasPrefix("ppa_"))
        #expect(storage.retrieve(key: "pending") == nil)
        #expect(try await fixture(storage: storage).accessToken(for: identity) == token)
    }

    @Test func offlineCredentialExchangeRetriesTheSavedMainLoginWithoutReauthentication() async throws {
        let storage = PublishingTestStorage(), identity = AccountIdentity.apple("owner")
        try fixture(storage: storage).stage(identity: identity, identityToken: Data("main-token".utf8), nonce: PublishingAppleNonce())
        PublishingAuthProtocol.respond = { _ in throw URLError(.notConnectedToInternet) }
        defer { PublishingAuthProtocol.respond = nil }
        await #expect(throws: (any Error).self) { try await fixture(storage: storage).accessToken(for: identity) }
        #expect(storage.retrieve(key: "pending") != nil)
        let valid = try response(subject: "owner")
        PublishingAuthProtocol.respond = { _ in (200, valid) }
        #expect(try await fixture(storage: storage).accessToken(for: identity).hasPrefix("ppa_"))
    }

    @Test func existingAppAccountSharesTheSavedMainLoginWithoutASeparateSignIn() async throws {
        let storage = PublishingTestStorage(), pointer = PublishingTestAccountSession()
        pointer.identity = .apple("owner")
        let valid = try response(subject: "owner")
        var exchanges = 0
        PublishingAuthProtocol.respond = { request in
            exchanges += 1; #expect(request.url!.path.hasSuffix("/apple")); return (200, valid)
        }
        defer { PublishingAuthProtocol.respond = nil }
        let apple = try fixture(storage: storage)
        try apple.stage(identity: .apple("owner"), identityToken: Data("main-login-credential".utf8), nonce: PublishingAppleNonce())
        let service = AuthService(session: pointer, publishingApple: apple, credentialState: { _ in .authorized })
        async let first = service.publishingAccessToken(for: .apple("owner"))
        async let second = service.publishingAccessToken(for: .apple("owner"))
        let tokens = try await [first, second]
        #expect(tokens[0] == tokens[1]); #expect(exchanges == 1)
        #expect(pointer.identity == .apple("owner"))
        #expect(try await service.publishingAccessToken(for: .apple("owner")) == tokens[0])
        #expect(exchanges == 1)
    }

    @Test func missingLegacyCredentialNeverStartsAnInteractiveSignInOutsideAccountSettings() async throws {
        let pointer = PublishingTestAccountSession(); pointer.identity = .apple("owner")
        var requests = 0
        PublishingAuthProtocol.respond = { _ in requests += 1; return (500, Data()) }
        defer { PublishingAuthProtocol.respond = nil }
        let service = AuthService(session: pointer, publishingApple: try fixture(storage: PublishingTestStorage()), credentialState: { _ in .authorized })
        for _ in 0..<2 {
            await #expect(throws: PublishingFailure.appleAuthorizationRequired) { try await service.publishingAccessToken(for: .apple("owner")) }
        }
        #expect(requests == 0); #expect(pointer.identity == .apple("owner"))
    }

    @Test func accountSwitchDuringCredentialExchangeCannotReturnThePreviousAccountsSession() async throws {
        let pointer = PublishingTestAccountSession(); pointer.identity = .apple("owner")
        var requests = 0
        let valid = try response(subject: "owner")
        PublishingAuthProtocol.respond = { _ in requests += 1; pointer.identity = .apple("other"); return (200, valid) }
        defer { PublishingAuthProtocol.respond = nil }
        let apple = try fixture(storage: PublishingTestStorage())
        try apple.stage(identity: .apple("owner"), identityToken: Data("main-login-token".utf8), nonce: PublishingAppleNonce())
        let service = AuthService(session: pointer, publishingApple: apple, credentialState: { _ in .authorized })
        await #expect(throws: CancellationError.self) { try await service.publishingAccessToken(for: .apple("owner")) }
        #expect(requests == 1); #expect(pointer.identity == .apple("other"))
    }
}
