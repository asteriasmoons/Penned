import Foundation
import GRDB
import Testing
@testable import Vellix

private final class QueueHTTP: URLProtocol {
    nonisolated(unsafe) static var response: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "queue.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let response = Self.response else { throw URLError(.notConnectedToInternet) }
            let (code, data) = try response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    nonisolated static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

@Suite(.serialized) @MainActor
struct PublishingQueueTests {
    @Test func enablingFollowBlockLinksUploadsChildrenInOneParentUpdateWithoutCreatingChildPublications() async throws {
        let (db, docs, document, original, client) = try setup(); var status = original, commits = 0
        QueueHTTP.response = { request in
            if request.url!.path.hasSuffix("/list") { return (200, try JSONEncoder().encode([status])) }
            if request.httpMethod == "GET" { return (200, try JSONEncoder().encode(status)) }
            #expect(request.httpMethod == "PUT")
            #expect(request.url!.path.hasSuffix("/publications/" + status.id))
            let input = try QueueHTTP.body(request), saved = try #require(input["document"] as? [String: Any])
            let enabled = (input["settings"] as? [String: Any])?["allowFollowLinkedContent"] as? Bool ?? status.settings.allowFollowLinkedContent
            if enabled { #expect((saved["linkedPages"] as? [[String: Any]])?.count == 1) }
            else { #expect(saved["linkedPages"] == nil) }
            commits += 1; status.version += 1; status.settings.allowFollowLinkedContent = enabled
            status.sourceFingerprint = input["sourceFingerprint"] as? String
            return (200, try JSONEncoder().encode(status))
        }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: { "test" }, client: client, runWorker: false)
        await queue.discover()
        let child = try docs.create(DocumentDraft(title: "Unpublished child", parentDocumentID: document.id))
        var settings = status.settings; settings.allowFollowLinkedContent = true
        try await queue.change(document.id, settings: settings)
        #expect(commits == 1); #expect(queue.jobs.count == 1)
        #expect(queue.jobs[document.id]?.status.settings.allowFollowLinkedContent == true)
        await queue.drain(); #expect(commits == 1)
        _ = try docs.saveEditorJSON(id: child.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "paragraph", "content": [["type": "text", "text": "Saved child edit"]]]]))
        await queue.drain(); #expect(commits == 2)
        settings.allowFollowLinkedContent = false
        try await queue.change(document.id, settings: settings)
        #expect(commits == 3); #expect(queue.jobs[document.id]?.status.settings.allowFollowLinkedContent == false)
        queue.stop()
    }
    @Test func authorPhotoUpgradeIsDurableWithoutTreatingMatchingSavedContentAsAStaleDevice() async throws {
        let (db, _, document, original, client) = try setup(); var status = original
        status.settings.showAuthor = true
        QueueHTTP.response = { _ in (200, try JSONEncoder().encode([status])) }; defer { QueueHTTP.response = nil }
        let photo = try publishingAvatarPNG(), queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: { "test" }, client: client, runWorker: false, authorAvatar: { photo })
        await queue.discover()
        #expect(queue.jobs[document.id]?.dirty == true); #expect(queue.jobs[document.id]?.blocked == false)
        let sequence = queue.jobs[document.id]?.sequence
        queue.profileChanged(); #expect(queue.jobs[document.id]?.sequence == (sequence ?? 0) + 1)
        queue.stop()
        queue.profileChanged(); #expect(queue.jobs.isEmpty)
    }
    @Test func cachedVercelLinksMoveToPennedWithoutChangingThePublicPathOrOtherDomains() throws {
        let (_, _, _, original, _) = try setup()
        var status = original
        status.publicURL = try #require(URL(string: "https://penned-site-pi.vercel.app/p/custom-saved-path"))
        status.usePennedDomain()
        #expect(status.publicURL.absoluteString == "https://penned.im/p/custom-saved-path")
        status.publicURL = original.publicURL; status.usePennedDomain()
        #expect(status.publicURL == original.publicURL)
    }

    @Test func pendingJobsSurviveClosingAndReopeningTheSQLiteFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try DatabaseQueue(path: path), first = try AppDatabase(writer)
        try first.writeMetadata { db in
            try db.execute(sql: "INSERT INTO publicationJobs(ownerKey,libraryID,documentID,statusJSON,intent,dirty) VALUES('owner','local','saved','{}','stop',1)")
        }
        try writer.close()
        let reopenedWriter = try DatabaseQueue(path: path), reopened = try AppDatabase(reopenedWriter)
        #expect(try reopened.read { try String.fetchOne($0, sql: "SELECT intent FROM publicationJobs WHERE documentID='saved'") } == "stop")
        #expect(try reopened.read { try Int.fetchOne($0, sql: "SELECT dirty FROM publicationJobs WHERE documentID='saved'") } == 1)
        try reopenedWriter.close()
    }

    @Test func liveNativeQueueWhenExplicitlyAuthorized() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["PENNED_LIVE_QUEUE_TOKEN"], let subject = env["PENNED_LIVE_QUEUE_USER"], let url = env["PENNED_LIVE_QUEUE_URL"], let key = env["PENNED_LIVE_QUEUE_KEY"] else { return }
        let database = try AppDatabase.makeInMemory(), docs = DocumentRepository(database: database)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AttachmentStore(rootURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try docs.create(DocumentDraft(title: "Native queue live check"))
        _ = try docs.create(DocumentDraft(title: "PRIVATE UNRELATED CANARY"))
        let file = try docs.attachmentRepository(store: store).importData(Data("Actual live native attachment".utf8), originalFileName: "native.txt", mimeType: "text/plain", documentID: page.id)
        _ = try docs.saveEditorJSON(id: page.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: [
            ["type": "paragraph", "content": [["type": "text", "text": "Saved native writing"]]],
            ["type": "attachment", "attrs": ["file": ["kind": "file", "relativePath": file.relativePath]]]
        ]))
        let client = PublishingClient(configuration: try SupabaseConfiguration(values: ["SUPABASE_URL": url, "SUPABASE_PUBLISHABLE_KEY": key]))
        let queue = PublishingQueue(database: database, store: store)
        let identity = AccountIdentity.email(project: url, userID: try #require(UUID(uuidString: subject)))
        queue.start(identity: { identity }, accessToken: { token }, client: client, runWorker: false)
        defer { queue.stop() }
        try await queue.publish(page.id)
        let initial = try #require(queue.jobs[page.id]?.status)
        struct PublicValue: Decodable { let document: PublishingDocument }
        let before: PublicValue = try await client.request(path: "public/" + initial.token, method: "GET")
        #expect(before.document.title == page.title)
        #expect(!String(decoding: try JSONEncoder().encode(before.document), as: UTF8.self).contains("PRIVATE"))
        _ = try docs.updateTitle(id: page.id, title: "Automatically updated by native queue")
        var appearance = page.appearance; appearance.textColorHex = "#45F7DF"
        _ = try docs.updateAppearance(id: page.id, cover: nil, appearance: appearance)
        await queue.drain()
        #expect(queue.jobs[page.id]?.dirty == false)
        let after: PublicValue = try await client.request(path: "public/" + initial.token, method: "GET")
        #expect(after.document.title == "Automatically updated by native queue")
        #expect(String(decoding: try JSONEncoder().encode(after.document.appearance), as: UTF8.self).contains("#45F7DF"))
        let updated = try #require(queue.jobs[page.id]?.status)
        #expect(updated.version == initial.version + 1)
        #expect(updated.uploadedMedia == initial.uploadedMedia)
        try await queue.stopPublishing(page.id)
        #expect(queue.jobs[page.id]?.status.active == false)
        do { let _: PublicValue = try await client.request(path: "public/" + initial.token, method: "GET"); Issue.record("Unpublished content remained readable") } catch { }
        let asset = try #require(initial.uploadedMedia?.first)
        let (_, response) = try await URLSession.shared.data(from: URL(string: url + "/functions/v1/penned-publishing/public/" + initial.token + "/media/" + asset.id)!)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }
    private func setup() throws -> (AppDatabase, DocumentRepository, DocumentRecord, PublicationStatus, PublishingClient) {
        let db = try AppDatabase.makeInMemory(), docs = DocumentRepository(database: db), document = try docs.create(DocumentDraft(title: "Queue document"))
        let prepared = try PublishingDocumentBuilder(database: db, attachmentStore: .previewStore()).prepare(documentID: document.id, owner: .apple("owner"))
        let status = PublicationStatus(id: UUID().uuidString.lowercased(), sourceLibraryID: db.libraryID, sourceDocumentID: document.id, version: 1, active: true,
            token: String(repeating: "a", count: 64), publicURL: URL(string: "https://example.com/p/test")!, settings: .init(), updatedAt: "2026-10-25T12:00:00Z", sourceFingerprint: try prepared.document.fingerprint())
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [QueueHTTP.self]
        let client = PublishingClient(configuration: try SupabaseConfiguration(values: ["SUPABASE_URL": "https://queue.example.com", "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_fixture"]), session: URLSession(configuration: configuration))
        return (db, docs, document, status, client)
    }

    @Test func metadataAndDependentSavesAreDurableAndRollbackDoesNotQueue() async throws {
        let (db, docs, document, status, client) = try setup()
        QueueHTTP.response = { _ in (200, try JSONEncoder().encode([status])) }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: { "test" }, client: client, runWorker: false)
        await queue.discover(); #expect(queue.jobs[document.id]?.dirty == false)
        _ = try docs.updateTitle(id: document.id, title: "Only title changed")
        queue.reload(); #expect(queue.jobs[document.id]?.dirty == true)
        let sequence = try db.read { try Int.fetchOne($0, sql: "SELECT sequence FROM publicationJobs")! }
        struct Rollback: Error {}
        #expect(throws: Rollback.self) {
            try db.write { db in try db.execute(sql: "UPDATE documents SET title='Must roll back' WHERE id=?", arguments: [document.id]); throw Rollback() }
        }
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT sequence FROM publicationJobs") } == sequence)
        queue.stop()
        let reopened = PublishingQueue(database: db, store: .previewStore())
        reopened.start(identity: { .apple("owner") }, accessToken: { "test" }, client: client, runWorker: false)
        #expect(reopened.jobs[document.id]?.dirty == true)
        reopened.stop()
    }

    @Test func offlineRetryUploadsSavedTitleAndCoalescesUnrelatedSaves() async throws {
        let (db, docs, document, original, client) = try setup(); var status = original, uploads = 0, offline = false
        QueueHTTP.response = { request in
            if offline { throw URLError(.notConnectedToInternet) }
            if request.url!.path.hasSuffix("/list") { return (200, try JSONEncoder().encode([status])) }
            let input = try QueueHTTP.body(request)
            #expect(input["action"] as? String == "update"); #expect((input["document"] as? [String: Any])?["title"] as? String == "Saved offline")
            #expect(input["settings"] == nil)
            uploads += 1; status.version += 1; status.sourceFingerprint = input["sourceFingerprint"] as? String
            return (200, try JSONEncoder().encode(status))
        }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: { "test" }, client: client, runWorker: false)
        await queue.discover(); _ = try docs.updateTitle(id: document.id, title: "Saved offline")
        offline = true; await queue.drain(); #expect(queue.jobs[document.id]?.dirty == true); #expect(uploads == 0)
        offline = false; queue.retry(); await queue.drain(); #expect(uploads == 1); #expect(queue.jobs[document.id]?.dirty == false)
        _ = try docs.create(DocumentDraft(title: "PRIVATE unrelated"))
        await queue.drain(); #expect(uploads == 1)
        queue.stop()
    }

    @Test func conflictBlocksStaleDeviceAndTrashStillRevokes() async throws {
        let (db, docs, document, original, client) = try setup(); var status = original, updates = 0, stops = 0
        QueueHTTP.response = { request in
            if request.url!.path.hasSuffix("/list") { return (200, try JSONEncoder().encode([status])) }
            if request.httpMethod == "PUT" { updates += 1; return (409, Data("{\"error\":\"conflict\"}".utf8)) }
            if request.url!.path.hasSuffix("/unpublish") { stops += 1; status.active = false; status.version += 1 }
            return (200, try JSONEncoder().encode(status))
        }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: { "test" }, client: client, runWorker: false)
        await queue.discover(); _ = try docs.updateTitle(id: document.id, title: "Stale local edit")
        status.version += 1; status.sourceFingerprint = String(repeating: "f", count: 64)
        await queue.drain(); #expect(updates == 1); #expect(queue.jobs[document.id]?.blocked == true)
        _ = try docs.trash(id: document.id); queue.retry(); await queue.drain()
        #expect(stops == 1); #expect(queue.jobs[document.id]?.intent == "inactive")
        queue.stop()
    }

    @Test func offlineTrashPersistsRevocationEvenIfTheDocumentIsRestoredBeforeConnecting() async throws {
        let (db, docs, document, status, client) = try setup()
        QueueHTTP.response = { _ in (200, try JSONEncoder().encode([status])) }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: { "test" }, client: client, runWorker: false)
        await queue.discover(); _ = try docs.trash(id: document.id)
        try db.write { try $0.execute(sql: "UPDATE documents SET isTrashed=0 WHERE id=?", arguments: [document.id]) }
        queue.reload(); #expect(queue.jobs[document.id]?.intent == "stop"); #expect(queue.jobs[document.id]?.dirty == true)
        queue.stop()
    }

    @Test func unpublishedRemoteCannotBeReactivatedByQueuedUpdateOrRestart() async throws {
        let (db, docs, document, original, client) = try setup(); var status = original
        QueueHTTP.response = { request in
            if request.url!.path.hasSuffix("/list") { return (200, try JSONEncoder().encode([status])) }
            if request.httpMethod == "PUT" { return (409, Data("{\"error\":\"inactive\"}".utf8)) }
            return (200, try JSONEncoder().encode(status))
        }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: { "test" }, client: client, runWorker: false)
        await queue.discover(); _ = try docs.updateTitle(id: document.id, title: "Delayed")
        status.active = false; status.version += 1
        await queue.drain(); #expect(queue.jobs[document.id]?.intent == "inactive")
        _ = try docs.updateTitle(id: document.id, title: "Still private")
        await queue.drain(); #expect(status.active == false)
        queue.stop()
    }

    @Test func switchingAccountsHidesAndStopsThePreviousQueue() async throws {
        let (db, docs, document, status, client) = try setup(); var identity: AccountIdentity? = .apple("owner"), requests = 0
        QueueHTTP.response = { _ in requests += 1; return (200, try JSONEncoder().encode([status])) }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { identity }, accessToken: { "test" }, client: client, runWorker: false)
        await queue.discover(); _ = try docs.updateTitle(id: document.id, title: "Pending owner change")
        identity = .apple("other"); await queue.drain(); #expect(requests == 1)
        queue.start(identity: { identity }, accessToken: { "other" }, client: client, runWorker: false)
        #expect(queue.jobs.isEmpty)
        queue.stop()
    }

    @Test func metadataOnlyRemoteChangesCanRebaseWithoutOverwritingAnotherDevicesContent() async throws {
        let (db, docs, document, original, client) = try setup(); var status = original, uploads = 0
        QueueHTTP.response = { request in
            if request.url!.path.hasSuffix("/list") { return (200, try JSONEncoder().encode([status])) }
            if request.httpMethod == "PUT" {
                let input = try QueueHTTP.body(request)
                if input["expectedVersion"] as? Int != status.version { return (409, Data("{\"error\":\"conflict\"}".utf8)) }
                uploads += 1; status.version += 1; status.sourceFingerprint = input["sourceFingerprint"] as? String
            }
            return (200, try JSONEncoder().encode(status))
        }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: { "test" }, client: client, runWorker: false)
        await queue.discover(); _ = try docs.updateTitle(id: document.id, title: "Pending local edit")
        status.version += 1; status.settings.showAuthor = true
        await queue.drain(); #expect(queue.jobs[document.id]?.blocked == false)
        await queue.drain(); #expect(uploads == 1); #expect(queue.jobs[document.id]?.dirty == false)
        queue.stop()
    }

    @Test func aSaveDuringUploadRemainsPendingUntilItsOwnVersionIsAcknowledged() async throws {
        let (db, docs, document, original, client) = try setup(); var status = original, armed = false, titles: [String] = []
        QueueHTTP.response = { request in
            if request.url!.path.hasSuffix("/list") { return (200, try JSONEncoder().encode([status])) }
            let input = try QueueHTTP.body(request)
            titles.append((input["document"] as! [String: Any])["title"] as! String)
            status.version += 1; status.sourceFingerprint = input["sourceFingerprint"] as? String
            return (200, try JSONEncoder().encode(status))
        }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: {
            if armed { armed = false; _ = try docs.updateTitle(id: document.id, title: "Saved during upload") }
            return "test"
        }, client: client, runWorker: false)
        await queue.discover(); _ = try docs.updateTitle(id: document.id, title: "First saved version"); armed = true
        await queue.drain(); #expect(queue.jobs[document.id]?.dirty == true)
        await queue.drain(); #expect(queue.jobs[document.id]?.dirty == false)
        #expect(titles == ["First saved version", "Saved during upload"])
        queue.stop()
    }

    @Test func aLostSuccessResponseReconcilesByFingerprintWithoutDuplicatingTheUpload() async throws {
        let (db, docs, document, original, client) = try setup(); var status = original, accepted = 0
        QueueHTTP.response = { request in
            if request.url!.path.hasSuffix("/list") { return (200, try JSONEncoder().encode([status])) }
            if request.httpMethod == "PUT" {
                let input = try QueueHTTP.body(request)
                if input["expectedVersion"] as? Int != status.version { return (409, Data("{\"error\":\"conflict\"}".utf8)) }
                accepted += 1; status.version += 1; status.sourceFingerprint = input["sourceFingerprint"] as? String
                throw URLError(.networkConnectionLost)
            }
            return (200, try JSONEncoder().encode(status))
        }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: { "test" }, client: client, runWorker: false)
        await queue.discover(); _ = try docs.updateTitle(id: document.id, title: "Acknowledgement was lost")
        await queue.drain(); #expect(queue.jobs[document.id]?.dirty == true)
        queue.retry(); await queue.drain(); #expect(queue.jobs[document.id]?.dirty == false); #expect(accepted == 1)
        queue.stop()
    }

    @Test func aPublicationMissingOnANewSyncingDeviceIsNeverInferredDeleted() async throws {
        let (db, _, _, original, client) = try setup(); var status = original, stops = 0
        status.sourceDocumentID = UUID().uuidString
        QueueHTTP.response = { request in
            if request.url!.path.hasSuffix("/unpublish") { stops += 1 }
            return (200, try JSONEncoder().encode([status]))
        }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: { "test" }, client: client, runWorker: false)
        await queue.discover(); await queue.drain()
        #expect(stops == 0); #expect(queue.jobs[status.sourceDocumentID]?.blocked == true)
        queue.stop()
    }

    @Test func stopPublishingInterruptsAnUploadBeforeItCanCommitOrReactivate() async throws {
        let (db, docs, document, original, client) = try setup(); var status = original, armed = false, updates = 0
        QueueHTTP.response = { request in
            if request.url!.path.hasSuffix("/list") { return (200, try JSONEncoder().encode([status])) }
            if request.httpMethod == "PUT" { updates += 1 }
            if request.url!.path.hasSuffix("/unpublish") { status.active = false; status.version += 1 }
            return (200, try JSONEncoder().encode(status))
        }; defer { QueueHTTP.response = nil }
        let queue = PublishingQueue(database: db, store: .previewStore())
        queue.start(identity: { .apple("owner") }, accessToken: {
            if armed { armed = false; try await queue.stopPublishing(document.id) }
            return "test"
        }, client: client, runWorker: false)
        await queue.discover(); _ = try docs.updateTitle(id: document.id, title: "Must not upload after removal"); armed = true
        await queue.drain()
        #expect(updates == 0); #expect(queue.jobs[document.id]?.intent == "inactive"); #expect(status.active == false)
        queue.stop()
    }
}
