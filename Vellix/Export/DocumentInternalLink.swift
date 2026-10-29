import Foundation

// One canonical private route shared by the Link sheet and semantic exporters.
// Public URLs continue to come exclusively from PublishingQueue.
enum DocumentInternalLink {
    static func url(documentID: String, libraryID: String, spaceID: String?) -> URL {
        var value = URLComponents()
        value.scheme = "penned"; value.host = "document"; value.path = "/" + documentID
        value.queryItems = [URLQueryItem(name: "library", value: libraryID)]
        if let spaceID { value.queryItems?.append(URLQueryItem(name: "space", value: spaceID)) }
        return value.url!
    }

    @MainActor static func resolve(_ url: URL, environment: AppEnvironment,
                                  switchSpace: ((String) async throws -> Void)? = nil) async throws -> DocumentRecord? {
        guard url.scheme?.lowercased() == "penned", url.host == "document" else { return nil }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.first(where: { $0.name == "library" })?.value == environment.database.libraryID else {
            throw DocumentExportError.failed("This is a private document link for another library. Switch to its account in Account Settings before opening it.")
        }
        let id = url.pathComponents.dropFirst().joined(separator: "/")
        guard !id.isEmpty, id.count <= 300, !id.contains("/"), id.rangeOfCharacter(from: .controlCharacters) == nil else { throw DocumentExportError.failed("This document link is invalid.") }
        let spaceID = parts.queryItems?.first(where: { $0.name == "space" })?.value
        if let spaceID, spaceID != environment.selectedSpaceID {
            if let switchSpace { try await switchSpace(spaceID) }
            else { try await environment.switchSpace(to: spaceID) }
        }
        let page = try environment.documents.requireDocument(id: id)
        guard !page.isTrashed, page.spaceID == environment.selectedSpaceID else { throw LibraryError.staleWorkspace }
        return page
    }
}
