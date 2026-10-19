import Foundation
import Security
import Supabase
import Testing
@testable import Vellix

private final class AuthHTTPFixture: @unchecked Sendable {
    let host = "test-\(UUID().uuidString.lowercased()).example.com"
    private let lock = NSLock()
    private var history: [URLRequest] = []
    var respond: @Sendable (URLRequest) throws -> (Int, Data)
    init(respond: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        self.respond = respond
        AuthFixtureProtocol.register(self)
    }
    func execute(_ request: URLRequest) throws -> (Int, Data) {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1_024); var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
            }
            recorded.httpBodyStream = nil; recorded.httpBody = data
        }
        lock.withLock { history.append(recorded) }
        return try respond(recorded)
    }
    var requests: [URLRequest] { lock.withLock { history } }
    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthFixtureProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class AuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: AuthHTTPFixture] = [:]
    static func register(_ fixture: AuthHTTPFixture) { lock.withLock { fixtures[fixture.host] = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let fixture = Self.lock.withLock({ Self.fixtures[request.url?.host ?? ""] }) else {
                throw URLError(.unsupportedURL)
            }
            let (status, data) = try fixture.execute(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class AuthTestStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var failWrites = false
    var failReads = false
    func store(key: String, value: Data) throws {
        try lock.withLock {
            if failWrites { throw AccountError.keychainUnavailable }
            values[key] = value
        }
    }
    func retrieve(key: String) throws -> Data? {
        try lock.withLock {
            if failReads { throw AccountError.keychainUnavailable }
            return values[key]
        }
    }
    func remove(key: String) { lock.withLock { values[key] = nil } }
}

private final class AuthTestStores {
    var stores: [String: AuthTestStorage] = [:]
    func storage(_ key: String) -> AuthTestStorage {
        if let store = stores[key] { return store }
        let store = AuthTestStorage(); stores[key] = store; return store
    }

    func keychainStorage(_ service: String) -> PennedAuthKeychainStorage {
        let store = storage(service)
        return PennedAuthKeychainStorage(service: service, storage: store, copyMatching: { query in
            guard query[kSecAttrService as String] as? String == service,
                  let key = query[kSecAttrAccount as String] as? String,
                  query[kSecReturnData as String] as? Bool == true,
                  query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String else {
                return (errSecParam, nil)
            }
            do {
                guard let data = try store.retrieve(key: key) else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            } catch { return (errSecInteractionNotAllowed, nil) }
        }, deleteItem: { query in
            guard query[kSecAttrService as String] as? String == service,
                  let key = query[kSecAttrAccount as String] as? String else { return errSecParam }
            do {
                guard try store.retrieve(key: key) != nil else { return errSecItemNotFound }
                store.remove(key: key)
                return errSecSuccess
            } catch { return errSecInteractionNotAllowed }
        })
    }
}

@Suite @MainActor
struct SupabaseAuthTests {
    private func config(_ fixture: AuthHTTPFixture) throws -> SupabaseConfiguration {
        try SupabaseConfiguration(values: ["SUPABASE_URL": "https://\(fixture.host)",
            "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_test_fixture_only"])
    }
    private func service(_ fixture: AuthHTTPFixture, stores: AuthTestStores = AuthTestStores()) throws -> SupabaseEmailAuth {
        let config = try config(fixture)
        return SupabaseEmailAuth(configuration: { config }, storageFactory: { stores.storage($0) }, urlSession: fixture.session())
    }
    private nonisolated static func session(id: UUID = UUID(), email: String = "user@example.com", expired: Bool = false, refresh: String = "fixture-refresh") -> Session {
        let now = Date()
        let expiry = now.addingTimeInterval(expired ? -120 : 3_600).timeIntervalSince1970
        func base64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let claims = try! JSONSerialization.data(withJSONObject: ["sub": id.uuidString.lowercased(), "exp": expiry])
        let jwt = "\(base64(Data("{\"alg\":\"HS256\"}".utf8))).\(base64(claims)).fixture"
        let user = User(id: id, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: email,
            createdAt: now, emailConfirmedAt: now, role: "authenticated", updatedAt: now)
        return Session(accessToken: jwt, tokenType: "bearer", expiresIn: 3_600, expiresAt: expiry,
            refreshToken: refresh, user: user)
    }
    private nonisolated static func wire<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    private func seed(_ session: Session, config: SupabaseConfiguration, stores: AuthTestStores) throws -> AccountIdentity {
        let id = AccountIdentity.email(project: config.projectID, userID: session.user.id)
        try stores.storage(SupabaseEmailAuth.storageNamespace(for: id)).store(key: SupabaseEmailAuth.sessionKey,
            value: JSONEncoder().encode(session))
        return id
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(); var bytes = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; result.append(contentsOf: bytes.prefix(count))
            }
            data = result
        } else { data = Data("{}".utf8) }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func missingAndPrivilegedConfigurationFailsClosed() throws {
        for key in ["", "sb_secret_not_allowed", "service_role", "legacy-jwt-key"] {
            #expect(throws: EmailAuthError.configurationMissing) {
                try SupabaseConfiguration(values: ["SUPABASE_URL": "https://auth.example.com", "SUPABASE_PUBLISHABLE_KEY": key])
            }
        }
        #expect(throws: EmailAuthError.configurationMissing) { try SupabaseConfiguration(values: [:]) }
    }

    @Test func xcconfigPlaceholdersAndUnexpandedBuildSettingsAreRejected() throws {
        for (address, key) in [
            ("$(SUPABASE_URL)", "$(SUPABASE_PUBLISHABLE_KEY)"),
            ("https://YOUR_SUPABASE_PROJECT_REF.supabase.co", "sb_publishable_test_fixture_only"),
            ("https://auth.example.com", "YOUR_SUPABASE_PUBLISHABLE_KEY"),
            ("https://auth.example.com", "sb_publishable_$(MISSING_VALUE)"),
            ("https://auth.example.com", "sb_publishable_test fixture")
        ] {
            #expect(throws: EmailAuthError.configurationMissing) {
                try SupabaseConfiguration(values: ["SUPABASE_URL": address, "SUPABASE_PUBLISHABLE_KEY": key])
            }
        }
    }

    @Test func sdkSendsAndResendsEmailOTPWithoutActivatingASession() async throws {
        let fixture = AuthHTTPFixture { _ in (200, Data("{}".utf8)) }
        let stores = AuthTestStores(); let auth = try service(fixture, stores: stores)
        let attempt = UUID()
        try await auth.sendCode(email: "user@example.com", attempt: attempt)
        try await auth.sendCode(email: "user@example.com", attempt: attempt)
        #expect(fixture.requests.count == 2)
        for request in fixture.requests {
            #expect(request.url?.path == "/auth/v1/otp")
            #expect(try body(request)["email"] as? String == "user@example.com")
            #expect(try body(request)["create_user"] as? Bool == true)
        }
        #expect(stores.stores.isEmpty)
    }

    @Test func sdkVerifiesEmailCodeAndPersistsTheFullSessionInItsOwnNamespace() async throws {
        let session = Self.session()
        let fixture = AuthHTTPFixture { request in
            if request.url?.path.hasSuffix("/verify") == true { return (200, try Self.wire(session)) }
            if request.url?.path.hasSuffix("/user") == true { return (200, try Self.wire(session.user)) }
            return (200, Data("{}".utf8))
        }
        let stores = AuthTestStores(); let auth = try service(fixture, stores: stores); let attempt = UUID()
        try await auth.sendCode(email: "user@example.com", attempt: attempt)
        let account = try await auth.verifyCode(email: "user@example.com", code: "12345678", attempt: attempt)
        let request = try #require(fixture.requests.first(where: { $0.url?.path.hasSuffix("/verify") == true }))
        #expect(try body(request)["type"] as? String == "email")
        #expect(try body(request)["token"] as? String == "12345678")
        let stored = try stores.storage(SupabaseEmailAuth.storageNamespace(for: account.identity)).retrieve(key: SupabaseEmailAuth.sessionKey)
        let data = try #require(stored)
        #expect(try JSONDecoder().decode(Session.self, from: data).refreshToken == session.refreshToken)
        #expect(account.identity == .email(project: try config(fixture).projectID, userID: session.user.id))
    }

    @Test func nativeKeychainMissingItemsAreEmptyAndRemovalIsIdempotent() throws {
        let storage = CheckedAuthStorage(AuthTestStores().keychainStorage("test-\(UUID())"))
        #expect(try storage.retrieve(key: "supabase.session") == nil)
        try storage.remove(key: "supabase.auth.token")
        try storage.check()
        let data = Data("test-session".utf8)
        try storage.store(key: SupabaseEmailAuth.sessionKey, value: data)
        #expect(try storage.retrieve(key: SupabaseEmailAuth.sessionKey) == data)
        try storage.remove(key: SupabaseEmailAuth.sessionKey)
        try storage.remove(key: SupabaseEmailAuth.sessionKey)
        try storage.check()
    }

    @Test func nativeKeychainAccessFailuresStillPreventActivation() throws {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecMissingEntitlement, errSecDecode] {
            let storage = CheckedAuthStorage(PennedAuthKeychainStorage(service: "test-\(UUID())",
                storage: AuthTestStorage(), copyMatching: { _ in (status, nil) }, deleteItem: { _ in status }))
            #expect(throws: AccountError.keychainUnavailable) { try storage.retrieve(key: SupabaseEmailAuth.sessionKey) }
            #expect(throws: AccountError.keychainUnavailable) { try storage.remove(key: SupabaseEmailAuth.sessionKey) }
            #expect(throws: AccountError.keychainUnavailable) { try storage.check() }
        }
    }

    @Test func nativeKeychainSuccessfulReadWithoutDataStillFailsClosed() throws {
        let storage = PennedAuthKeychainStorage(service: "test-\(UUID())", storage: AuthTestStorage(),
            copyMatching: { _ in (errSecSuccess, nil) }, deleteItem: { _ in errSecSuccess })
        #expect(throws: AccountError.keychainUnavailable) { try storage.retrieve(key: SupabaseEmailAuth.sessionKey) }
    }

    @Test func absentKeychainMigrationSlotsDoNotBlockOTPOrRestoration() async throws {
        let session = Self.session()
        let fixture = AuthHTTPFixture { request in
            if request.url?.path.hasSuffix("/verify") == true { return (200, try Self.wire(session)) }
            if request.url?.path.hasSuffix("/user") == true { return (200, try Self.wire(session.user)) }
            return (200, Data("{}".utf8))
        }
        let stores = AuthTestStores(); let config = try config(fixture)
        let auth = SupabaseEmailAuth(configuration: { config }, storageFactory: { stores.keychainStorage($0) },
            urlSession: fixture.session())
        let attempt = UUID()
        try await auth.sendCode(email: "user@example.com", attempt: attempt)
        let verified = try await auth.verifyCode(email: "user@example.com", code: "12345678", attempt: attempt)
        let bytes = try stores.storage(SupabaseEmailAuth.storageNamespace(for: verified.identity))
            .retrieve(key: SupabaseEmailAuth.sessionKey)
        let stored = try #require(bytes)
        #expect(try JSONDecoder().decode(Session.self, from: stored).accessToken == session.accessToken)
        let restored = SupabaseEmailAuth(configuration: { config }, storageFactory: { stores.keychainStorage($0) },
            urlSession: fixture.session())
        #expect(try await restored.restore(verified.identity).identity == verified.identity)
        try restored.forget(verified.identity)
        try restored.forget(verified.identity)
        #expect(try stores.storage(SupabaseEmailAuth.storageNamespace(for: verified.identity))
            .retrieve(key: SupabaseEmailAuth.sessionKey) == nil)
    }

    @Test func invalidExpiredAndRateLimitedCodesAreReportedFromSDKResponses() async throws {
        for (code, status, expected) in [("invalid_credentials", 400, EmailAuthError.invalidCode),
            ("otp_expired", 403, .expiredCode), ("over_email_send_rate_limit", 429, .rateLimited)] {
            let fixture = AuthHTTPFixture { request in
                if request.url?.path.hasSuffix("/verify") == true {
                    return (status, Data("{\"code\":\"\(code)\",\"msg\":\"Rejected verification\"}".utf8))
                }
                return (200, Data("{}".utf8))
            }
            let auth = try service(fixture); let attempt = UUID()
            try await auth.sendCode(email: "user@example.com", attempt: attempt)
            await #expect(throws: expected) { try await auth.verifyCode(email: "user@example.com", code: "12345678", attempt: attempt) }
        }
    }

    @Test func expiredSessionsRefreshAndPersistRotatedTokens() async throws {
        let expired = Self.session(expired: true, refresh: "old-fixture-refresh")
        let fresh = Self.session(id: expired.user.id, refresh: "rotated-fixture-refresh")
        let fixture = AuthHTTPFixture { request in
            if request.url?.path.hasSuffix("/token") == true { return (200, try Self.wire(fresh)) }
            return (200, try Self.wire(fresh.user))
        }
        let stores = AuthTestStores()
        let identity = try seed(expired, config: config(fixture), stores: stores)
        let auth = try service(fixture, stores: stores)
        #expect(try await auth.restore(identity).identity == identity)
        let bytes = try stores.storage(SupabaseEmailAuth.storageNamespace(for: identity)).retrieve(key: SupabaseEmailAuth.sessionKey)
        let saved = try #require(bytes)
        #expect(try JSONDecoder().decode(Session.self, from: saved).refreshToken == fresh.refreshToken)
        #expect(fixture.requests.contains(where: { $0.url?.query == "grant_type=refresh_token" }))
    }

    @Test func twoSavedSDKSessionStoresRemainIndependentAcrossServiceRecreation() async throws {
        let first = Self.session(email: "first@example.com", refresh: "first-fixture")
        let second = Self.session(email: "second@example.com", refresh: "second-fixture")
        let fixture = AuthHTTPFixture { request in
            let user = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(first.accessToken)" ? first.user : second.user
            return (200, try Self.wire(user))
        }
        let stores = AuthTestStores(); let config = try config(fixture)
        let firstID = try seed(first, config: config, stores: stores)
        let secondID = try seed(second, config: config, stores: stores)
        let auth = try service(fixture, stores: stores)
        #expect(try await auth.restore(firstID).email == "first@example.com")
        #expect(try await auth.restore(secondID).email == "second@example.com")
        let restored = try service(fixture, stores: stores)
        #expect(try await restored.restore(firstID).identity == firstID)
        #expect(SupabaseEmailAuth.storageNamespace(for: firstID) != SupabaseEmailAuth.storageNamespace(for: secondID))
    }

    @Test func storageWriteFailureCannotReportSuccessfulOTPAuthentication() async throws {
        let session = Self.session()
        let fixture = AuthHTTPFixture { request in
            if request.url?.path.hasSuffix("/verify") == true { return (200, try Self.wire(session)) }
            if request.url?.path.hasSuffix("/user") == true { return (200, try Self.wire(session.user)) }
            return (200, Data("{}".utf8))
        }
        let stores = AuthTestStores()
        let identity = AccountIdentity.email(project: try config(fixture).projectID, userID: session.user.id)
        stores.storage(SupabaseEmailAuth.storageNamespace(for: identity)).failWrites = true
        let auth = try service(fixture, stores: stores); let attempt = UUID()
        try await auth.sendCode(email: "user@example.com", attempt: attempt)
        await #expect(throws: AccountError.keychainUnavailable) { try await auth.verifyCode(email: "user@example.com", code: "12345678", attempt: attempt) }
    }

    @Test func inaccessibleSessionStorageIsNotMistakenForRevocation() async throws {
        let session = Self.session()
        let fixture = AuthHTTPFixture { _ in (200, Data("{}".utf8)) }
        let stores = AuthTestStores(); let identity = try seed(session, config: config(fixture), stores: stores)
        stores.storage(SupabaseEmailAuth.storageNamespace(for: identity)).failReads = true
        let auth = try service(fixture, stores: stores)
        await #expect(throws: AccountError.keychainUnavailable) { try await auth.restore(identity) }
    }

    @Test func aDifferentConfiguredProjectNeverReadsTheOtherProjectsSession() async throws {
        let fixture = AuthHTTPFixture { _ in (200, Data("{}".utf8)) }
        let stores = AuthTestStores(); let auth = try service(fixture, stores: stores)
        await #expect(throws: EmailAuthError.wrongProject) {
            try await auth.restore(.email(project: "https://different.example.com", userID: UUID()))
        }
        #expect(stores.stores.isEmpty)
        #expect(fixture.requests.isEmpty)
    }

    @Test func cancelledDraftCannotBeVerified() async throws {
        let fixture = AuthHTTPFixture { _ in (200, Data("{}".utf8)) }
        let auth = try service(fixture); let attempt = UUID()
        try await auth.sendCode(email: "user@example.com", attempt: attempt)
        auth.cancel(attempt: attempt)
        await #expect(throws: EmailAuthError.codeNotRequested) {
            try await auth.verifyCode(email: "user@example.com", code: "12345678", attempt: attempt)
        }
    }

    @Test func logoutUsesOnlyTheLocalServerSessionScopeAndKeepsOtherStoredAccounts() async throws {
        let first = Self.session(); let second = Self.session(email: "other@example.com")
        let fixture = AuthHTTPFixture { _ in (204, Data()) }
        let stores = AuthTestStores(); let config = try config(fixture)
        let firstID = try seed(first, config: config, stores: stores)
        let secondID = try seed(second, config: config, stores: stores)
        let auth = try service(fixture, stores: stores)
        try await auth.signOut(firstID)
        #expect(fixture.requests.contains(where: { $0.url?.query == "scope=local" }))
        #expect(try stores.storage(SupabaseEmailAuth.storageNamespace(for: firstID)).retrieve(key: SupabaseEmailAuth.sessionKey) == nil)
        #expect(try stores.storage(SupabaseEmailAuth.storageNamespace(for: secondID)).retrieve(key: SupabaseEmailAuth.sessionKey) != nil)
    }

    @Test func deletionCallsTheAuthenticatedFunctionAndRequiresMatchingConfirmation() async throws {
        let session = Self.session()
        let fixture = AuthHTTPFixture { request in
            if request.url?.path.hasSuffix("/penned-delete-account") == true {
                return (200, Data("{\"deletedUserID\":\"\(session.user.id.uuidString)\"}".utf8))
            }
            return (200, try Self.wire(session.user))
        }
        let stores = AuthTestStores(); let identity = try seed(session, config: config(fixture), stores: stores)
        let auth = try service(fixture, stores: stores)
        try await auth.deleteAccount(identity)
        let request = try #require(fixture.requests.first(where: { $0.url?.path.hasSuffix("/penned-delete-account") == true }))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(session.accessToken)")
        #expect(try body(request).isEmpty)
    }

    @Test func networkFailuresKeepCredentialsForRetryButOfflineLogoutRemovesThem() async throws {
        let session = Self.session()
        let fixture = AuthHTTPFixture { _ in throw URLError(.notConnectedToInternet) }
        let stores = AuthTestStores(); let identity = try seed(session, config: config(fixture), stores: stores)
        let auth = try service(fixture, stores: stores)
        await #expect(throws: EmailAuthError.network) { try await auth.restore(identity) }
        #expect(try stores.storage(SupabaseEmailAuth.storageNamespace(for: identity)).retrieve(key: SupabaseEmailAuth.sessionKey) != nil)
        try await auth.signOut(identity)
        #expect(try stores.storage(SupabaseEmailAuth.storageNamespace(for: identity)).retrieve(key: SupabaseEmailAuth.sessionKey) == nil)
    }

    @Test func missingFailedOrMismatchedDeletionConfirmationIsNeverSuccess() async throws {
        for (status, expected) in [(404, EmailAuthError.deletionUnavailable), (500, .deletionFailed), (200, .deletionFailed)] {
            let session = Self.session()
            let fixture = AuthHTTPFixture { request in
                if request.url?.path.hasSuffix("/penned-delete-account") == true {
                    return (status, Data("{\"deletedUserID\":\"\(UUID().uuidString)\"}".utf8))
                }
                return (200, try Self.wire(session.user))
            }
            let stores = AuthTestStores(); let identity = try seed(session, config: config(fixture), stores: stores)
            let auth = try service(fixture, stores: stores)
            await #expect(throws: expected) { try await auth.deleteAccount(identity) }
            #expect(try stores.storage(SupabaseEmailAuth.storageNamespace(for: identity)).retrieve(key: SupabaseEmailAuth.sessionKey) != nil)
        }
    }

    @Test func logoutCanRemoveAnOldProjectsCredentialsWithoutSendingThemToANewProject() async throws {
        let fixture = AuthHTTPFixture { _ in throw URLError(.unsupportedURL) }
        let stores = AuthTestStores(); let identity = try seed(Self.session(), config: config(fixture), stores: stores)
        let auth = SupabaseEmailAuth(configuration: { throw EmailAuthError.configurationMissing }, storageFactory: { stores.storage($0) }, urlSession: fixture.session())
        try await auth.signOut(identity)
        #expect(try stores.storage(SupabaseEmailAuth.storageNamespace(for: identity)).retrieve(key: SupabaseEmailAuth.sessionKey) == nil)
        #expect(fixture.requests.isEmpty)
    }
}
