import Foundation

enum AccountIdentity: Codable, Hashable, Sendable {
    case apple(String)
    case email(project: String, userID: UUID)

    var providerName: String {
        switch self {
        case .apple: return "Apple"
        case .email: return "Email"
        }
    }

    var cloudIdentity: String {
        switch self {
        case .apple(let id): return id
        case .email(let project, let id): return "supabase:\(project):\(id.uuidString.lowercased())"
        }
    }

    var libraryOwnerKey: String {
        switch self {
        case .apple(let id): return "apple:\(id)"
        case .email: return cloudIdentity
        }
    }
}
