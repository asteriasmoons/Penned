import Foundation

// DocumentRecord is a mutable persistence value; snapshots are transferred by value.
extension TemplateGalleryNativeSnapshot: @unchecked Sendable {}

/// A complete, transportable snapshot of a gallery template.
/// Media bytes are keyed by the asset identifiers used in the document.
struct TemplateGalleryPackage: Codable, Sendable {
    var galleryTemplateID: String
    var categoryID: String
    var title: String
    var revision: Int
    var document: PublishingDocument
    var files: [String: Data]
    /// Exact Penned editor records. Older packages may contain only the web projection.
    var nativeSnapshot: TemplateGalleryNativeSnapshot? = nil

    /// Ensures the package carries every media asset referenced by its document.
    func validateMedia() throws {
        let required = Set(document.media.map(\.id))
        let available = Set(files.keys)
        guard required.isSubset(of: available) else {
            throw PublishingFailure.invalidContent("Some template media files are missing.")
        }
        try nativeSnapshot?.validate()
    }
}
