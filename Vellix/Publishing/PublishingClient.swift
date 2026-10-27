import Foundation

nonisolated struct PublishingClient: Sendable {
    let configuration: SupabaseConfiguration
    var session: URLSession = .shared

    func request<Response: Decodable>(path: String, method: String, token: String? = nil, body: Data? = nil,
                                     contentType: String = "application/json", fileName: String? = nil) async throws -> Response {
        guard !path.contains(".."), !path.contains("?"), !path.hasPrefix("/") else { throw PublishingFailure.invalidContent("Invalid API path.") }
        var request = URLRequest(url: configuration.url.appendingPathComponent("functions/v1/penned-publishing/" + path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 45
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let fileName {
            let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "File"
            request.setValue(encoded, forHTTPHeaderField: "X-File-Name")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PublishingFailure.unavailable("Invalid server response.") }
        if response.statusCode == 409 {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            if code == "path_taken" { throw PublishingFailure.invalidContent("That public URL is already in use. Choose another path.") }
            throw PublishingFailure.conflict
        }
        if response.statusCode == 401 { throw PublishingFailure.authenticationRequired }
        guard (200..<300).contains(response.statusCode) else {
            let error = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Request failed."
            throw PublishingFailure.unavailable(error)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func create(libraryID: String, documentID: String, token: String) async throws -> PublicationStatus {
        try await request(path: "publications", method: "POST", token: token,
                          body: JSONEncoder().encode(["sourceLibraryID": libraryID, "sourceDocumentID": documentID]))
    }

    func status(id: String, token: String) async throws -> PublicationStatus {
        try await request(path: "publications/" + checkedID(id), method: "GET", token: token)
    }

    func upload(_ asset: PublishingMedia, bytes: Data, publicationID: String, token: String) async throws -> PublishingMedia {
        try await request(path: "publications/" + checkedID(publicationID) + "/media/" + checkedID(asset.id), method: "PUT", token: token,
                          body: bytes, contentType: asset.mimeType, fileName: asset.name)
    }

    func commit(_ document: PublishingDocument, publication: PublicationStatus, settings: PublishingSettings?,
                publishing: Bool, token: String) async throws -> PublicationStatus {
        struct Commit: Encodable { let action: String; let expectedVersion: Int; let document: PublishingDocument; let settings: PublishingSettings?; let sourceFingerprint: String }
        return try await request(path: "publications/" + checkedID(publication.id), method: "PUT", token: token,
            body: JSONEncoder().encode(Commit(action: publishing ? "publish" : "update", expectedVersion: publication.version, document: document, settings: settings, sourceFingerprint: try document.fingerprint())))
    }

    func list(libraryID: String, token: String) async throws -> [PublicationStatus] {
        try await request(path: "publications/list", method: "POST", token: token, body: JSONEncoder().encode(["sourceLibraryID": libraryID]))
    }

    func configure(_ publication: PublicationStatus, path: String? = nil, password: String? = nil, emails: [String]? = nil, domains: [String]? = nil, token: String) async throws -> PublicationStatus {
        struct Input: Encodable { let expectedVersion: Int; let customPath: String?; let password: String?; let emails: [String]?; let emailDomains: [String]? }
        return try await request(path: "publications/" + checkedID(publication.id) + "/access", method: "POST", token: token,
            body: JSONEncoder().encode(Input(expectedVersion: publication.version, customPath: path, password: password, emails: emails, emailDomains: domains)))
    }

    func change(_ action: String, publication: PublicationStatus, settings: PublishingSettings? = nil, token: String) async throws -> PublicationStatus {
        guard ["settings", "unpublish", "regenerate"].contains(action) else { throw PublishingFailure.invalidContent("Unknown publication action.") }
        struct Change: Encodable { let expectedVersion: Int; let settings: PublishingSettings? }
        return try await request(path: "publications/" + checkedID(publication.id) + "/" + action, method: "POST", token: token,
                                 body: JSONEncoder().encode(Change(expectedVersion: publication.version, settings: settings)))
    }

    func revokeOwner(token: String) async throws {
        let _: [String: Bool] = try await request(path: "owner", method: "DELETE", token: token)
    }

    func removeMedia(id: String, publication: PublicationStatus, token: String) async throws {
        let _: [String: Bool] = try await request(path: "publications/" + checkedID(publication.id) + "/media/" + checkedID(id), method: "DELETE", token: token,
            body: JSONEncoder().encode(["expectedVersion": publication.version]))
    }

    private func checkedID(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw PublishingFailure.invalidContent("Invalid publication identifier.") }
        return value.lowercased()
    }
}
