import Foundation

// Visible previews are always safe; child bodies are added separately only for opted-in publications.
enum PublishingVisibleContent {
    static func prepare(_ root: [String: Any], document: DocumentRecord, repository: DocumentRepository,
                        collections: CollectionRepository, onlyVisibleEntryFields: Bool = false) throws -> [String: Any] {
        var referenced = Set<String>()
        let visibleCollectionIDs = Set(try collections.collectionIDs(forDocument: document.id))
        func page(_ record: DocumentRecord) throws -> [String: Any] {
            guard !record.isTrashed, !record.isArchived, record.templateID == nil else {
                throw PublishingFailure.invalidContent("A referenced page is unavailable.")
            }
            var preview: [String: Any] = ["title": record.title, "excerpt": String(record.previewText.prefix(400)),
                "targetDocumentID": record.id, "fontStyle": record.appearance.fontStyle.rawValue,
                "textColorHex": record.appearance.textColorHex]
            if let icon = record.icon { preview["icon"] = icon }
            if record.appearance.displaysCover {
                if let cover = record.cover { preview["cover"] = ["relativePath": cover] }
                else if let photo = record.appearance.coverPhoto { preview["coverPhoto"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(photo)) }
                else { preview["coverThemeID"] = record.appearance.resolvedCoverTheme.rawValue }
            }
            if let style = record.cardStyle {
                preview["cardStyle"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style))
            }
            return ["type": "publishedPage", "attrs": ["preview": preview]]
        }
        func collection(_ id: String) throws -> [String: Any] {
            let snapshot = try collections.snapshot(id: id)
            guard visibleCollectionIDs.contains(id), let view = snapshot.activeView else {
                throw PublishingFailure.invalidContent("A collection does not belong to the selected document.")
            }
            guard snapshot.views.count <= 100 else { throw PublishingFailure.invalidContent("A published collection supports up to 100 saved views.") }
            func presentation(_ view: CollectionViewRecord) throws -> [String: Any] {
            let fields = snapshot.visibleFields(in: view), entries = snapshot.presentedEntries(in: view)
            guard fields.count <= 100, entries.count <= 1000 else {
                throw PublishingFailure.invalidContent("A published collection supports up to 100 visible fields and 1,000 matching entries.")
            }
            let fieldKeys = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($0.element.id, "field-\($0.offset)") })
            let groups = view.kind == .kanban ? snapshot.kanbanGroups(in: view) : []
            let groupKeys = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.element.column.id, "group-\($0.offset)") })
            let ordered = view.kind == .kanban ? groups.flatMap(\.entries) : entries
            let rows = try ordered.map { entry -> [String: Any] in
                var result: [String: Any] = ["title": entry.title, "targetDocumentID": entry.id]
                result["values"] = Dictionary(uniqueKeysWithValues: fields.map { field in
                    let value = entry.values[field.id] ?? CollectionValue(), definition = field.configuration
                    var projected: [String: Any] = ["text": field.display(value, definition: definition), "empty": value.isEmpty,
                        "chips": definition.options.filter { value.optionIDs.contains($0.id) }.map { ["name": $0.name, "color": $0.color] }]
                    if let checked = value.checked { projected["checked"] = checked }
                    return (fieldKeys[field.id]!, projected)
                })
                if view.configuration.showsCover && entry.appearance.displaysCover {
                    if let path = entry.cover { result["cover"] = ["relativePath": path] }
                    else if let photo = entry.appearance.coverPhoto { result["coverPhoto"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(photo)) }
                    else { result["coverThemeID"] = entry.appearance.resolvedCoverTheme.rawValue }
                }
                if view.kind == .kanban, let column = view.configuration.kanbanColumnID(for: entry.id) {
                    result["group"] = groupKeys[column]
                }
                return result
            }
            return ["name": snapshot.name, "viewName": view.name, "kind": view.kind.rawValue,
                "galleryColumns": view.configuration.galleryColumns, "showsCover": view.configuration.showsCover,
                "compactCards": view.configuration.compactCards,
                "fields": fields.map { ["key": fieldKeys[$0.id]!, "name": $0.name, "kind": $0.kind.rawValue, "icon": $0.resolvedIcon] },
                "entries": rows,
                "groups": groups.map { ["key": groupKeys[$0.column.id]!, "name": $0.column.name, "color": $0.column.color, "collapsed": $0.column.collapsed] }]
            }
            var projection = try presentation(view)
            projection["activeViewKey"] = "view-\(snapshot.views.firstIndex(where: { $0.id == view.id }) ?? 0)"
            projection["views"] = try snapshot.views.enumerated().map { index, candidate -> [String: Any] in
                var result = try presentation(candidate)
                result["key"] = "view-\(index)"
                return result
            }
            return ["type": "publishedCollection", "attrs": ["projection": projection]]
        }
        func visit(_ node: [String: Any]) throws -> [String: Any] {
            let attrs = node["attrs"] as? [String: Any] ?? [:]
            if node["type"] as? String == "pageReference", let id = attrs["documentID"] as? String {
                referenced.insert(id)
                guard let record = try repository.document(id: id), !record.isTrashed, !record.isArchived, record.templateID == nil else {
                    return ["type": "privateReference"]
                }
                return try page(record)
            }
            if node["type"] as? String == "collection", let id = attrs["collectionID"] as? String {
                return try collection(id)
            }
            var result = node
            if let children = node["content"] as? [[String: Any]] { result["content"] = try children.map(visit) }
            return result
        }
        var result = try visit(root)
        var children = result["content"] as? [[String: Any]] ?? []
        if let id = try collections.collectionID(forEntry: document.id) {
            let snapshot = try collections.snapshot(id: id)
            if let entry = snapshot.entries.first(where: { $0.id == document.id }) {
                let visibleFields = Set(snapshot.views.filter { snapshot.presentedEntries(in: $0).contains(where: { $0.id == document.id }) }.flatMap { snapshot.visibleFields(in: $0).map(\.id) })
                let properties: [[String: Any]] = try snapshot.fields.filter { !onlyVisibleEntryFields || visibleFields.contains($0.id) }.map { field in
                    let property = (entry.values[field.id] ?? CollectionValue()).applying(to: field.configuration)
                    var value = try property.bridgeObject()
                    value["icon"] = field.resolvedIcon
                    return ["type": "inlineProperty", "attrs": ["property": value]]
                }
                children.insert(contentsOf: properties, at: 0)
            }
        }
        for child in try repository.children(of: document.id, includingCollectionEntries: false) where !referenced.contains(child.id) {
            children.append(try page(child))
        }
        result["content"] = children
        return result
    }

    static func paths(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            var result = Set([object["relativePath"], object["imagePath"]].compactMap { $0 as? String })
            for child in object.values { result.formUnion(paths(child)) }
            return result
        }
        if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(paths($1)) } }
        return []
    }

    static func media(_ value: Any, assets: [String: PublishingMedia]) throws -> Any {
        if var object = value as? [String: Any] {
            for key in ["relativePath", "imagePath"] {
                if let path = object.removeValue(forKey: key) as? String {
                    guard let asset = assets[path] else { throw PublishingFailure.invalidContent("Visible preview media is unavailable.") }
                    object["mediaID"] = asset.id
                }
            }
            return try object.mapValues { try media($0, assets: assets) }
        }
        if let array = value as? [Any] { return try array.map { try media($0, assets: assets) } }
        return value
    }
}
