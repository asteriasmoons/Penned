#if os(iOS)
import Foundation
import Combine
import UIKit
import GRDB
import Darwin
import notify

@MainActor
final class WebClipperCoordinator: ObservableObject {
    private weak var accounts: AppState?
    private weak var environment: AppEnvironment?
    private var changes: AnyCancellable?
    private var notificationToken: Int32 = 0
    private var observing = false
    private var importing = false
    private let catalogueImages = WebClipperCatalogueImages()
    private var catalogueTask: Task<Void, Never>?
    private var catalogueGeneration: UInt64 = 0

    func connect(accounts: AppState, environment: AppEnvironment?) {
        changes = nil
        catalogueTask?.cancel()
        catalogueGeneration &+= 1
        self.accounts = accounts; self.environment = environment
        guard let environment, !environment.database.isInMemory, !accounts.isWorking,
              case .signedIn = accounts.status, accounts.currentUser?.remoteAuthDeleted == false else {
            let images = catalogueImages
            Task { await images.resetAccount() }
            try? ClipperShared.disconnect(); return
        }
        if !observing {
            observing = notify.notify_register_dispatch(ClipperShared.notification, &notificationToken, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.drain() }
            } == notify.NOTIFY_STATUS_OK
        }
        changes = NotificationCenter.default.publisher(for: .pennedCollectionsChanged, object: environment.database)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.publishCatalogue(); self?.drain() } }
        publishCatalogue(retryErrors: true)
    }

    private var ownerID: String? {
        guard let accounts, !accounts.isWorking, case .signedIn = accounts.status,
              accounts.currentUser?.remoteAuthDeleted == false, let identity = accounts.currentAccountIdentity else { return nil }
        return LibraryRecord.accountID(ownerKey: identity.libraryOwnerKey)
    }

    func refresh() { publishCatalogue(retryErrors: true); drain(retryErrors: true) }

    private func publishCatalogue(retryErrors: Bool = false) {
        guard let ownerID, let accounts, let environment, environment.database.isAccessible else { return }
        catalogueTask?.cancel()
        catalogueGeneration &+= 1
        let generation = catalogueGeneration
        let database = environment.database
        let accountName = accounts.currentUser?.displayName ?? accounts.currentUser?.email ?? "Penned Account"
        let avatar = accounts.currentUser?.profileImageData
        let selectedSpaceID = environment.selectedSpaceID
        let scale = UITraitCollection.current.displayScale
        let images = catalogueImages
        catalogueTask = Task { [weak self, weak environment] in
            do {
                let (spaces, folders, tags) = try await Task.detached(priority: .utility) {
                    try (SpaceRepository(database: database).all(), FolderRepository(database: database).all(),
                         DocumentTagRepository(database: database).catalogue())
                }.value
                try Task.checkCancellation()
                let toolbarIcons = ["chevdown", "chevleft", "xmarkwavy", "linesfolderfill", "searchwavy", "hashtagwavy", "infowavy", "writepen", "settingswavy", "checkwavy", "spaces", "linedpages"]
                let names = Set(toolbarIcons + spaces.map { $0.icon ?? "spaces" } + folders.map { $0.icon ?? "linesfolderfill" })
                var thumbnails: [String: ClipperThumbnailRequest] = [:]
                if let avatar { thumbnails["avatar"] = ClipperThumbnailRequest(data: avatar, size: 48) }
                for space in spaces {
                    if let data = space.iconImageData { thumbnails[space.id] = ClipperThumbnailRequest(data: data, size: 32) }
                }
                guard let rendered = await images.render(ownerID: ownerID, names: names, requests: thumbnails, displayScale: scale),
                      !Task.isCancelled, let self, let environment, self.catalogueGeneration == generation,
                      self.ownerID == ownerID, self.environment === environment, database.isAccessible else { return }
                // Account validation and publication stay on main together so a
                // completed old render cannot reconnect a signed-out account.
                try ClipperShared.locked {
                    let previous = try ClipperShared.connection()
                    let session = previous?.ownerID == ownerID && previous?.libraryID == database.libraryID ? previous!.sessionID : UUID().uuidString
                    let connection = ClipperConnection(sessionID: session, ownerID: ownerID, libraryID: database.libraryID,
                        accountName: accountName, avatar: rendered.thumbnails["avatar"], selectedSpaceID: selectedSpaceID,
                        spaces: spaces.map { ClipperDestination(id: $0.id, title: $0.title, image: rendered.thumbnails[$0.id] ?? rendered.icons[$0.icon ?? "spaces"]) },
                        folders: folders.map { ClipperDestination(id: $0.id, title: $0.title, spaceID: $0.spaceID, parentID: $0.parentFolderID, image: rendered.icons[$0.icon ?? "linesfolderfill"]) },
                        tags: tags.map { ClipperDestination(id: $0.id, title: $0.name, spaceID: $0.spaceID) },
                        icons: rendered.icons.filter { toolbarIcons.contains($0.key) })
                    try ClipperShared.write(connection, to: ClipperShared.directory().appendingPathComponent("connection.json"))
                }
                self.drain(retryErrors: retryErrors)
            } catch {
                guard !Task.isCancelled, let self, let environment, self.catalogueGeneration == generation,
                      self.ownerID == ownerID, self.environment === environment, database.isAccessible else { return }
                environment.errorMessage = error.localizedDescription
                // A refresh failure must not strand imports if an older valid
                // connection is still present; drain rechecks that connection.
                self.drain(retryErrors: retryErrors)
            }
        }
    }

    private func drain(retryErrors: Bool = false) {
        guard !importing, let ownerID, let environment, environment.database.isAccessible else { return }
        importing = true
        defer { importing = false }
        do {
            let root = try ClipperShared.directory()
            let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                .filter { $0.pathExtension == "clip" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var changed = false
            for directory in directories {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                do {
                    try ClipperShared.locked {
                        guard self.ownerID == ownerID, let connection = try ClipperShared.connection(),
                              connection.ownerID == ownerID, connection.libraryID == environment.database.libraryID else { return }
                        let envelope = try ClipperShared.read(ClipperEnvelope.self, at: directory.appendingPathComponent("clip.json"))
                        guard envelope.ownerID == ownerID, envelope.libraryID == environment.database.libraryID else { return }
                        let resultURL = directory.appendingPathComponent("result.json")
                        if FileManager.default.fileExists(atPath: resultURL.path) {
                            let result = try ClipperShared.read(ClipperResult.self, at: resultURL)
                            if result.state == "imported" || (result.state == "error" && !retryErrors) { return }
                        }
                        // Old authorized clips remain owned by the same account across sign-outs.
                        var request = envelope.submission; request.sessionID = connection.sessionID
                        try ClipperShared.validate(request, connection: connection)
                        let id = try Self.importClip(envelope, directory: directory, environment: environment)
                        try ClipperShared.write(ClipperResult(state: "imported", documentID: id), to: resultURL)
                        // Keep the small receipt, not a second permanent copy of imported media.
                        for asset in envelope.assets { try? FileManager.default.removeItem(at: directory.appendingPathComponent(asset.filename)) }
                        changed = true
                    }
                } catch {
                    try? ClipperShared.locked {
                        try ClipperShared.write(ClipperResult(state: "error", message: error.localizedDescription), to: directory.appendingPathComponent("result.json"))
                    }
                    environment.errorMessage = "A Safari clip is waiting to import. " + error.localizedDescription
                }
            }
            if changed { environment.refresh() }
        } catch { environment.errorMessage = error.localizedDescription }
    }

    private static func importClip(_ envelope: ClipperEnvelope, directory: URL, environment: AppEnvironment) throws -> String? {
        let database = environment.database, store = environment.attachmentStore
        let repository = DocumentRepository(database: database)
        var copied: [AttachmentRecord] = []
        do {
            return try database.write { db -> String? in
                if let receipt = try Row.fetchOne(db, sql: "SELECT documentID,libraryID FROM webClipImports WHERE id=?", arguments: [envelope.submission.id]) {
                    guard receipt["libraryID"] as String == database.libraryID else { throw LibraryError.wrongOwner }
                    let documentID: String? = receipt["documentID"]
                    return documentID
                }
                let clip = envelope.submission
                let document = try repository.create(DocumentDraft(title: clip.title, spaceID: clip.spaceID, folderID: clip.folderID), in: db)
                var files: [String: EditorAttachment] = [:]
                for asset in envelope.assets {
                    guard AttachmentStore.validRelativePath(asset.filename) else { throw VellixError.attachmentImport("Invalid clip image path.") }
                    let record = try store.importFile(at: directory.appendingPathComponent(asset.filename), documentID: document.id)
                    copied.append(record)
                    let media = AttachmentMedia.inspect(url: store.fileURL(relativePath: record.relativePath), mimeType: asset.mimeType)
                    guard media.kind == .image else { throw VellixError.attachmentImport("A clipped image is no longer available.") }
                    try record.insert(db)
                    files[asset.source] = EditorAttachment(record: record, media: media)
                }
                func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }
                func paragraph(_ children: [[String: Any]], type: String = "paragraph") -> [String: Any] {
                    ["type": type, "attrs": ["id": UUID().uuidString], "content": children]
                }
                func convert(_ node: ClipperNode) throws -> [String: Any] {
                    if node.type == "image" {
                        guard let source = node.attrs?.src, let file = files[source] else { throw VellixError.attachmentImport("A clipped image is missing. Retry the clip in Safari.") }
                        return ["type": "attachment", "attrs": ["id": UUID().uuidString, "file": file.object, "displayMode": "inline", "widthPercent": 100, "textAlign": "left"]]
                    }
                    var result: [String: Any] = ["type": node.type]
                    if let value = node.text { result["text"] = value }
                    if node.type != "text", node.type != "hardBreak" {
                        var attrs: [String: Any] = ["id": UUID().uuidString]
                        if let value = node.attrs?.level { attrs["level"] = value }
                        if let value = node.attrs?.start { attrs["start"] = max(1, value) }
                        if let value = node.attrs?.language { attrs["language"] = value }
                        if let value = node.attrs?.colspan { attrs["colspan"] = min(100, max(1, value)) }
                        if let value = node.attrs?.rowspan { attrs["rowspan"] = min(100, max(1, value)) }
                        if let value = node.attrs?.checked { attrs["checked"] = value }
                        if node.type == "divider" { attrs["style"] = "thinLine" }
                        result["attrs"] = attrs
                    }
                    if let children = node.content { result["content"] = try children.map(convert) }
                    if let marks = node.marks {
                        result["marks"] = marks.map { mark -> [String: Any] in
                            if mark.type == "link", let href = mark.attrs?.href { return ["type": "link", "attrs": ["href": href, "target": "_blank", "rel": "noopener noreferrer"]] }
                            return ["type": mark.type]
                        }
                    }
                    return result
                }
                let site = clip.siteName.trimmedNonEmpty ?? URL(string: clip.sourceURL)?.host ?? clip.sourceURL
                var metadata = [paragraph([text("Site: "), ["type": "text", "text": site, "marks": [["type": "bold"]]]])]
                let tags = try clip.tagIDs.map { id -> DocumentTag in
                    guard let tag = try DocumentTag.fetchOne(db,
                        sql: "SELECT * FROM documentTagRecords WHERE id=? AND spaceID=?",
                        arguments: [id, clip.spaceID]) else { throw VellixError.tagging("A selected tag is no longer in this Space.") }
                    return tag
                }
                if !tags.isEmpty {
                    var inline: [[String: Any]] = []
                    for tag in tags {
                        if !inline.isEmpty { inline.append(text(" ")) }
                        inline.append(["type": "inlineTag", "attrs": ["id": UUID().uuidString, "name": tag.name, "tagID": tag.id]])
                    }
                    metadata.append(paragraph(inline))
                }
                var saved = InlinePropertyDefinition()
                saved.kind = .date; saved.name = "Saved"; saved.includeTime = true
                saved.setDate(envelope.createdAt)
                metadata.append(["type": "inlineProperty", "attrs": ["id": UUID().uuidString, "property": try saved.bridgeObject()]])
                var source: [String: Any] = ["url": clip.sourceURL, "title": document.title]
                if let thumbnail = clip.thumbnailURL.flatMap({ files[$0] }) ?? envelope.assets.first.flatMap({ files[$0.source] }) {
                    source["file"] = thumbnail.object
                }
                var content: [[String: Any]] = [["type": "plainCallout", "attrs": ["id": UUID().uuidString,
                    "color": "#ffffff", "clipSource": source], "content": metadata]]
                content.append(["type": "divider", "attrs": ["id": UUID().uuidString, "style": "fourCircles"]])
                // Preserve a webpage's table of contents as an editable, icon-free
                // Penned callout with a heading and a bulleted list.
                func plainText(_ node: ClipperNode) -> String {
                    (node.text ?? "") + (node.content ?? []).map(plainText).joined()
                }
                func isTOCHeading(_ node: ClipperNode) -> Bool {
                    guard node.type == "heading" || node.type == "paragraph" else { return false }
                    let label = plainText(node).trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    return ["in this article", "table of contents", "contents", "on this page", "in this guide"].contains { label == $0 || label.hasPrefix($0 + ":") }
                }
                // Some sites expose a TOC as one paragraph: a label followed by
                // consecutive anchor links, rather than an HTML list.
                func inlineTOC(_ node: ClipperNode) -> (String, [ClipperNode])? {
                    guard node.type == "paragraph", let children = node.content else { return nil }
                    let fullText = plainText(node).trimmingCharacters(in: .whitespacesAndNewlines)
                    let labels = ["in this article", "table of contents", "on this page", "in this guide"]
                    guard let label = labels.first(where: { fullText.lowercased().hasPrefix($0) }) else { return nil }
                    let links = children.filter { child in
                        child.type == "text" && child.marks?.contains(where: { $0.type == "link" }) == true &&
                        !(child.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    guard links.count >= 2 else { return nil }
                    return (label, links)
                }
                func tocBullets(_ node: ClipperNode) -> ClipperNode? {
                    guard node.type == "orderedList" || node.type == "bulletList" else { return nil }
                    var list = node
                    list.type = "bulletList"
                    return list
                }
                func plainTextFromEditor(_ node: [String: Any]) -> String {
                    (node["text"] as? String ?? "") +
                    (node["content"] as? [[String: Any]] ?? []).map(plainTextFromEditor).joined()
                }
                // Build TOC callouts from the actual extracted nodes. A heading
                // and its list may be separated by layout-only empty paragraphs.
                // The plainCallout schema accepts block+ (heading + bulletList).
                func normalizedTOCTitle(_ value: String) -> String? {
                    let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                    let lower = title.lowercased()
                    return ["in this article", "table of contents", "contents", "on this page", "in this guide"]
                        .contains(lower) ? title : nil
                }
                func makeTOCCallout(title: String, list: [String: Any]) -> [String: Any] {
                    let heading: [String: Any] = ["type": "heading", "attrs": ["id": UUID().uuidString, "level": 3],
                                                  "content": [text(title)]]
                    var bullets = list
                    bullets["type"] = "bulletList"
                    return ["type": "plainCallout", "attrs": ["id": UUID().uuidString, "color": "#ffffff"],
                            "content": [heading, bullets]]
                }
                var index = 0
                while index < clip.content.count {
                    let node = clip.content[index]
                    if let (title, links) = inlineTOC(node) {
                        let items: [[String: Any]] = try links.map { link in
                            ["type": "listItem", "attrs": ["id": UUID().uuidString],
                             "content": [paragraph([try convert(link)])]]
                        }
                        let list: [String: Any] = ["type": "bulletList", "attrs": ["id": UUID().uuidString], "content": items]
                        content.append(makeTOCCallout(title: title, list: list))
                        index += 1
                        continue
                    }
                    if ["heading", "paragraph"].contains(node.type),
                       let title = normalizedTOCTitle(plainText(node)) {
                        var next = index + 1
                        while next < clip.content.count,
                              clip.content[next].type == "paragraph",
                              plainText(clip.content[next]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            next += 1
                        }
                        if next < clip.content.count, let list = tocBullets(clip.content[next]) {
                            content.append(makeTOCCallout(title: title, list: try convert(list)))
                            index = next + 1
                            continue
                        }
                    }
                    content.append(try convert(node))
                    index += 1
                }
                // Normalize any heading/list pair produced by other extraction
                // paths after conversion, before the document is persisted.
                var cursor = 0
                while cursor + 1 < content.count {
                    let candidate = content[cursor]
                    let kind = candidate["type"] as? String ?? ""
                    if ["heading", "paragraph"].contains(kind),
                       let title = normalizedTOCTitle(plainTextFromEditor(candidate)),
                       ["orderedList", "bulletList"].contains(content[cursor + 1]["type"] as? String ?? "") {
                        content.replaceSubrange(cursor...cursor + 1,
                                                with: [makeTOCCallout(title: title, list: content[cursor + 1])])
                    }
                    cursor += 1
                }
                if !clip.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    content.append(["type": "blockquote", "attrs": ["id": UUID().uuidString],
                        "content": clip.notes.components(separatedBy: .newlines).map { paragraph($0.isEmpty ? [] : [text($0)]) }])
                }
                _ = try repository.saveEditorJSON(id: document.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: content), in: db)
                try db.execute(sql: "INSERT INTO webClipImports(id,libraryID,documentID,sourceURL,author,siteName,createdAt) VALUES (?,?,?,?,?,?,?)",
                    arguments: [clip.id, database.libraryID, document.id, clip.sourceURL, clip.author, clip.siteName, envelope.createdAt])
                return document.id
            }
        } catch {
            for record in copied { try? store.removeFile(relativePath: record.relativePath) }
            throw error
        }
    }
    deinit { catalogueTask?.cancel(); if observing { notify.notify_cancel(notificationToken) } }
}
#endif
