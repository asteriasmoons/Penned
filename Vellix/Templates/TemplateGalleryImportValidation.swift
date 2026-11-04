import Foundation
import CryptoKit

/// Verifies the integrity of the exported package before import.
extension TemplateGalleryPackage {
    func validateForImport(expectedID: String? = nil, expectedRevision: Int? = nil) throws {
        guard !galleryTemplateID.isEmpty, !categoryID.isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              revision > 0 else {
            throw PublishingFailure.invalidContent("The template package has invalid metadata.")
        }
        if let expectedID, galleryTemplateID != expectedID {
            throw PublishingFailure.invalidContent("The template identifier does not match the gallery entry.")
        }
        if let expectedRevision, revision != expectedRevision {
            throw PublishingFailure.conflict
        }
        guard document.schemaVersion == 1 else {
            throw PublishingFailure.invalidContent("This template uses an unsupported document format.")
        }
        let assetIDs = document.media.map(\.id)
        guard Set(assetIDs).count == assetIDs.count,
              Set(files.keys) == Set(assetIDs) else {
            throw PublishingFailure.invalidContent("The template media manifest does not match its files.")
        }
        for media in document.media {
            guard let bytes = files[media.id], bytes.count == media.size,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == media.sha256 else {
                throw PublishingFailure.invalidContent("A template media file failed its integrity check.")
            }
        }
        for page in document.linkedPages ?? [] {
            guard !page.key.isEmpty, page.key != "root" else {
                throw PublishingFailure.invalidContent("A linked template page has an invalid key.")
            }
        }
    }
}
