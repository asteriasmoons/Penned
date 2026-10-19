//
// AuthUser.swift
// Penned
//

import Foundation
import SwiftData

enum AuthProvider: String, Codable {
    case apple = "apple"
    case email = "email"
    case google = "google"
}

@Model
final class AuthUser {
    var serverId: String?
    var email: String?
    var displayName: String?
    var authProviderRaw: String = AuthProvider.apple.rawValue
    var appleUserId: String?        // Apple's stable user identifier
    var supabaseUserID: String?
    var supabaseProjectURL: String?
    var authenticationEmail: String?
    var remoteAuthDeleted: Bool = false
    var googleUserId: String?       // Google's stable user identifier
    var profileImagePath: String?     // Local file URL or relative path to a saved profile image
    var profileImageData: Data?
    var cloudAccountRecordName: String?
    var profileNeedsUpload: Bool = false
    var profileRevision: Int = 0

    var createdAt: Date = Date()
    
    var authProvider: AuthProvider {
        get { AuthProvider(rawValue: authProviderRaw) ?? .apple }
        set { authProviderRaw = newValue.rawValue }
    }
    
    var isEmail: Bool { authProvider == .email }
    var isGoogle: Bool { authProvider == .google }
    var isApple: Bool { authProvider == .apple }

    var identity: AccountIdentity? {
        switch authProvider {
        case .apple:
            return appleUserId.flatMap { $0.isEmpty ? nil : .apple($0) }
        case .email:
            guard let id = supabaseUserID.flatMap(UUID.init(uuidString:)), let project = supabaseProjectURL else { return nil }
            return .email(project: project, userID: id)
        case .google: return nil
        }
    }

    var providerName: String { identity?.providerName ?? authProvider.rawValue.capitalized }
    
    init(
        email: String? = nil,
        displayName: String? = nil,
        authProvider: AuthProvider = .apple,
        appleUserId: String? = nil,
        googleUserId: String? = nil,
        serverId: String? = nil
    ) {
        self.email = email
        self.displayName = displayName
        self.authProviderRaw = authProvider.rawValue
        self.appleUserId = appleUserId
        self.googleUserId = googleUserId
        self.serverId = serverId
        self.createdAt = Date()
    }
}
