import Foundation
import CloudKit
import CryptoKit

@MainActor
protocol AccountCloudStoring {
    func accountID() async throws -> String
    func fetch(identity: AccountIdentity, ownerID: String) async throws -> AccountProfile?
    func save(_ profile: AccountProfile, identity: AccountIdentity, ownerID: String) async throws
    func delete(identity: AccountIdentity, ownerID: String) async throws
}

@MainActor
final class AccountCloudStore: AccountCloudStoring {
    static let containerIdentifier = "iCloud.im.lystaria.Penned"
    private lazy var container = CKContainer(identifier: Self.containerIdentifier)

    static func recordID(for appleUserID: String) -> CKRecord.ID {
        recordID(for: .apple(appleUserID))
    }

    static func recordID(for identity: AccountIdentity) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data(identity.cloudIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        let prefix: String
        switch identity {
        case .apple: prefix = "account-"
        case .email: prefix = "email-account-"
        }
        return CKRecord.ID(recordName: prefix + digest)
    }

    func accountID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw AccountError.iCloudUnavailable }
        return try await container.userRecordID().recordName
    }

    private func requireOwner(_ ownerID: String) async throws {
        guard try await accountID() == ownerID else { throw AccountError.differentCloudAccount }
        try Task.checkCancellation()
    }

    private func record(_ identity: AccountIdentity) async throws -> CKRecord? {
        do { return try await container.privateCloudDatabase.record(for: Self.recordID(for: identity)) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    func fetch(identity: AccountIdentity, ownerID: String) async throws -> AccountProfile? {
        try await requireOwner(ownerID)
        guard let record = try await record(identity) else { return nil }
        let image = try (record["image"] as? CKAsset)?.fileURL.map { url in
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5 * 1_024 * 1_024 else {
                throw AccountError.invalidImage
            }
            return try Data(contentsOf: url)
        }
        return AccountProfile(name: record["name"] as? String, email: record["email"] as? String, imageData: image)
    }

    func save(_ profile: AccountProfile, identity: AccountIdentity, ownerID: String) async throws {
        try await requireOwner(ownerID)
        let record = try await record(identity) ?? CKRecord(recordType: "PennedAccountProfile", recordID: Self.recordID(for: identity))
        record["name"] = profile.name as CKRecordValue?
        record["email"] = profile.email as CKRecordValue?
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        if let image = profile.imageData {
            try image.write(to: imageURL, options: .atomic)
            record["image"] = CKAsset(fileURL: imageURL)
        } else { record["image"] = nil }
        try await requireOwner(ownerID)
        // The default optimistic save refuses a concurrent server change instead of silently losing it.
        _ = try await container.privateCloudDatabase.save(record)
    }

    func delete(identity: AccountIdentity, ownerID: String) async throws {
        try await requireOwner(ownerID)
        do { _ = try await container.privateCloudDatabase.deleteRecord(withID: Self.recordID(for: identity)) }
        catch let error as CKError where error.code == .unknownItem { return }
    }
}
