import Foundation

nonisolated enum PublishingProjection {
    static let attributes: [String: Set<String>] = [
        "doc": [], "text": [], "paragraph": [], "caption": [], "heading": ["level"], "hardBreak": [],
        "bulletList": [], "orderedList": ["start", "type"], "listItem": [], "codeBlock": ["language"],
        "blockquote": ["color"], "callout": ["icon", "color"], "plainCallout": ["color"],
        "divider": ["style"], "pageBreak": [], "toggleItem": ["open"], "taskList": [], "taskItem": ["checked", "crossed"],
        "templateComponent": ["definition", "response"], "inlineProperty": ["property"],
        "table": ["name", "leftOffset", "stripeColor", "columnless", "rowless", "rowCount", "columnCount", "headerRow"],
        "tableRow": [], "tableCell": ["colspan", "rowspan", "colwidth", "fillColor", "textColor", "formula", "calculated", "font", "bold", "italic", "strike", "code", "align", "format", "decimals", "currency"],
        "tableHeader": ["colspan", "rowspan", "colwidth", "fillColor", "textColor", "formula", "calculated", "font", "bold", "italic", "strike", "code", "align", "format", "decimals", "currency"],
        "attachment": ["displayMode", "widthPercent"], "inlineTag": ["name"]
    ]
    static let nestedKeys: Set<String> = ["kind", "name", "label", "value", "checked", "options", "id", "color", "selectedOptionIDs", "prefix", "suffix", "minimum", "maximum", "step", "urlLabel", "includeTime", "placeholder", "icon", "title", "choices", "style", "symbol", "maxRating", "minimumLabel", "maximumLabel", "start", "end", "angle"]

    static func paths(in content: [String: Any]) -> Set<String> {
        guard let type = content["type"] as? String, type != "pageReference", type != "collection" else { return [] }
        var paths: Set<String> = []
        if type == "attachment", let attrs = content["attrs"] as? [String: Any], let file = attrs["file"] as? [String: Any] {
            for key in ["relativePath", "previewPath"] { if let path = file[key] as? String { paths.insert(path) } }
        }
        for child in content["content"] as? [[String: Any]] ?? [] { paths.formUnion(self.paths(in: child)) }
        return paths
    }

    static func content(_ source: [String: Any], media: [String: PublishingMedia], depth: Int = 0) throws -> [String: Any] {
        guard depth <= 64, let type = source["type"] as? String else { throw PublishingFailure.invalidContent("Invalid document structure.") }
        if ["pageReference", "privateReference"].contains(type) { return ["type": "privateReference"] }
        if ["collection", "privateCollection"].contains(type) { return ["type": "privateCollection"] }
        if ["publishedPage", "publishedCollection"].contains(type) {
            let attrs = source["attrs"] as? [String: Any] ?? [:]
            return ["type": type, "attrs": try PublishingVisibleContent.media(attrs, assets: media)]
        }
        guard let allowed = attributes[type] else { throw PublishingFailure.invalidContent("Unsupported block: \(type).") }
        if source["content"] != nil && !(source["content"] is [[String: Any]]) { throw PublishingFailure.invalidContent("Invalid block content.") }
        if source["marks"] != nil && !(source["marks"] is [[String: Any]]) { throw PublishingFailure.invalidContent("Invalid text formatting.") }
        if source["attrs"] != nil && !(source["attrs"] is [String: Any]) { throw PublishingFailure.invalidContent("Invalid block attributes.") }
        var result: [String: Any] = ["type": type]
        if type == "text" { result["text"] = source["text"] as? String ?? "" }
        if let attrs = source["attrs"] as? [String: Any], type != "doc" {
            var approved = try attrs.filter { allowed.union(["id", "textAlign", "indent"]).contains($0.key) }
                .mapValues { try nested($0) }
            if type == "attachment" {
                guard let file = attrs["file"] as? [String: Any], let path = file["relativePath"] as? String, let asset = media[path] else {
                    throw PublishingFailure.invalidContent("An attachment is unavailable.")
                }
                var value: [String: Any] = ["mediaID": asset.id, "kind": file["kind"] as? String ?? "file"]
                for key in ["width", "height"] { if let dimension = file[key] as? Int, dimension > 0, dimension <= 30000 { value[key] = dimension } }
                if let path = file["previewPath"] as? String, let preview = media[path] { value["previewMediaID"] = preview.id }
                approved["file"] = value
            }
            if !approved.isEmpty { result["attrs"] = approved }
        }
        if let children = source["content"] as? [[String: Any]] { result["content"] = try children.map { try content($0, media: media, depth: depth + 1) } }
        if let marks = source["marks"] as? [[String: Any]] {
            result["marks"] = try marks.compactMap { mark -> [String: Any]? in
                guard let type = mark["type"] as? String else { return nil }
                if ["bold", "italic", "underline", "strike", "code"].contains(type) { return ["type": type] }
                let attrs = mark["attrs"] as? [String: Any] ?? [:]
                if type == "link" {
                    guard let href = attrs["href"] as? String, let url = URL(string: href),
                          href.hasPrefix("#") || ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
                    return ["type": type, "attrs": ["href": href]]
                }
                if type == "textStyle" { return ["type": type, "attrs": try attrs.filter { ["color", "gradient"].contains($0.key) }.mapValues { try nested($0) }] }
                throw PublishingFailure.invalidContent("Unsupported text formatting: \(type).")
            }
        }
        return result
    }

    private static func nested(_ value: Any, depth: Int = 0) throws -> Any {
        guard depth <= 8 else { throw PublishingFailure.invalidContent("A block is too deeply nested.") }
        if let object = value as? [String: Any] { return try object.filter { nestedKeys.contains($0.key) }.mapValues { try nested($0, depth: depth + 1) } }
        if let array = value as? [Any] { return try array.map { try nested($0, depth: depth + 1) } }
        return value
    }
}
