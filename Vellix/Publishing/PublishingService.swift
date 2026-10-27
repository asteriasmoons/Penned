import Foundation

@MainActor
final class PublishingService {
    private let builder: PublishingDocumentBuilder
    private let client: PublishingClient
    private let currentIdentity: () -> AccountIdentity?
    private let accessToken: () async throws -> String
    private let canOperate: () -> Bool
    private let authorAvatar: () -> Data?

    init(database: AppDatabase, attachmentStore: AttachmentStore, client: PublishingClient,
         currentIdentity: @escaping () -> AccountIdentity?, accessToken: @escaping () async throws -> String, canOperate: @escaping () -> Bool = { true }, authorAvatar: @escaping () -> Data? = { nil }) {
        builder = PublishingDocumentBuilder(database: database, attachmentStore: attachmentStore)
        self.client = client
        self.currentIdentity = currentIdentity
        self.accessToken = accessToken
        self.canOperate = canOperate
        self.authorAvatar = authorAvatar
    }

    func prepare(documentID: String, includeAuthorAvatar: Bool = true, includeLinkedPages: Bool = false) throws -> PreparedPublication {
        guard let identity = currentIdentity() else { throw PublishingFailure.authenticationRequired }
        let avatarData = includeAuthorAvatar ? authorAvatar() : nil
        print("PENNED-AVATAR prepare doc=\(documentID) includeAuthorAvatar=\(includeAuthorAvatar) avatarBytes=\(avatarData?.count ?? -1)")
        return try builder.prepare(documentID: documentID, owner: identity, authorAvatarData: avatarData, includeLinkedPages: includeLinkedPages)
    }

    func publish(documentID: String, settings: PublishingSettings = .init(), replacing publication: PublicationStatus? = nil) async throws -> PublicationStatus {
        try await transfer(documentID: documentID, settings: settings, publication: publication, publishing: true)
    }

    func update(documentID: String, publication: PublicationStatus, settings: PublishingSettings) async throws -> PublicationStatus {
        try await transfer(documentID: documentID, settings: settings, publication: publication, publishing: false)
    }

    func updateAutomatically(documentID: String, publication: PublicationStatus) async throws -> PublicationStatus {
        try await transfer(documentID: documentID, settings: nil, publication: publication, publishing: false)
    }

    func discover(libraryID: String) async throws -> [PublicationStatus] {
        guard let identity = currentIdentity() else { throw PublishingFailure.authenticationRequired }
        let token = try await accessToken(); try check(identity)
        let result = try await client.list(libraryID: libraryID, token: token); try check(identity)
        return result
    }

    func establishBaseline(documentID: String, publication: PublicationStatus) async throws -> PublicationStatus {
        guard let identity = currentIdentity() else { throw PublishingFailure.authenticationRequired }
        let prepared = try builder.prepare(documentID: documentID, owner: identity)
        struct Baseline: Encodable { let document: PublishingDocument; let sourceFingerprint: String; let expectedVersion: Int }
        let token = try await accessToken(); try check(identity)
        let result: PublicationStatus = try await client.request(path: "publications/" + publication.id + "/baseline", method: "POST", token: token,
            body: JSONEncoder().encode(Baseline(document: prepared.document, sourceFingerprint: try prepared.document.fingerprint(), expectedVersion: publication.version)))
        try check(identity); return result
    }

    func configure(_ publication: PublicationStatus, path: String? = nil, password: String? = nil, emails: [String]? = nil, domains: [String]? = nil) async throws -> PublicationStatus {
        guard let identity = currentIdentity() else { throw PublishingFailure.authenticationRequired }
        let token = try await accessToken(); try check(identity)
        let result = try await client.configure(publication, path: path, password: password, emails: emails, domains: domains, token: token)
        try check(identity); return result
    }

    func status(_ publication: PublicationStatus) async throws -> PublicationStatus {
        guard let identity = currentIdentity() else { throw PublishingFailure.authenticationRequired }
        let token = try await accessToken()
        try check(identity)
        let result = try await client.status(id: publication.id, token: token)
        try check(identity)
        return result
    }

    func change(_ action: String, publication: PublicationStatus, settings: PublishingSettings? = nil) async throws -> PublicationStatus {
        guard let identity = currentIdentity() else { throw PublishingFailure.authenticationRequired }
        let token = try await accessToken()
        try check(identity)
        let result = try await client.change(action, publication: publication, settings: settings, token: token)
        try check(identity)
        return result
    }

    private func transfer(documentID: String, settings: PublishingSettings?, publication: PublicationStatus?, publishing: Bool) async throws -> PublicationStatus {
        guard let identity = currentIdentity() else { throw PublishingFailure.authenticationRequired }
        let options = settings ?? publication?.settings ?? .init()
        let prepared = try prepare(documentID: documentID, includeAuthorAvatar: options.showAuthor, includeLinkedPages: options.allowFollowLinkedContent)
        let token = try await accessToken()
        try check(identity)
        let status: PublicationStatus
        if let publication {
            guard publication.sourceLibraryID == prepared.sourceLibraryID, publication.sourceDocumentID == documentID else { throw PublishingFailure.invalidContent("The selected publication belongs to another document.") }
            status = publication
        } else { status = try await client.create(libraryID: prepared.sourceLibraryID, documentID: documentID, token: token) }
        for asset in prepared.document.media {
            if status.uploadedMedia?.contains(asset) == true { continue }
            try check(identity)
            guard let bytes = prepared.files[asset.id] else { throw PublishingFailure.invalidContent("A media file is missing.") }
            let uploaded = try await client.upload(asset, bytes: bytes, publicationID: status.id, token: token)
            guard uploaded == asset else { throw PublishingFailure.unavailable("The uploaded file could not be verified.") }
        }
        try check(identity)
        let result = try await client.commit(prepared.document, publication: status, settings: settings, publishing: publishing, token: token)
        try check(identity)
        return result
    }

    private func check(_ identity: AccountIdentity) throws {
        try Task.checkCancellation()
        guard canOperate() else { throw CancellationError() }
        guard currentIdentity() == identity else { throw CancellationError() }
    }
}
