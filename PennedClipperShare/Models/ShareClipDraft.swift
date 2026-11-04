import Foundation

/// Editable clip details gathered before a Share Extension submission.
struct ShareClipDraft {
    var id: String = UUID().uuidString
    var sessionID: String = ""
    var spaceID: String = ""
    var folderID: String?
    var tagIDs: Set<String> = []

    var title: String = ""
    var author: String = ""
    var siteName: String = ""
    var sourceURL: String = ""
    var notes: String = ""
    var content: [ClipperNode] = []
    var thumbnailURL: String?

    var canSave: Bool {
        !sessionID.isEmpty &&
        !spaceID.isEmpty &&
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        ClipperShared.webURL(sourceURL) != nil &&
        !content.isEmpty
    }

    func submission() -> ClipperSubmission {
        ClipperSubmission(
            id: id,
            sessionID: sessionID,
            spaceID: spaceID,
            folderID: folderID,
            tagIDs: tagIDs.sorted(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.trimmingCharacters(in: .whitespacesAndNewlines),
            siteName: siteName.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceURL: sourceURL,
            notes: notes,
            content: content,
            thumbnailURL: thumbnailURL
        )
    }
}
