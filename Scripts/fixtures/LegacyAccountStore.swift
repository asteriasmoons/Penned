import Foundation
import SwiftData

// Exact persisted fields from the Apple-only account model, before Supabase support.
@Model final class AuthUser {
    var serverId: String?
    var email: String?
    var displayName: String?
    var authProviderRaw: String = "apple"
    var appleUserId: String?
    var googleUserId: String?
    var profileImagePath: String?
    var profileImageData: Data?
    var cloudAccountRecordName: String?
    var profileNeedsUpload: Bool = false
    var profileRevision: Int = 0
    var createdAt: Date = Date()
    init() {
        appleUserId = "legacy-native-id"
        email = "contact@example.com"
        displayName = "Existing Apple Account"
        profileImageData = Data([1, 2, 3])
        cloudAccountRecordName = "legacy-cloud-owner"
        profileNeedsUpload = true
        profileRevision = 4
    }
}

@main struct LegacyAccountFixture {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema([AuthUser.self])
        let config = ModelConfiguration("PennedAccounts", schema: schema,
            url: directory.appendingPathComponent("Accounts.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        container.mainContext.insert(AuthUser())
        try container.mainContext.save()
    }
}
