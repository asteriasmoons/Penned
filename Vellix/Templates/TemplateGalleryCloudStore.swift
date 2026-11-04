import Foundation

/// Public gallery reads and authenticated administrator mutations.
@MainActor
final class TemplateGalleryCloudStore {
    private let configuration: SupabaseConfiguration?
    private let session: URLSession

    init(configuration: SupabaseConfiguration? = nil, session: URLSession = .shared) {
        self.configuration = configuration ?? (try? SupabaseConfiguration.load())
        self.session = session
    }

    private func request(_ resource: String, method: String = "GET",
                         token: String? = nil, body: Data? = nil) async throws -> Data {
        guard !resource.contains("..") else { throw PublishingFailure.invalidContent("Invalid gallery path.") }
        guard let configuration else { throw PublishingFailure.unavailable("Gallery service is not configured.") }
        var request = URLRequest(url: configuration.url.appendingPathComponent(
            "functions/v1/penned-gallery/" + resource))
        request.httpMethod = method
        request.httpBody = body
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PublishingFailure.unavailable("No gallery response.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PublishingFailure.authenticationRequired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PublishingFailure.unavailable("Gallery request failed (\(http.statusCode)).")
        }
        return data
    }

    private struct CategoryRow: Decodable {
        let id: String
        let title: String
        let sort_order: Double
        let created_at: Date
        let updated_at: Date
    }

    private struct TemplateRow: Decodable {
        let id: String
        let category_id: String
        let title: String
        let description: String
        let revision: Int
        let sort_order: Double
        let created_at: Date
        let updated_at: Date
    }

    private var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Self.parseTimestamp(try container.decode(String.self))
        }
        return value
    }

    /// Postgres timestamptz values arrive with variable-precision fractional
    /// seconds (".63", ".89083") and a "+00" style offset that ISO8601DateFormatter
    /// rejects. These dates are only used for sorting/display, so parsing never
    /// fails the whole catalog: on an unrecognized value we fall back to a sentinel.
    static func parseTimestamp(_ raw: String) -> Date {
        let iso = ISO8601DateFormatter()
        for options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] as [ISO8601DateFormatter.Options] {
            iso.formatOptions = options
            if let date = iso.date(from: raw) { return date }
        }
        var normalized = raw.replacingOccurrences(of: " ", with: "T")
        normalized = normalized.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        if normalized.range(of: #"[+-]\d{2}$"#, options: .regularExpression) != nil {
            normalized += ":00"
        } else if normalized.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) == nil {
            normalized += "Z"
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: normalized) ?? .distantPast
    }

    func fetchCategories() async throws -> [GalleryCategory] {
        try decoder.decode([CategoryRow].self, from: await request("categories")).map {
            GalleryCategory(id: $0.id, title: $0.title, sortOrder: $0.sort_order,
                            createdAt: $0.created_at, updatedAt: $0.updated_at)
        }
    }

    func fetchTemplates() async throws -> [GalleryTemplate] {
        try decoder.decode([TemplateRow].self, from: await request("templates")).map { metadata($0) }
    }

    private func metadata(_ row: TemplateRow) -> GalleryTemplate {
        GalleryTemplate(id: row.id, categoryID: row.category_id, title: row.title,
            templateDescription: row.description, revision: row.revision,
            sortOrder: row.sort_order, createdAt: row.created_at, updatedAt: row.updated_at)
    }

    func fetchPackage(templateID: String, expectedRevision: Int? = nil) async throws -> TemplateGalleryPackage {
        struct PackageRow: Decodable { let package: TemplateGalleryPackage }
        let row = try JSONDecoder().decode(PackageRow.self, from: await request("templates/" + templateID))
        try row.package.validateForImport(expectedID: templateID, expectedRevision: expectedRevision)
        return row.package
    }

    private func adminToken() async throws -> String {
        guard let identity = try KeychainAccountSessionStore().currentIdentity(),
              case .apple(let subject) = identity,
              TemplateGalleryAuthorization.canShowPublishingControls(appleUserID: subject) else {
            throw PublishingFailure.authenticationRequired
        }
        return try await PublishingAppleAuth().accessToken(for: identity)
    }

    func saveCategory(id: String? = nil, title: String, sortOrder: Double = 0) async throws {
        struct Input: Encodable { let title: String; let sort_order: Double }
        let _: Data = try await request(id.map { "categories/" + $0 } ?? "categories",
            method: id == nil ? "POST" : "PUT", token: try await adminToken(),
            body: JSONEncoder().encode(Input(title: title, sort_order: sortOrder)))
    }

    func deleteCategory(id: String) async throws {
        _ = try await request("categories/" + id, method: "DELETE", token: try await adminToken())
    }

    @discardableResult
    func saveTemplate(_ package: TemplateGalleryPackage, description: String,
                      sortOrder: Double = 0, updating: Bool = false) async throws -> GalleryTemplate {
        struct Input: Encodable {
            let title: String
            let description: String
            let category_id: String
            let revision: Int
            let expectedRevision: Int?
            let sort_order: Double
            let package: TemplateGalleryPackage
        }
        try package.validateForImport()
        let data = try await request(updating ? "templates/" + package.galleryTemplateID : "templates",
            method: updating ? "PUT" : "POST", token: try await adminToken(),
            body: JSONEncoder().encode(Input(title: package.title, description: description,
                category_id: package.categoryID, revision: package.revision,
                expectedRevision: updating ? package.revision - 1 : nil,
                sort_order: sortOrder, package: package)))
        return metadata(try decoder.decode(TemplateRow.self, from: data))
    }

    func deleteTemplate(id: String) async throws {
        _ = try await request("templates/" + id, method: "DELETE", token: try await adminToken())
    }
}
