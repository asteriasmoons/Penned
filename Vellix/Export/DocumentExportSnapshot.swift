import Foundation
import SwiftUI
import CryptoKit

struct DocumentExportSnapshot {
    let libraryID: String
    let spaceID: String?
    let pages: [DocumentRecord]
    let contents: [String: DocumentPreviewContent]
    let files: [EditorAttachment]
    let assets: [String: URL]
    let assetNames: [String: String]
    var warnings: [String]
    var root: DocumentRecord { pages[0] }

    static func capture(documentID: String, environment: AppEnvironment, includeNested: Bool) async throws -> Self {
        let libraryID = environment.database.libraryID, spaceID = environment.selectedSpaceID
        var pending = [documentID], seen = Set<String>(), pages: [DocumentRecord] = []
        var contents: [String: DocumentPreviewContent] = [:], files: [String: EditorAttachment] = [:]
        while !pending.isEmpty {
            try Task.checkCancellation()
            let id = pending.removeLast()
            guard seen.insert(id).inserted else { continue }
            if let model = environment.editorCache.model(for: id) {
                await model.waitForPersistentOperations()
                if model.session.isReady && !model.session.isLoadingDocument { try await model.captureAndSave() }
                else { try model.saveCurrentContent() }
            }
            guard environment.database.libraryID == libraryID, environment.selectedSpaceID == spaceID,
                  !environment.isSwitchingSpace else { throw LibraryError.staleWorkspace }
            let page = try environment.documents.requireDocument(id: id)
            guard !page.isTrashed, page.spaceID == spaceID else { throw LibraryError.staleWorkspace }
            pages.append(page)
            contents[id] = try environment.collections.repository.previewContent(for: page, documents: environment.documents)
            for file in try environment.documents.editorAttachments(documentID: id, json: page.tipTapJSON, store: environment.attachmentStore) {
                files[file.id] = file
            }
            if includeNested {
                let children = try environment.documents.children(of: id)
                pending.append(contentsOf: children.reversed().map(\.id))
            }
        }
        var paths = Set<String>(), assets: [String: URL] = [:], names: [String: String] = [:], warnings: [String] = []
        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                for (key, value) in object {
                    if ["relativePath", "previewPath", "imagePath", "thumbnailRelativePath"].contains(key), let path = value as? String, !path.isEmpty {
                        paths.insert(path)
                    } else { collect(value) }
                }
            } else if let array = value as? [Any] { array.forEach(collect) }
        }
        for page in pages {
            if let cover = page.cover { paths.insert(cover) }
            for path in [page.appearance.editorBackground.imagePath, page.appearance.innerPageBackground.imagePath, page.cardStyle?.imagePath].compactMap({ $0 }) { paths.insert(path) }
            collect(TipTapContentAnalyzer.documentObject(from: page.tipTapJSON))
            for child in contents[page.id]?.children ?? [] {
                if let cover = child.cover { paths.insert(cover) }
                if let path = child.cardStyle?.imagePath { paths.insert(path) }
            }
            let embedded = TipTapContentAnalyzer.collectionIDs(in: page.tipTapJSON)
            for collection in contents[page.id]?.collections ?? [] where embedded.contains(collection.record.id) {
                for entry in collection.entries { if let cover = entry.cover { paths.insert(cover) } }
            }
        }
        for file in files.values {
            let object = file.object
            collect(object)
            if let path = object["relativePath"] as? String {
                paths.insert(path); names[path] = object["name"] as? String ?? URL(fileURLWithPath: path).lastPathComponent
            }
        }
        for path in paths.sorted() {
            do {
                let url = try environment.attachmentStore.validatedFileURL(relativePath: path)
                guard FileManager.default.fileExists(atPath: url.path) else { throw DocumentExportError.failed("Missing asset") }
                assets[path] = url
            } catch { warnings.append("Unavailable asset: " + (names[path] ?? URL(fileURLWithPath: path).lastPathComponent)) }
        }
        return Self(libraryID: libraryID, spaceID: spaceID, pages: pages, contents: contents,
            files: Array(files.values), assets: assets, assetNames: names, warnings: warnings)
    }

    func collections(for page: DocumentRecord) -> [[String: Any]] {
        let embedded = TipTapContentAnalyzer.collectionIDs(in: page.tipTapJSON)
        return (contents[page.id]?.collections ?? []).filter { embedded.contains($0.record.id) }.compactMap { snapshot in
            guard let view = snapshot.activeView else { return nil }
            if view.kind != .kanban { return CollectionStore.payloads(from: [snapshot]).first }
            var copy = snapshot
            if let index = copy.views.firstIndex(where: { $0.id == view.id }) { copy.views[index].kind = .gallery }
            guard var payload = CollectionStore.payloads(from: [copy]).first else { return nil }
            payload["kind"] = "kanban"
            payload["columns"] = snapshot.kanbanGroups(in: view).map { group in
                ["id": group.column.id, "name": group.column.name, "color": group.column.color,
                 "collapsed": group.column.collapsed, "entries": group.entries.map(\.id)] as [String: Any]
            }
            return payload
        }
    }

    func assetFilename(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return digest + "-" + DocumentExportNames.filename(url.deletingPathExtension().lastPathComponent) +
            (url.pathExtension.isEmpty ? "" : "." + DocumentExportNames.filename(url.pathExtension))
    }
}
