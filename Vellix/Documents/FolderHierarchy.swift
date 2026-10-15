import Foundation

nonisolated struct FolderHierarchy {
    let folders: [FolderRecord]

    func children(of parentID: String?) -> [FolderRecord] {
        folders.filter { $0.parentFolderID == parentID }.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    func path(to id: String) -> [FolderRecord] {
        let records = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var result: [FolderRecord] = []
        var visited: Set<String> = []
        var current: String? = id
        while let id = current, visited.insert(id).inserted, let folder = records[id] {
            result.append(folder)
            current = folder.parentFolderID
        }
        return Array(result.reversed())
    }

    func descendants(including roots: Set<String>) -> Set<String> {
        var result = roots
        var pending = Array(roots)
        while let id = pending.popLast() {
            for child in children(of: id) where result.insert(child.id).inserted { pending.append(child.id) }
        }
        return result
    }

    func itemCount(in id: String, documents: [DocumentRecord]) -> Int {
        children(of: id).count + documents.filter {
            $0.folderID == id && $0.parentDocumentID == nil && !$0.isTrashed && !$0.isArchived
        }.count
    }
}

struct FolderEditorRequest: Identifiable {
    let id = UUID()
    var folder: FolderRecord?
    var parentFolderID: String?
    var spaceID: String?
}

struct LibraryMoveRequest: Identifiable {
    let id = UUID()
    var documentIDs: Set<String>
    var folderIDs: Set<String>
}

enum LibrarySheet: Identifiable {
    case folder(FolderEditorRequest)
    case move(LibraryMoveRequest)

    var id: UUID {
        switch self {
        case .folder(let request): return request.id
        case .move(let request): return request.id
        }
    }
}
