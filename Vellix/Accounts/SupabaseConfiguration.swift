import Foundation

struct SupabaseConfiguration: Equatable, Sendable {
    let url: URL
    let publishableKey: String
    var projectID: String { url.absoluteString }

    static func load(bundle: Bundle = .main) throws -> Self {
        try Self(values: bundle.infoDictionary ?? [:])
    }

    init(values: [String: Any]) throws {
        let address = (values["SUPABASE_URL"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (values["SUPABASE_PUBLISHABLE_KEY"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.contains("$("), !key.contains("$("),
              !address.localizedCaseInsensitiveContains("YOUR_SUPABASE_"),
              !key.localizedCaseInsensitiveContains("YOUR_SUPABASE_"),
              !key.contains(where: \.isWhitespace) else { throw EmailAuthError.configurationMissing }
        guard var components = URLComponents(string: address), components.scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", key.hasPrefix("sb_publishable_"),
              key.count > "sb_publishable_".count else { throw EmailAuthError.configurationMissing }
        components.host = host.lowercased()
        components.path = ""
        guard let url = components.url else { throw EmailAuthError.configurationMissing }
        self.url = url
        self.publishableKey = key
    }
}
