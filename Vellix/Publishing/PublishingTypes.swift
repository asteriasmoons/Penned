import Foundation
import CryptoKit

nonisolated enum PublishingDate {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

extension PublishingDocument {
    nonisolated func fingerprint() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum PublishingFailure: LocalizedError, Equatable {
    case authenticationRequired, appleAuthorizationRequired, invalidContent(String), unavailable(String), conflict
    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "Restore your account session through Account Settings."
        case .appleAuthorizationRequired: "Reconnect this Apple account through Account Settings."
        case .invalidContent(let message): "This document cannot be published: \(message)"
        case .unavailable(let message): "Publishing is unavailable: \(message)"
        case .conflict: "The publication changed on another device. Refresh its status before updating."
        }
    }
}

nonisolated enum PublishingJSON: Codable, Equatable, Sendable {
    case object([String: PublishingJSON]), array([PublishingJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([PublishingJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: PublishingJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    static func decode(_ value: Any) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }
}

nonisolated struct PublishingMedia: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var mimeType: String
    var size: Int
    var sha256: String
}

nonisolated struct PublishingDocument: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var title: String
    var subtitle: String?
    var icon: String?
    var cover: PublishingJSON?
    var appearance: PublishingJSON
    var content: PublishingJSON
    var media: [PublishingMedia]
    var authorAvatar: PublishingJSON? = nil
    var linkedPages: [PublishingLinkedPage]? = nil
}

nonisolated struct PublishingLinkedPage: Codable, Equatable, Sendable {
    var key: String
    var parentKey: String
    var document: PublishingDocument
}

nonisolated struct PublishingSettings: Codable, Equatable, Sendable {
    var showTitle: Bool = true
    var showAuthor: Bool = false
    var showTableOfContents: Bool = true
    var allowIndexing: Bool = false
    var allowFollowLinkedContent: Bool = false
    var authorName: String = ""
    var expiresAt: String?
    var showBranding = true
    var hideHashtags = false

    enum CodingKeys: String, CodingKey { case showTitle, showAuthor, showTableOfContents, allowIndexing, allowFollowLinkedContent, authorName, expiresAt, showBranding, hideHashtags }
    init() {}
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showTitle = try container.decodeIfPresent(Bool.self, forKey: .showTitle) ?? true
        showAuthor = try container.decodeIfPresent(Bool.self, forKey: .showAuthor) ?? false
        showTableOfContents = try container.decodeIfPresent(Bool.self, forKey: .showTableOfContents) ?? true
        allowIndexing = try container.decodeIfPresent(Bool.self, forKey: .allowIndexing) ?? false
        allowFollowLinkedContent = try container.decodeIfPresent(Bool.self, forKey: .allowFollowLinkedContent) ?? false
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName) ?? ""
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        showBranding = try container.decodeIfPresent(Bool.self, forKey: .showBranding) ?? true
        hideHashtags = try container.decodeIfPresent(Bool.self, forKey: .hideHashtags) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showTitle, forKey: .showTitle)
        try container.encode(showAuthor, forKey: .showAuthor)
        try container.encode(showTableOfContents, forKey: .showTableOfContents)
        try container.encode(allowIndexing, forKey: .allowIndexing)
        try container.encode(allowFollowLinkedContent, forKey: .allowFollowLinkedContent)
        try container.encode(authorName, forKey: .authorName)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(showBranding, forKey: .showBranding)
        try container.encode(hideHashtags, forKey: .hideHashtags)
    }
}

nonisolated struct PublicationStatus: Codable, Equatable, Sendable {
    var id: String
    var sourceLibraryID: String
    var sourceDocumentID: String
    var version: Int
    var active: Bool
    var token: String
    var publicURL: URL
    var settings: PublishingSettings
    var updatedAt: String
    var sourceFingerprint: String?
    var publishedAt: String?
    var customPath: String?
    var passwordSet: Bool?
    var emails: [String]?
    var emailDomains: [String]?
    var uploadedMedia: [PublishingMedia]?

    mutating func usePennedDomain() {
        guard publicURL.host == "penned-site-pi.vercel.app",
              var url = URLComponents(url: publicURL, resolvingAgainstBaseURL: false) else { return }
        url.host = "penned.im"
        if let canonical = url.url { publicURL = canonical }
    }
}
