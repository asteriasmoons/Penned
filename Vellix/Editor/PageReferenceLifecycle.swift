import Foundation

/// Keeps removal of a page block from falling back to a second native rendering of the same page.
@MainActor
final class PageReferenceLifecycle {
    private var removedBatches: [String: String] = [:]

    func reset() { removedBatches.removeAll() }

    static func prepareForEditing(_ record: DocumentRecord, repository: DocumentRepository) throws -> DocumentRecord {
        let current = try materializeLegacyChildren(of: record, repository: repository)
        guard current.parentDocumentID != nil, current.dailyNoteDate == nil, !current.isTrashed, !current.isArchived,
              TipTapContentAnalyzer.hasLegacyGroupedTitle(current.title, in: current.tipTapJSON) else { return current }
        return try repository.updateTitle(id: current.id, title: "", allowsBlankTitle: true)
    }

    private static func materializeLegacyChildren(of record: DocumentRecord, repository: DocumentRepository) throws -> DocumentRecord {
        let current = try repository.requireDocument(id: record.id)
        guard !current.isTrashed, !current.isArchived else { return current }
        let references = TipTapContentAnalyzer.pageReferenceIDs(in: current.tipTapJSON)
        let missing = try repository.children(of: current.id, includingCollectionEntries: false)
            .filter { !references.contains($0.id) && !$0.id.hasPrefix("vellix-task-page:") && !$0.id.hasPrefix("vellix-task-history:") }.map(\.id)
        guard !missing.isEmpty else { return current }
        // These pages already appeared after the body in native fallback UI. Give them real editor positions.
        var object = TipTapContentAnalyzer.documentObject(from: current.tipTapJSON)
        var content = object["content"] as? [[String: Any]] ?? []
        var insertion = content.count
        // Keep trailing blank editing lines after the cards, not between the existing and recovered cards.
        while insertion > 0 {
            let node = content[insertion - 1]
            let attrs = node["attrs"] as? [String: Any] ?? [:]
            guard node["type"] as? String == "paragraph",
                  (node["content"] as? [Any] ?? []).isEmpty,
                  attrs["placeholderEnabled"] as? Bool != true else { break }
            insertion -= 1
        }
        // An old grouping could leave the body with only its required empty paragraph.
        // The recovered page reference can now serve as the first block instead.
        if content.count == 1, insertion == 0 {
            let attrs = content[0]["attrs"] as? [String: Any] ?? [:]
            if (attrs["indent"] as? Int ?? 0) == 0, !(attrs["textAlign"] is String) {
                content.removeAll()
            }
        }
        content.insert(contentsOf: missing.map {
            ["type": "pageReference", "attrs": ["id": UUID().uuidString, "documentID": $0]] as [String: Any]
        }, at: insertion)
        object["content"] = content
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        return try repository.saveEditorJSON(id: current.id, canonicalJSON: json)
    }

    static func createGroupedChild(json: String, parent: DocumentRecord, repository: DocumentRepository,
                                   place: (String) async throws -> Bool) async throws -> DocumentRecord {
        let child = try repository.create(DocumentDraft(title: "", spaceID: parent.spaceID, folderID: parent.folderID,
            parentDocumentID: parent.id, tipTapJSON: json, allowsBlankTitle: true))
        var moved: [DocumentRecord] = []
        func restoreMovedPages() throws {
            for page in moved {
                guard try repository.document(id: page.id)?.parentDocumentID == child.id else { continue }
                _ = try repository.move(id: page.id, spaceID: page.spaceID, folderID: page.folderID, parentDocumentID: parent.id)
            }
        }
        do {
            for pageID in TipTapContentAnalyzer.pageReferenceIDs(in: json) {
                guard let page = try repository.document(id: pageID), page.parentDocumentID == parent.id else { continue }
                _ = try repository.move(id: page.id, spaceID: page.spaceID, folderID: page.folderID, parentDocumentID: child.id)
                moved.append(page)
            }
        } catch {
            try restoreMovedPages()
            throw error
        }
        // A definite rejection means the source still owns these blocks. Do not
        // roll back an uncertain bridge error after a command may have committed.
        guard try await place(child.id) else {
            try restoreMovedPages()
            throw VellixError.editorBridge("The selection changed before grouping. The new page was kept as a copy.")
        }
        return child
    }

    func reconcile(previous: Set<String>, next: Set<String>, parentID: String, repository: DocumentRepository) throws {
        for id in previous.subtracting(next) where id != parentID {
            guard let page = try repository.document(id: id), page.parentDocumentID == parentID,
                  !page.isTrashed, !page.isArchived else { continue }
            let removed = try repository.trash(id: id)
            if let batch = removed.trashBatchID { removedBatches[id] = batch }
        }
        for id in next.intersection(Set(removedBatches.keys)) {
            guard let page = try repository.document(id: id), page.parentDocumentID == parentID else { continue }
            // Undo may restore only the exact Trash operation performed by this editor, never a later external deletion.
            if page.isTrashed, page.trashBatchID == removedBatches[id] {
                _ = try repository.restore(id: id)
            }
            removedBatches.removeValue(forKey: id)
        }
    }
}
