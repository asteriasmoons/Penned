import Foundation
import Darwin

// Shared by Penned, the companion app and its extension. No authentication credentials.
nonisolated struct ClipperDestination: Codable, Sendable {
    var id: String
    var title: String
    var spaceID: String?
    var parentID: String?
    var image: String?
}
nonisolated struct ClipperConnection: Codable, Sendable {
    var sessionID: String
    var ownerID: String
    var libraryID: String
    var accountName: String
    var avatar: String?
    var selectedSpaceID: String?
    var spaces: [ClipperDestination]
    var folders: [ClipperDestination]
    var tags: [ClipperDestination]
    var icons: [String: String]
}
nonisolated struct ClipperNode: Codable, Sendable {
    var type: String
    var text: String?
    var content: [ClipperNode]?
    var marks: [ClipperMark]?
    var attrs: ClipperAttributes?
}
nonisolated struct ClipperMark: Codable, Sendable {
    var type: String
    var attrs: ClipperAttributes?
}
nonisolated struct ClipperAttributes: Codable, Sendable {
    var level: Int?
    var start: Int?
    var src: String?
    var alt: String?
    var href: String?
    var language: String?
    var colspan: Int?
    var rowspan: Int?
    var checked: Bool?
}
nonisolated struct ClipperSubmission: Codable, Sendable {
    var id: String
    var sessionID: String
    var spaceID: String
    var folderID: String?
    var tagIDs: [String]
    var title: String
    var author: String
    var siteName: String
    var sourceURL: String
    var notes: String
    var content: [ClipperNode]
    var thumbnailURL: String? = nil
}
nonisolated struct ClipperAsset: Codable, Sendable {
    var source: String
    var filename: String
    var mimeType: String
}
nonisolated struct ClipperEnvelope: Codable, Sendable {
    var ownerID: String
    var libraryID: String
    var createdAt: Date
    var submission: ClipperSubmission
    var assets: [ClipperAsset]
}
nonisolated struct ClipperResult: Codable, Sendable {
    var state: String
    var documentID: String?
    var message: String?
}
nonisolated enum ClipperError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
nonisolated enum ClipperShared {
    static let appGroup = "group.com.asteriasmoons.Penned"
    static let notification = "im.penned.webclip.inbox"
    static let maxPayload = 8 * 1024 * 1024
    static let maxAsset = 12 * 1024 * 1024
    static let maxAssetsBytes = 80 * 1024 * 1024

    static func directory() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw ClipperError.message("Enable the shared Penned App Group for Penned, Penned Web Clipper and its Safari extension in Signing & Capabilities.")
        }
        let root = container.appendingPathComponent("WebClipper", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return root
    }
    static func locked<T>(_ body: () throws -> T) throws -> T {
        let url = try directory().appendingPathComponent("inbox.lock")
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ClipperError.message("Penned's clip inbox is unavailable.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ClipperError.message("Penned's clip inbox is busy. Please retry.") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func read<T: Decodable>(_ type: T.Type, at url: URL, limit: Int = maxPayload) throws -> T {
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size <= limit else { throw ClipperError.message("The clip file is invalid or too large.") }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    static func connection() throws -> ClipperConnection? {
        let url = try directory().appendingPathComponent("connection.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try read(ClipperConnection.self, at: url)
    }
    static func disconnect() throws {
        try locked {
            let url = try directory().appendingPathComponent("connection.json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    static func clipDirectory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ClipperError.message("Invalid clip identifier.") }
        return try directory().appendingPathComponent(id.lowercased() + ".clip", isDirectory: true)
    }
    static func validate(_ request: ClipperSubmission, connection: ClipperConnection) throws {
        guard UUID(uuidString: request.id) != nil, request.sessionID == connection.sessionID else {
            throw ClipperError.message("Your Penned account changed. Reopen the clipper before saving.")
        }
        guard connection.spaces.contains(where: { $0.id == request.spaceID }),
              request.folderID == nil || connection.folders.contains(where: { $0.id == request.folderID && $0.spaceID == request.spaceID }),
              request.tagIDs.count <= 100,
              request.tagIDs.allSatisfy({ id in connection.tags.contains { $0.id == id && $0.spaceID == request.spaceID } }) else {
            throw ClipperError.message("This destination changed. Choose a Space, folder and tags again.")
        }
        guard !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.title.count <= 1000,
              request.author.count <= 1000, request.siteName.count <= 1000, request.notes.count <= 50_000,
              request.thumbnailURL == nil || request.thumbnailURL.map({ webURL($0) != nil || isImageDataURL($0) }) == true,
              webURL(request.sourceURL) != nil, !request.content.isEmpty else {
            throw ClipperError.message("The article title, URL or content is invalid.")
        }
        var count = 0
        let allowed: [String: Set<String>] = [
                "doc": ["paragraph", "heading", "caption", "blockquote", "bulletList", "orderedList", "taskList", "codeBlock", "image", "divider", "table"],
                "paragraph": ["text", "hardBreak"], "heading": ["text", "hardBreak"], "caption": ["text", "hardBreak"],
                "blockquote": ["paragraph", "heading", "caption", "blockquote", "bulletList", "orderedList", "taskList", "codeBlock", "image", "table", "divider"],
                "bulletList": ["listItem"], "orderedList": ["listItem"], "taskList": ["taskItem"],
                "listItem": ["paragraph", "heading", "caption", "bulletList", "orderedList", "taskList", "blockquote", "image", "codeBlock", "table", "divider"],
                "taskItem": ["paragraph", "heading", "caption", "bulletList", "orderedList", "taskList", "blockquote", "image", "codeBlock", "table", "divider"],
                "codeBlock": ["text"], "table": ["tableRow"], "tableRow": ["tableCell", "tableHeader"],
                "tableCell": ["paragraph", "heading", "caption", "bulletList", "orderedList", "taskList", "blockquote", "image", "codeBlock", "table", "divider"],
                "tableHeader": ["paragraph", "heading", "caption", "bulletList", "orderedList", "taskList", "blockquote", "image", "codeBlock", "table", "divider"]
        ]
        func visit(_ node: ClipperNode, depth: Int, parent: String) throws {
            count += 1
            guard count <= 50_000, depth <= 48 else { throw ClipperError.message("This article is too complex to clip safely.") }
            guard allowed[parent]?.contains(node.type) == true else { throw ClipperError.message("This article contains an unsupported block structure.") }
            if node.type == "text" { guard let text = node.text, !text.isEmpty else { throw ClipperError.message("The article contains invalid text.") }; return try validateMarks(node.marks) }
            guard node.marks?.isEmpty != false, node.text == nil else { throw ClipperError.message("The article contains invalid block formatting.") }
            if node.type == "image" {
                guard let source = node.attrs?.src, webURL(source) != nil || isImageDataURL(source) else { throw ClipperError.message("An article image has an unsupported URL.") }
            }
            if node.type == "heading", !(1...6).contains(node.attrs?.level ?? 1) { throw ClipperError.message("Invalid article heading.") }
            if ["bulletList", "orderedList", "taskList", "table", "tableRow", "blockquote"].contains(node.type), node.content?.isEmpty != false { throw ClipperError.message("The article contains an empty container.") }
            if ["listItem", "taskItem", "tableCell", "tableHeader"].contains(node.type), node.content?.first?.type != "paragraph" { throw ClipperError.message("The article contains an invalid list or table.") }
            if ["hardBreak", "image", "divider"].contains(node.type), node.content?.isEmpty == false { throw ClipperError.message("Invalid article node.") }
            for child in node.content ?? [] { try visit(child, depth: depth + 1, parent: node.type) }
        }
        for node in request.content { try visit(node, depth: 0, parent: "doc") }
    }
    private static func validateMarks(_ marks: [ClipperMark]?) throws {
        for mark in marks ?? [] {
            guard ["bold", "italic", "underline", "strike", "code", "link"].contains(mark.type) else { throw ClipperError.message("Unsupported article text formatting.") }
            if mark.type == "link", linkURL(mark.attrs?.href ?? "") == nil { throw ClipperError.message("An article link uses an unsupported URL.") }
        }
    }
    static func webURL(_ value: String) -> URL? {
        guard value.count <= 16_384, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func linkURL(_ value: String) -> URL? {
        guard value.count <= 16_384, let url = URL(string: value), ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    static func isImageDataURL(_ value: String) -> Bool {
        ["data:image/png;base64,", "data:image/jpeg;base64,", "data:image/gif;base64,", "data:image/webp;base64,"].contains { value.hasPrefix($0) }
    }
}
