import Foundation

// Credentials belong to a provider subject, never to the currently visible email.
nonisolated struct RailwayAccountScope: Equatable, Sendable {
    let ownerKey: String
    let libraryID: String
    var keychainService: String { "im.lystaria.Penned.Railway.Session." + libraryID }

    init(ownerKey: String) throws {
        guard !ownerKey.isEmpty, ownerKey.hasPrefix("apple:") || ownerKey.hasPrefix("supabase:") else { throw RailwayError.accountMismatch }
        self.ownerKey = ownerKey
        libraryID = RailwayAccountSession.libraryID(ownerKey: ownerKey)
    }

    func validate(_ session: RailwaySession) throws {
        guard session.ownerKey == ownerKey, session.libraryID == libraryID,
              !session.deviceID.isEmpty, !session.accessToken.isEmpty, !session.refreshToken.isEmpty else { throw RailwayError.accountMismatch }
    }
}

