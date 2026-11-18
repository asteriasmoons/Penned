import Foundation

nonisolated enum PublishingProjection {
    static let attributes: [String: Set<String>] = [
        "doc": [], "text": [], "paragraph": [], "caption": [], "heading": ["level"], "hardBreak": [],
        "bulletList": [], "orderedList": ["start", "type"], "listItem": [], "codeBlock": ["language"],
        "blockquote": ["color"], "callout": ["icon", "color"], "plainCallout": ["color", "textColor", "widthPercent", "minimumHeight"], "plainCalloutRow": [],
        "gridCard": ["icon", "iconColor", "backgroundColor", "title", "alignment", "width", "height"],
        "iconCallout": ["icon", "iconColor", "backgroundColor", "textColor", "imageTint"],
        "richLink": ["href", "layout", "metadata"],
        "divider": ["style", "color"], "pageBreak": [], "toggleItem": ["open"], "taskList": [], "taskItem": ["checked", "crossed"],
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
        if type == "plainCallout", let source = (content["attrs"] as? [String: Any])?["clipSource"] as? [String: Any],
           let file = source["file"] as? [String: Any] {
            for key in ["relativePath", "previewPath"] { if let path = file[key] as? String { paths.insert(path) } }
        }
        if type == "divider", let attrs = content["attrs"] as? [String: Any], attrs["style"] as? String == "washiTape",
           let path = attrs["imagePath"] as? String { paths.insert(path) }
        if type == "iconCallout", let path = (content["attrs"] as? [String: Any])?["imagePath"] as? String { paths.insert(path) }
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
            if type == "heading", let label = HeadingLabelSettings.configuration(attrs), label.enabled {
                approved["label"] = label.payload
            }
            if type == "richLink" {
                guard let href = attrs["href"] as? String, let url = DocumentLinkURL.web(href) else {
                    throw PublishingFailure.invalidContent("A Rich Link has an invalid URL.")
                }
                approved["href"] = url.absoluteString
                let metadata = attrs["metadata"] as? [String: Any] ?? [:]
                var preview: [String: String] = [:]
                for key in ["title", "description", "site"] { preview[key] = metadata[key] as? String }
                for key in ["image", "favicon"] {
                    preview[key] = (metadata[key] as? String).flatMap(DocumentLinkURL.web)?.absoluteString
                }
                approved["metadata"] = preview
            }
            if type == "attachment" {
                guard let file = attrs["file"] as? [String: Any], let path = file["relativePath"] as? String, let asset = media[path] else {
                    throw PublishingFailure.invalidContent("An attachment is unavailable.")
                }
                var value: [String: Any] = ["mediaID": asset.id, "kind": file["kind"] as? String ?? "file"]
                for key in ["width", "height"] { if let dimension = file[key] as? Int, dimension > 0, dimension <= 30000 { value[key] = dimension } }
                if let path = file["previewPath"] as? String, let preview = media[path] { value["previewMediaID"] = preview.id }
                approved["file"] = value
            }
            if type == "divider", attrs["style"] as? String == "washiTape" {
                if WashiTapeSize(attrs["tapeSize"]) == .thin { approved["tapeSize"] = "thin" }
                if let path = attrs["imagePath"] as? String {
                    guard let asset = media[path] else { throw PublishingFailure.invalidContent("A Washi Tape image is unavailable.") }
                    approved["mediaID"] = asset.id
                } else if let photo = WashiTapeRequest.photo(attrs["remotePhoto"]) {
                    approved["remotePhoto"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(photo))
                }
            }
            if type == "iconCallout", let path = attrs["imagePath"] as? String {
                guard let asset = media[path] else { throw PublishingFailure.invalidContent("A callout icon image is unavailable.") }
                approved["mediaID"] = asset.id
            }
            if type == "plainCallout", let source = attrs["clipSource"] as? [String: Any],
               let href = source["url"] as? String, let url = InlinePropertyDefinition.safeURL(href) {
                var value: [String: Any] = ["url": url.absoluteString, "title": source["title"] as? String ?? href]
                if let file = source["file"] as? [String: Any], let path = file["relativePath"] as? String {
                    guard let asset = media[path] else { throw PublishingFailure.invalidContent("The source preview image is unavailable.") }
                    var publishedFile: [String: Any] = ["mediaID": asset.id, "kind": "image"]
                    if let previewPath = file["previewPath"] as? String, let preview = media[previewPath] { publishedFile["previewMediaID"] = preview.id }
                    value["file"] = publishedFile
                }
                approved["clipSource"] = value
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
