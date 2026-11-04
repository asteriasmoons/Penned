import Foundation

/// Native document graph retained separately from the web-publishing projection.
/// Source IDs are only references inside the package; import must generate new IDs.
struct TemplateGalleryNativeSnapshot: Codable {
    var schemaVersion: Int = 1
    var rootDocumentID: String
    var documents: [DocumentRecord]
    /// Source attachment metadata, retained so import can create new attachment IDs.
    var attachments: [AttachmentRecord] = []
    /// Original stored paths mapped to file bytes, including thumbnails and covers.
    var attachmentFiles: [String: Data] = [:]
    /// Complete collection definitions, views, entries, and field values.
    var collections: [CollectionSnapshot] = []

    func validate() throws {
        guard schemaVersion == 1,
              !documents.isEmpty,
              Set(documents.map(\.id)).count == documents.count,
              let root = documents.first(where: { $0.id == rootDocumentID }),
              root.parentDocumentID == nil else {
            throw PublishingFailure.invalidContent("The native template document tree is invalid.")
        }
        let ids = Set(documents.map(\.id))
        guard Set(attachments.map(\.id)).count == attachments.count,
              attachments.allSatisfy({ ids.contains($0.documentID) }),
              attachments.allSatisfy({ attachmentFiles[$0.relativePath] != nil &&
                  ($0.thumbnailRelativePath == nil || attachmentFiles[$0.thumbnailRelativePath!] != nil) }),
              collections.allSatisfy({ ids.contains($0.record.documentID) &&
                  $0.entries.allSatisfy({ ids.contains($0.id) }) }) else {
            throw PublishingFailure.invalidContent("A template attachment or collection is incomplete.")
        }
        for document in documents {
            let referencedPaths = EditorAttachment.paths(in: document.tipTapJSON)
            guard referencedPaths.allSatisfy({ attachmentFiles[$0] != nil }),
                  document.cover.map({ attachmentFiles[$0] != nil }) ?? true,
                  document.appearance.editorBackground.imagePath.map({ attachmentFiles[$0] != nil }) ?? true,
                  document.appearance.innerPageBackground.imagePath.map({ attachmentFiles[$0] != nil }) ?? true else {
                throw PublishingFailure.invalidContent("A referenced template image or attachment is missing.")
            }
            if let parent = document.parentDocumentID, !ids.contains(parent) {
                throw PublishingFailure.invalidContent("A nested template page has no parent in its package.")
            }
            guard let data = document.tipTapJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "doc" else {
                throw PublishingFailure.invalidContent("A template page contains invalid editor content.")
            }
        }
        for document in documents {
            var visited = Set<String>()
            var cursor: DocumentRecord? = document
            while let current = cursor {
                guard visited.insert(current.id).inserted else {
                    throw PublishingFailure.invalidContent("The template contains a circular page hierarchy.")
                }
                cursor = current.parentDocumentID.flatMap { parent in
                    documents.first(where: { $0.id == parent })
                }
            }
        }
    }
}
