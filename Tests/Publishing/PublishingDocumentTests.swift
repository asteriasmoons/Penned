import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import Vellix

@MainActor func publishingAvatarPNG() throws -> Data {
    let context = try #require(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.7, green: 0.4, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
    let image = try #require(context.makeImage()), data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite @MainActor
struct PublishingDocumentTests {
    @Test func authorPhotoIsNormalizedStableAndScopedWithoutExportingPrivateAccountFields() throws {
        let db = try AppDatabase.makeInMemory(), docs = DocumentRepository(database: db)
        let first = try docs.create(DocumentDraft(title: "First")), second = try docs.create(DocumentDraft(title: "Second"))
        let builder = PublishingDocumentBuilder(database: db, attachmentStore: .previewStore()), image = try publishingAvatarPNG()
        let one = try builder.prepare(documentID: first.id, owner: .apple("owner"), authorAvatarData: image)
        let again = try builder.prepare(documentID: first.id, owner: .apple("owner"), authorAvatarData: image)
        let other = try builder.prepare(documentID: second.id, owner: .apple("owner"), authorAvatarData: image)
        #expect(one.document.authorAvatar != nil); #expect(one.document.media == again.document.media)
        #expect(one.document.media.first?.id != other.document.media.first?.id)
        let bytes = try #require(one.files.values.first), source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 256)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(try builder.prepare(documentID: first.id, owner: .apple("owner")).document.authorAvatar == nil)
        #expect(throws: (any Error).self) { try builder.prepare(documentID: first.id, owner: .apple("owner"), authorAvatarData: Data("not an image".utf8)) }
    }
    @Test func nestedReferencesAndCollectionsDoNotExportPrivateData() throws {
        let root: [String: Any] = ["type": "doc", "attrs": ["taskHistoryProjection": "private-history"], "content": [
            ["type": "pageReference", "attrs": ["documentID": "private-child", "title": "PRIVATE TITLE"], "content": [["type": "text", "text": "PRIVATE BODY"]]],
            ["type": "collection", "attrs": ["collectionID": "private-collection", "entries": ["PRIVATE ENTRY"]]],
            ["type": "paragraph", "content": [["type": "text", "text": "Selected content"]]]
        ]]
        let result = try PublishingProjection.content(root, media: [:])
        let data = try JSONSerialization.data(withJSONObject: result)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("PRIVATE"))
        #expect(!text.contains("private-child"))
        #expect(!text.contains("private-collection"))
        #expect(!text.contains("private-history"))
        #expect(text.contains("privateReference"))
        #expect(text.contains("privateCollection"))
        #expect(text.contains("Selected content"))
        #expect(PublishingProjection.paths(in: root).isEmpty)
    }

    @Test func preparesOnlyTheSelectedDocumentWithoutEnablingCloudKit() throws {
        let database = try AppDatabase.makeInMemory()
        let repository = DocumentRepository(database: database)
        let parent = try repository.create(DocumentDraft(title: "PRIVATE PARENT"))
        let selected = try repository.create(DocumentDraft(title: "Selected", subtitle: "Subtitle", parentDocumentID: parent.id))
        _ = try repository.create(DocumentDraft(title: "PRIVATE SIBLING", parentDocumentID: parent.id))
        let builder = PublishingDocumentBuilder(database: database, attachmentStore: .previewStore())
        let prepared = try builder.prepare(documentID: selected.id, owner: .apple("owner"))
        #expect(prepared.sourceDocumentID == selected.id)
        #expect(prepared.document.title == "Selected")
        #expect(prepared.document.subtitle == "Subtitle")
        #expect(prepared.document.icon == selected.icon)
        #expect(prepared.document.schemaVersion == 1)
        #expect(prepared.document.media.isEmpty)
        let wire = String(decoding: try JSONEncoder().encode(prepared.document), as: UTF8.self)
        #expect(!wire.contains("PRIVATE"))
        #expect(!wire.contains(parent.id))
        #expect(!wire.contains("parentDocumentID"))
        #expect(try LibraryRepository(database: database).library(id: LibraryRecord.localID)?.syncEnabled == false)
    }

    @Test func anotherAccountsLibraryAndTrashedDocumentsCannotPublish() throws {
        let database = try AppDatabase.makeInMemory()
        let libraries = LibraryRepository(database: database)
        let owner = AccountIdentity.apple("owner")
        let library = try libraries.accountLibrary(ownerKey: owner.libraryOwnerKey)
        let scoped = database.scoped(to: library.id)
        let repository = DocumentRepository(database: scoped)
        let document = try repository.create(DocumentDraft(title: "Private"))
        let builder = PublishingDocumentBuilder(database: scoped, attachmentStore: .previewStore())
        #expect(throws: LibraryError.wrongOwner) { try builder.prepare(documentID: document.id, owner: .apple("other")) }
        _ = try repository.trash(id: document.id)
        #expect(throws: (any Error).self) { try builder.prepare(documentID: document.id, owner: owner) }
    }

    @Test func unknownNodesFailAndPrivateLinksAreRemoved() throws {
        #expect(throws: (any Error).self) { try PublishingProjection.content(["type": "futurePrivateBlock"], media: [:]) }
        let root: [String: Any] = ["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "Link", "marks": [["type": "link", "attrs": ["href": "penned://private/document"]]]]]]]]
        let wire = try JSONSerialization.data(withJSONObject: PublishingProjection.content(root, media: [:]))
        #expect(!String(decoding: wire, as: UTF8.self).contains("penned://"))
    }

    @Test func mediaAreReferencedExplicitlyAndRemainStableAcrossPreparations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.makeInMemory(), store = AttachmentStore(rootURL: directory)
        let repository = DocumentRepository(database: database)
        let selected = try repository.create(DocumentDraft(title: "Media document"))
        let unused = try repository.create(DocumentDraft(title: "PRIVATE OTHER DOCUMENT"))
        let attachments = repository.attachmentRepository(store: store)
        let file = try attachments.importData(Data("Approved attachment".utf8), originalFileName: "note.txt", mimeType: "text/plain", documentID: selected.id)
        _ = try attachments.importData(Data("PRIVATE FILE".utf8), originalFileName: "private.txt", mimeType: "text/plain", documentID: unused.id)
        let content: [String: Any] = ["type": "doc", "content": [["type": "attachment", "attrs": ["file": ["relativePath": file.relativePath, "kind": "file"]]]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)
        _ = try repository.saveEditorJSON(id: selected.id, canonicalJSON: json)
        let builder = PublishingDocumentBuilder(database: database, attachmentStore: store)
        let first = try builder.prepare(documentID: selected.id, owner: .apple("owner"))
        let second = try builder.prepare(documentID: selected.id, owner: .apple("owner"))
        #expect(first.document.media.count == 1)
        #expect(first.document.media == second.document.media)
        #expect(first.document.media.first?.name == "note.txt")
        #expect(first.files.values.first == Data("Approved attachment".utf8))
        let wire = String(decoding: try JSONEncoder().encode(first.document), as: UTF8.self)
        #expect(!wire.contains("relativePath"))
        #expect(!wire.contains(file.relativePath))
        #expect(!wire.contains("PRIVATE"))
    }
}

private final class PublishingServiceProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "publishing-service.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let respond = Self.respond else { throw URLError(.unsupportedURL) }
            let (status, data) = try respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

@Suite(.serialized) @MainActor
struct PublishingServiceTests {
    private func client() throws -> PublishingClient {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [PublishingServiceProtocol.self]
        return PublishingClient(configuration: try SupabaseConfiguration(values: ["SUPABASE_URL": "https://publishing-service.example.com", "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_fixture"]), session: URLSession(configuration: options))
    }

    private func status(document: DocumentRecord, database: AppDatabase, version: Int = 0, active: Bool = false) -> PublicationStatus {
        PublicationStatus(id: UUID().uuidString.lowercased(), sourceLibraryID: database.libraryID, sourceDocumentID: document.id,
            version: version, active: active, token: String(repeating: "a", count: 64), publicURL: URL(string: "https://example.com/public")!, settings: .init(), updatedAt: "2026-10-25T12:00:00Z")
    }

    @Test func selectedDocumentMediaAndVersionsFlowThroughTheRealNativeClient() async throws {
        let database = try AppDatabase.makeInMemory(), repository = DocumentRepository(database: database)
        let parent = try repository.create(DocumentDraft(title: "PRIVATE PARENT"))
        let selected = try repository.create(DocumentDraft(title: "Selected", parentDocumentID: parent.id))
        _ = try repository.create(DocumentDraft(title: "PRIVATE SIBLING", parentDocumentID: parent.id))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); PublishingServiceProtocol.respond = nil }
        let store = AttachmentStore(rootURL: directory), bytes = Data("Selected attachment".utf8)
        let child = try repository.create(DocumentDraft(title: "Visible Page", parentDocumentID: selected.id))
        let collection = try CollectionRepository(database: database, documents: repository).create(ownerID: selected.id, name: "Visible Collection", viewName: "Main", kind: .table)
        let file = try repository.attachmentRepository(store: store).importData(bytes, originalFileName: "selected.txt", mimeType: "text/plain", documentID: selected.id)
        let root: [String: Any] = ["type": "doc", "content": [
            ["type": "attachment", "attrs": ["file": ["kind": "file", "relativePath": file.relativePath]]],
            ["type": "pageReference", "attrs": ["documentID": child.id]],
            ["type": "collection", "attrs": ["collectionID": collection.record.id]]]]
        _ = try repository.saveEditorJSON(id: selected.id, canonicalJSON: String(decoding: JSONSerialization.data(withJSONObject: root), as: UTF8.self))
        let service = PublishingService(database: database, attachmentStore: store, client: try client(), currentIdentity: { .apple("owner") }, accessToken: { "fixture-access" })
        let prepared = try service.prepare(documentID: selected.id), draft = status(document: selected, database: database)
        var committed = draft; committed.version = 1; committed.active = true
        let draftData = try JSONEncoder().encode(draft), committedData = try JSONEncoder().encode(committed)
        let asset = try #require(prepared.document.media.first), assetData = try JSONEncoder().encode(asset)
        var paths: [String] = []
        PublishingServiceProtocol.respond = { request in
            paths.append(request.url!.path)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
            #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_fixture")
            if request.httpMethod == "POST" { return (201, draftData) }
            if request.url!.path.contains("/media/") {
                #expect(try PublishingServiceProtocol.body(request) == bytes)
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain")
                return (201, assetData)
            }
            let data = try PublishingServiceProtocol.body(request), wire = String(decoding: data, as: UTF8.self)
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(payload["action"] as? String == "publish")
            #expect(payload["expectedVersion"] as? Int == 0)
            #expect(!wire.contains("PRIVATE")); #expect(!wire.contains(parent.id)); #expect(!wire.contains("relativePath"))
            #expect(wire.contains("publishedPage")); #expect(wire.contains("publishedCollection"))
            return (200, committedData)
        }
        #expect(try await service.publish(documentID: selected.id) == committed)
        #expect(paths.count == 3)
        #expect(paths[1].hasSuffix("/media/" + asset.id))
    }

    @Test func accountSwitchDuringAuthenticationCannotUploadOrCommit() async throws {
        let database = try AppDatabase.makeInMemory(), document = try DocumentRepository(database: database).create(DocumentDraft(title: "Selected"))
        var identity: AccountIdentity = .apple("owner")
        let service = PublishingService(database: database, attachmentStore: .previewStore(), client: try client(), currentIdentity: { identity }, accessToken: { identity = .apple("another"); return "wrong-account" })
        PublishingServiceProtocol.respond = { _ in Issue.record("No network request may follow an account switch"); throw URLError(.cancelled) }
        defer { PublishingServiceProtocol.respond = nil }
        await #expect(throws: CancellationError.self) { try await service.publish(documentID: document.id) }
    }

    @Test func cancelledPublishingCannotCreateADraft() async throws {
        let database = try AppDatabase.makeInMemory(), document = try DocumentRepository(database: database).create(DocumentDraft(title: "Selected"))
        let service = PublishingService(database: database, attachmentStore: .previewStore(), client: try client(), currentIdentity: { .apple("owner") }, accessToken: { "token" })
        PublishingServiceProtocol.respond = { _ in Issue.record("Cancelled publishing reached the server"); throw URLError(.cancelled) }
        defer { PublishingServiceProtocol.respond = nil }
        let task = Task { try await service.publish(documentID: document.id) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func anotherDocumentsPublicationIsRejectedBeforeNetworking() async throws {
        let database = try AppDatabase.makeInMemory(), repository = DocumentRepository(database: database)
        let selected = try repository.create(DocumentDraft(title: "Selected")), other = try repository.create(DocumentDraft(title: "Other"))
        let service = PublishingService(database: database, attachmentStore: .previewStore(), client: try client(), currentIdentity: { .apple("owner") }, accessToken: { "token" })
        PublishingServiceProtocol.respond = { _ in Issue.record("Mismatched publication reached the server"); throw URLError(.cancelled) }
        defer { PublishingServiceProtocol.respond = nil }
        let publication = status(document: other, database: database)
        await #expect(throws: (any Error).self) { try await service.publish(documentID: selected.id, replacing: publication) }
    }

    @Test func serverConflictsAreSurfacedWithoutRetryingOrReactivating() async throws {
        let database = try AppDatabase.makeInMemory(), document = try DocumentRepository(database: database).create(DocumentDraft(title: "Selected"))
        let publication = status(document: document, database: database, version: 8, active: false)
        let service = PublishingService(database: database, attachmentStore: .previewStore(), client: try client(), currentIdentity: { .apple("owner") }, accessToken: { "token" })
        var calls = 0
        PublishingServiceProtocol.respond = { request in
            calls += 1
            let payload = try #require(JSONSerialization.jsonObject(with: PublishingServiceProtocol.body(request)) as? [String: Any])
            #expect(payload["action"] as? String == "update")
            #expect(payload["expectedVersion"] as? Int == 8)
            return (409, Data("{\"error\":\"inactive\"}".utf8))
        }
        defer { PublishingServiceProtocol.respond = nil }
        await #expect(throws: PublishingFailure.conflict) { try await service.update(documentID: document.id, publication: publication, settings: .init()) }
        #expect(calls == 1)
    }

    @Test func uploadedDigestMismatchCannotCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); PublishingServiceProtocol.respond = nil }
        let database = try AppDatabase.makeInMemory(), repository = DocumentRepository(database: database), store = AttachmentStore(rootURL: directory)
        let document = try repository.create(DocumentDraft(title: "Selected"))
        let file = try repository.attachmentRepository(store: store).importData(Data("Selected".utf8), originalFileName: "note.txt", mimeType: "text/plain", documentID: document.id)
        let root: [String: Any] = ["type": "doc", "content": [["type": "attachment", "attrs": ["file": ["kind": "file", "relativePath": file.relativePath]]]]]
        _ = try repository.saveEditorJSON(id: document.id, canonicalJSON: String(decoding: JSONSerialization.data(withJSONObject: root), as: UTF8.self))
        let service = PublishingService(database: database, attachmentStore: store, client: try client(), currentIdentity: { .apple("owner") }, accessToken: { "token" })
        let publication = status(document: document, database: database)
        var asset = try #require(service.prepare(documentID: document.id).document.media.first)
        asset.sha256 = String(repeating: "0", count: 64)
        let assetData = try JSONEncoder().encode(asset)
        var calls = 0
        PublishingServiceProtocol.respond = { request in
            calls += 1
            #expect(request.url!.path.contains("/media/"))
            return (201, assetData)
        }
        await #expect(throws: (any Error).self) { try await service.publish(documentID: document.id, replacing: publication) }
        #expect(calls == 1)
    }
}
