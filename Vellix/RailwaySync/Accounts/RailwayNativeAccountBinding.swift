import Foundation
import Combine

@MainActor final class RailwayNativeAccountBinding: ObservableObject {
    @Published private(set) var connectedLibraryID: String?
    private(set) var scope: RailwayAccountScope?
    private var session: RailwayAccountSession?
    private var generation = UUID()

    func select(ownerKey: String?) {
        let next = ownerKey.flatMap { try? RailwayAccountScope(ownerKey: $0) }
        guard next != scope else { return }
        generation = UUID()
        connectedLibraryID = nil
        if let previous = session { Task { await previous.suspend() } }
        session = nil
        scope = next
    }

    func client() throws -> RailwayAccountSession {
        guard let scope else { throw RailwayError.signedOut }
        if let session { return session }
        let transport = try RailwayTransport(baseURL: URL(string: "https://api.penned.im")!)
        let new = RailwayAccountSession(transport: transport, keychain: RailwayKeychain(service: scope.keychainService))
        session = new
        return new
    }

    // Restore persisted proof without a network dependency. A caller can validate
    // or refresh it online later; local offline writes remain independently gated.
    func restore() async throws -> RailwaySession? {
        guard let scope else { throw RailwayError.signedOut }
        let client = try client(), fence = generation
        let record = try await client.restore(expectedOwner: scope.ownerKey)
        guard fence == generation else { throw RailwayError.signedOut }
        if let record { try scope.validate(record) }
        return record
    }

    func verify(_ client: RailwayAccountSession, ownerKey: String) async throws -> RailwaySession {
        guard session === client, let scope, scope.ownerKey == ownerKey else { throw RailwayError.accountMismatch }
        let fence = generation
        let record = try await client.binding()
        try scope.validate(record)
        let profile = try await RailwayAccountService(session: client).profile()
        _ = try await RailwaySyncAPI(account: client).status()
        guard fence == generation, session === client, profile.accountID == ownerKey else { throw RailwayError.accountMismatch }
        if connectedLibraryID != record.libraryID {connectedLibraryID = record.libraryID}
        return try await client.binding()
    }

    // Restore, validate and renew in the background. A network failure is not
    // local account revocation. Only a definitive 401 discards the backend token.
    func restoreOnline()async throws->Bool {
        guard let scope else{throw RailwayError.signedOut}
        let client=try client(),fence=generation
        guard try await restore() != nil else{if generation==fence{connectedLibraryID=nil};return false}
        do{
            if connectedLibraryID==scope.libraryID{_ = try await client.token()}
            else{_ = try await verify(client,ownerKey:scope.ownerKey)}
            guard generation==fence else{throw CancellationError()}
            return true
        }catch RailwayError.http(401,_,_){
            guard generation==fence else{throw CancellationError()}
            try await client.discardRejectedSession()
            guard generation==fence else{throw CancellationError()}
            connectedLibraryID=nil
            return false
        }
    }

    // Called by the subsequent workspace integration, using its existing scoped
    // SQLite handle. Rebinding never activates capture or starts a sync worker.
    func bind(to database: AppDatabase) async throws -> RailwaySession {
        guard let scope, database.libraryID == scope.libraryID, database.isAccessible else { throw RailwayError.accountMismatch }
        let fence = generation, client = try client()
        guard let record = try await restore() else { throw RailwayError.signedOut }
        try scope.validate(record)
        guard fence == generation else { throw RailwayError.signedOut }
        try await RailwayDeviceRebinding(database: database, account: client).reconcile()
        guard fence == generation else { throw RailwayError.signedOut }
        return record
    }

    func disconnect() async throws {
        let client = try client(), fence = generation
        if try await restore() != nil { try await client.signOut() }
        try await client.finishPendingRevocation()
        if fence == generation { connectedLibraryID = nil }
    }
}
