import Foundation
import GRDB
import Combine
import Network

struct PublicationJob {
    var status: PublicationStatus
    var sequence: Int
    var intent: String
    var dirty: Bool
    var blocked: Bool
    var attempts: Int
    var retryAt: Double
    var error: String?
}

@MainActor
final class PublishingQueue: ObservableObject {
    @Published private(set) var jobs: [String: PublicationJob] = [:]
    @Published private(set) var busy = false
    @Published var errorMessage: String?
    private let database: AppDatabase
    private let store: AttachmentStore
    private var owner: String?
    private var identity: () -> AccountIdentity? = { nil }
    private var service: PublishingService?
    private var worker: Task<Void, Never>?
    private var buildService: (() throws -> PublishingService)?
    private var polling = false
    private var generation = UUID()
    private var change: AnyCancellable?
    private let network = NWPathMonitor()

    init(database: AppDatabase, store: AttachmentStore) {
        self.database = database; self.store = store
        change = NotificationCenter.default.publisher(for: .pennedCollectionsChanged)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }
        network.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { Task { @MainActor in self?.retry() } }
        }
        network.start(queue: DispatchQueue(label: "penned.publishing.network"))
    }

    func start(identity: @escaping () -> AccountIdentity?, accessToken: @escaping () async throws -> String, client: PublishingClient? = nil, runWorker: Bool = true, authorAvatar: @escaping () -> Data? = { nil }) {
        let key = identity()?.libraryOwnerKey
        guard owner != key || service == nil else { return }
        stop(); self.identity = identity; owner = key
        guard key != nil else { return }
        do {
            let client = try client ?? PublishingClient(configuration: .load())
            buildService = { [weak self] in
                guard let self else { throw CancellationError() }; let session = self.generation
                return PublishingService(database: self.database, attachmentStore: self.store, client: client,
                    currentIdentity: identity, accessToken: accessToken, canOperate: { [weak self] in self?.valid(session) == true }, authorAvatar: authorAvatar)
            }
            service = try buildService?(); polling = runWorker
            retry(); beginWorker()
        } catch { errorMessage = error.localizedDescription }
    }

    private func beginWorker() {
        guard polling, valid() else { return }; let session = generation
        worker = Task { [weak self] in
            var discovery = 0
            while !Task.isCancelled {
                guard let self, self.valid(session) else { return }
                if discovery % 6 == 0 { await self.discover() }
                await self.drain(); discovery += 1
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        generation = UUID(); worker?.cancel(); worker = nil; service = nil
        buildService = nil; polling = false
        owner = nil; jobs = [:]; busy = false
    }

    private func valid(_ session: UUID? = nil) -> Bool {
        database.isAccessible && owner != nil && identity()?.libraryOwnerKey == owner && (session == nil || session == generation)
    }

    func reload() {
        guard valid(), let owner else { return }
        do {
            jobs = try database.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM publicationJobs WHERE ownerKey=? AND libraryID=?", arguments: [owner, database.libraryID]).reduce(into: [:]) { result, row in
                    guard let data = (row["statusJSON"] as String).data(using: .utf8), var status = try? JSONDecoder().decode(PublicationStatus.self, from: data) else { return }
                    status.usePennedDomain()
                    result[status.sourceDocumentID] = PublicationJob(status: status, sequence: row["sequence"], intent: row["intent"], dirty: row["dirty"], blocked: row["blocked"], attempts: row["attempts"], retryAt: row["retryAt"], error: row["error"])
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func cache(_ status: PublicationStatus, intent: String, sequence: Int? = nil, clean: Bool = true) throws {
        guard valid(), let owner else { throw CancellationError() }
        guard status.sourceLibraryID == database.libraryID else { throw LibraryError.wrongOwner }
        let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        try database.writeMetadata { db in
            try db.execute(sql: """
                INSERT INTO publicationJobs(ownerKey,libraryID,documentID,statusJSON,intent,dirty)
                VALUES(?,?,?,?,?,?) ON CONFLICT(ownerKey,libraryID,documentID) DO UPDATE SET
                statusJSON=excluded.statusJSON,intent=excluded.intent,
                dirty=CASE WHEN excluded.intent='inactive' OR ? IS NULL OR sequence=? THEN excluded.dirty ELSE dirty END,
                attempts=0,retryAt=0,error=NULL,blocked=0
                """, arguments: [owner, database.libraryID, status.sourceDocumentID, json, intent, !clean, sequence, sequence])
        }
        reload()
    }

    func discover() async {
        guard valid(), !busy, let service else { return }
        let session = generation; busy = true; defer { if generation == session { busy = false } }
        do {
            let statuses = try await service.discover(libraryID: database.libraryID)
            guard valid(session) else { return }
            errorMessage = nil
            let remoteIDs = Set(statuses.map(\.id))
            for job in jobs.values where !remoteIDs.contains(job.status.id) {
                var removed = job.status; removed.active = false
                try cache(removed, intent: "inactive")
            }
            for original in statuses {
                var status = original
                let existing = jobs[status.sourceDocumentID]
                if existing?.intent == "stop" { continue }
                if let existing, existing.status == status && !existing.blocked { continue }
                let hash = try? service.prepare(documentID: status.sourceDocumentID, includeAuthorAvatar: status.settings.showAuthor, includeLinkedPages: status.settings.allowFollowLinkedContent).document.fingerprint()
                if status.active && status.sourceFingerprint == nil,
                   let baseline = try? await service.establishBaseline(documentID: status.sourceDocumentID, publication: status) {
                    guard valid(session) else { return }; status = baseline
                }
                try cache(status, intent: status.active ? "active" : "inactive", clean: !status.active || hash == status.sourceFingerprint)
                let metadataOnly = existing?.intent == "active" && existing?.status.active == true
                    && existing?.status.sourceFingerprint != nil && existing?.status.sourceFingerprint == status.sourceFingerprint
                var avatarUpgrade = false
                if status.settings.showAuthor, hash != status.sourceFingerprint, let previous = status.sourceFingerprint,
                   let withoutAvatar = try? service.prepare(documentID: status.sourceDocumentID, includeAuthorAvatar: false).document.fingerprint() {
                    avatarUpgrade = withoutAvatar == previous
                }
                var linkedPageUpgrade = false
                if status.settings.allowFollowLinkedContent, let previous = status.sourceFingerprint,
                   let withoutPages = try? service.prepare(documentID: status.sourceDocumentID, includeAuthorAvatar: status.settings.showAuthor).document.fingerprint() {
                    linkedPageUpgrade = withoutPages == previous
                }
                if status.active && hash != status.sourceFingerprint && !metadataOnly && !avatarUpgrade && !linkedPageUpgrade {
                    try fail(status.sourceDocumentID, message: "This device must receive the latest document through sync before uploading. Review and publish this device's saved version to resolve.", blocked: true)
                }
            }
        } catch { if valid(session) { errorMessage = error.localizedDescription } }
    }

    func retry() {
        guard valid(), let owner else { return }
        try? database.writeMetadata { db in
            try db.execute(sql: "UPDATE publicationJobs SET retryAt=0 WHERE ownerKey=? AND libraryID=? AND blocked=0", arguments: [owner, database.libraryID])
        }
        reload()
    }

    func profileChanged() {
        guard valid(), let owner else { return }
        try? database.writeMetadata { db in
            try db.execute(sql: "UPDATE publicationJobs SET dirty=1,sequence=sequence+1,retryAt=0 WHERE ownerKey=? AND libraryID=? AND intent='active' AND blocked=0", arguments: [owner, database.libraryID])
        }
        reload()
    }

    private func fail(_ id: String, message: String, blocked: Bool) throws {
        guard valid(), let owner else { throw CancellationError() }
        let attempts = (jobs[id]?.attempts ?? 0) + 1
        try database.writeMetadata { db in
            try db.execute(sql: "UPDATE publicationJobs SET dirty=1,attempts=?,retryAt=?,error=?,blocked=? WHERE ownerKey=? AND libraryID=? AND documentID=?",
                arguments: [attempts, Date().timeIntervalSince1970 + min(900, pow(2, Double(min(9, attempts))) * 5), message, blocked, owner, database.libraryID, id])
        }
        reload()
    }

    func drain() async {
        reload()
        guard valid(), !busy, let service else { return }
        let session = generation; busy = true; defer { if generation == session { busy = false } }
        for (id, job) in jobs.sorted(by: { $0.key < $1.key }) where job.dirty && job.retryAt <= Date().timeIntervalSince1970 {
            guard valid(session), !Task.isCancelled else { return }
            do {
                let document = try? DocumentRepository(database: database).document(id: id)
                // Absence during initial CloudKit hydration is not a deletion.
                if document == nil && job.intent != "stop" { continue }
                let removed = document?.isTrashed == true || document?.isArchived == true
                if job.blocked && !removed && job.intent != "stop" { continue }
                if job.intent == "stop" || removed {
                    var status = try await service.status(job.status)
                    if status.active { status = try await service.change("unpublish", publication: status) }
                    guard valid(session) else { return }
                    try cache(status, intent: "inactive", sequence: job.sequence)
                } else if job.intent == "active" {
                    let hash = try service.prepare(documentID: id, includeAuthorAvatar: job.status.settings.showAuthor, includeLinkedPages: job.status.settings.allowFollowLinkedContent).document.fingerprint()
                    if hash == job.status.sourceFingerprint {
                        try cache(job.status, intent: "active", sequence: job.sequence)
                    } else {
                        let status = try await service.updateAutomatically(documentID: id, publication: job.status)
                        guard valid(session) else { return }
                        try cache(status, intent: status.active ? "active" : "inactive", sequence: job.sequence)
                    }
                }
            } catch is CancellationError { return }
            catch {
                guard valid(session) else { return }
                if error as? PublishingFailure == .conflict {
                    if let latest = try? await service.status(job.status), valid(session) {
                        if job.intent == "stop" {
                            try? cache(latest, intent: latest.active ? "stop" : "inactive", sequence: job.sequence, clean: !latest.active); continue
                        }
                        let hash = try? service.prepare(documentID: id, includeAuthorAvatar: latest.settings.showAuthor, includeLinkedPages: latest.settings.allowFollowLinkedContent).document.fingerprint()
                        if !latest.active || hash == latest.sourceFingerprint {
                            try? cache(latest, intent: latest.active ? "active" : "inactive", sequence: job.sequence); continue
                        }
                        if latest.active, let previous = job.status.sourceFingerprint, previous == latest.sourceFingerprint {
                            try? cache(latest, intent: "active", sequence: job.sequence, clean: false); continue
                        }
                    }
                }
                try? fail(id, message: error.localizedDescription, blocked: error as? PublishingFailure == .conflict)
            }
        }
    }

    func publish(_ id: String) async throws {
        guard valid(), !busy, let service else { throw PublishingFailure.authenticationRequired }
        let session = generation
        busy = true; defer { if generation == session { busy = false } }
        var previous = jobs[id]?.status
        if let value = previous { previous = try await service.status(value) }
        let status = try await service.publish(documentID: id, settings: previous?.settings ?? .init(), replacing: previous)
        guard valid(session) else { throw CancellationError() }
        // A save arriving during the request remains pending rather than being lost.
        let hash = try? service.prepare(documentID: id, includeAuthorAvatar: status.settings.showAuthor, includeLinkedPages: status.settings.allowFollowLinkedContent).document.fingerprint()
        try cache(status, intent: "active", clean: hash == status.sourceFingerprint)
    }

    func stopPublishing(_ id: String) async throws {
        guard valid(), let owner, jobs[id] != nil else { throw PublishingFailure.authenticationRequired }
        generation = UUID(); worker?.cancel(); worker = nil; busy = false
        service = try buildService?()
        try database.writeMetadata { db in
            try db.execute(sql: "UPDATE publicationJobs SET intent='stop',dirty=1,blocked=0,retryAt=0,sequence=sequence+1 WHERE ownerKey=? AND libraryID=? AND documentID=?", arguments: [owner, database.libraryID, id])
        }
        reload(); await drain(); beginWorker()
    }

    func change(_ id: String, action: String = "settings", settings: PublishingSettings? = nil, path: String? = nil, password: String? = nil, emails: [String]? = nil, domains: [String]? = nil) async throws {
        guard valid(), !busy, let service, let job = jobs[id] else { throw PublishingFailure.authenticationRequired }
        let session = generation; busy = true; defer { if generation == session { busy = false } }
        let current = try await service.status(job.status)
        let status: PublicationStatus
        if action == "settings", let settings, settings.allowFollowLinkedContent != current.settings.allowFollowLinkedContent, current.active {
            status = try await service.update(documentID: id, publication: current, settings: settings)
        } else if action == "access" {
            status = try await service.configure(current, path: path, password: password, emails: emails, domains: domains)
        } else { status = try await service.change(action, publication: current, settings: settings) }
        guard valid(session) else { throw CancellationError() }
        try cache(status, intent: job.intent, sequence: job.sequence, clean: !job.dirty)
        if current.settings.showAuthor != status.settings.showAuthor { profileChanged() }
    }
}
