import Foundation
import CryptoKit

/// Prepares complete gallery packages using Penned's existing publication
/// serializer. Server-side authorization is enforced by the gallery API.
final class TemplateGalleryPublisher {
    private let builder: PublishingDocumentBuilder
    private let nativeExporter: TemplateGalleryNativeExporter
    private let documents: DocumentRepository

    init(database: AppDatabase, attachmentStore: AttachmentStore) {
        builder = PublishingDocumentBuilder(database: database, attachmentStore: attachmentStore)
        nativeExporter = TemplateGalleryNativeExporter(database: database, attachmentStore: attachmentStore)
        documents = DocumentRepository(database: database)
    }

    static func category(for template: TemplateRecord, in categories: [GalleryCategory]) throws -> GalleryCategory {
        let name = template.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = name.isEmpty || name.caseInsensitiveCompare("Mine") == .orderedSame
            ? TemplateRepository.unsortedCategory : name
        guard resolved.caseInsensitiveCompare(TemplateRepository.myTemplatesCategory) != .orderedSame else {
            throw PublishingFailure.invalidContent("Move this template to a public category before publishing it.")
        }
        let matches = categories.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(resolved) == .orderedSame
        }
        guard matches.count == 1, let category = matches.first else {
            throw PublishingFailure.invalidContent("The template's saved category is missing or ambiguous. Check Manage Categories before publishing.")
        }
        return category
    }

    static func publicationID(templateID: String, libraryID: String) -> String {
        let digest = SHA256.hash(data: Data((libraryID + "|gallery-template|" + templateID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
            .map { String(digest.dropFirst($0.lowerBound).prefix($0.count)) }.joined(separator: "-")
    }

    /// Builds a read-only export snapshot. Publishing the result requires a
    /// separately authenticated service that verifies administrator privileges.
    func prepare(documentID: String, categoryID: String, title: String,
                 owner: AccountIdentity, galleryTemplateID: String = UUID().uuidString.lowercased(),
                 revision: Int = 1) throws -> TemplateGalleryPackage {
        guard !categoryID.isEmpty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PublishingFailure.invalidContent("A template name and category are required.")
        }
        let rootDocument = try documents.requireDocument(id: documentID)
        let prepared: PreparedPublication
        if let templateID = rootDocument.templateID {
            prepared = try builder.prepareTemplate(documentID: documentID, templateID: templateID, owner: owner)
        } else {
            prepared = try builder.prepare(documentID: documentID, owner: owner, includeLinkedPages: true)
        }
        var document = prepared.document
        document.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeSnapshot = try nativeExporter.capture(documentID: documentID)
        let package = TemplateGalleryPackage(
            galleryTemplateID: galleryTemplateID,
            categoryID: categoryID,
            title: document.title,
            revision: revision,
            document: document,
            files: prepared.files,
            nativeSnapshot: nativeSnapshot
        )
        try package.validateMedia()
        return package
    }
}
