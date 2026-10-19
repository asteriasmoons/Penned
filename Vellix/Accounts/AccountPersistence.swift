import Foundation
import SwiftData

enum AccountPersistence {
    static func makeContainer(directory: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([AuthUser.self])
        if inMemory {
            return try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
        }
        let directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Vellix", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Session/cache records are local. Only the explicit profile service writes to CloudKit.
        let configuration = ModelConfiguration("PennedAccounts", schema: schema,
            url: directory.appendingPathComponent("Accounts.store"), cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

enum AccountError: LocalizedError, Equatable {
    case storageUnavailable, keychainUnavailable, invalidName, invalidEmail, invalidImage
    case iCloudUnavailable, differentCloudAccount, accountRemoved

    var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "Account storage could not be opened. Your document library is unaffected."
        case .keychainUnavailable: return "The account session could not be saved securely. Please try again."
        case .invalidName: return "Enter a name between 1 and 100 characters."
        case .invalidEmail: return "Enter a valid email address."
        case .invalidImage: return "The account image could not be loaded."
        case .iCloudUnavailable: return "Sign in to iCloud in device settings to sync account details. Your changes are saved on this device."
        case .differentCloudAccount: return "This account's details belong to a different iCloud account. Switch back to that iCloud account to sync them."
        case .accountRemoved: return "These account details were removed from iCloud. Sign in again to create a new Penned account."
        }
    }
}

struct AccountProfile: Equatable, Sendable {
    var name: String?
    var email: String?
    var imageData: Data?
}

enum AccountValidation {
    static func name(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 100 else { throw AccountError.invalidName }
        return value
    }

    static func email(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 254, value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else {
            throw AccountError.invalidEmail
        }
        return value
    }
}

extension AuthUser {
    var accountProfile: AccountProfile {
        AccountProfile(name: displayName, email: email, imageData: profileImageData)
    }
}
