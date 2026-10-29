import Foundation

struct DocumentMarkdownExport {
    let snapshot: DocumentExportSnapshot
    let settings: DocumentExportSettings
    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "~", with: "\\~")
    }
    private func destination(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: "(", with: "%28")
    }
    private func asset(_ path: String) -> String { "assets/" + destination(snapshot.assetFilename(path)) }
    func componentText(_ attrs: [String: Any]) -> String {
        let definition = attrs["definition"] as? [String: Any] ?? [:]
        let label = definition["label"] as? String ?? ""
        let choices = definition["choices"] as? [[String: Any]] ?? []
        let selected = Set((attrs["response"] as? [String]) ?? (attrs["response"] as? String).map { [$0] } ?? [])
        if !choices.isEmpty {
            return label + "\n" + choices.map { (selected.contains($0["id"] as? String ?? "") ? "[x] " : "[ ] ") + ($0["label"] as? String ?? "") }.joined(separator: "\n")
        }
        return label + ": " + (attrs["response"] is NSNull ? "Not set" : String(describing: attrs["response"] ?? "Not set"))
    }
    func text() -> String {
        let page = snapshot.root
        let title = settings.showTitle ? String(repeating: "#", count: settings.headingLevel) + " " + escape(page.title) + "\n\n" : ""
        let subtitle = page.subtitle.map { escape($0) + "\n\n" } ?? ""
        let cover = ""  // Markdown export excludes images, including the cover.
        let nodes = TipTapContentAnalyzer.documentObject(from: page.tipTapJSON)["content"] as? [[String: Any]] ?? []
        return title + subtitle + cover + blocks(nodes, page: page) + "\n"
    }
    private func inline(_ nodes: [[String: Any]]) -> String {
        nodes.map { node -> String in
            let type = node["type"] as? String ?? "text", attrs = node["attrs"] as? [String: Any] ?? [:]
            if type == "hardBreak" { return "  \n" }
            if type == "inlineTag" { return settings.showTags ? "#" + escape(attrs["name"] as? String ?? "") : "" }
            var value = escape(node["text"] as? String ?? "")
            for mark in node["marks"] as? [[String: Any]] ?? [] {
                let attr = mark["attrs"] as? [String: Any] ?? [:]
                switch mark["type"] as? String {
                case "bold": value = settings.strongDelimiter + value + settings.strongDelimiter
                case "italic": value = settings.italicDelimiter + value + settings.italicDelimiter
                case "strike": value = "~~" + value + "~~"
                case "code":
                    let raw = node["text"] as? String ?? "", fence = String(repeating: "`", count: max(1, raw.split(separator: "`", omittingEmptySubsequences: false).count))
                    value = fence + " " + raw + " " + fence
                case "link": break  // Markdown export keeps link text only, not the URL.
                default: break
                }
            }
            return value
        }.joined()
    }
    private func blocks(_ nodes: [[String: Any]], page: DocumentRecord) -> String {
        nodes.map { block($0, page: page) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private func block(_ node: [String: Any], page: DocumentRecord) -> String {
        let type = node["type"] as? String ?? "paragraph", attrs = node["attrs"] as? [String: Any] ?? [:]
        let children = node["content"] as? [[String: Any]] ?? []
        switch type {
        case "text": return inline([node])
        case "paragraph": return inline(children)
        case "caption": return inline(children)
        case "heading": return String(repeating: "#", count: min(6, max(1, attrs["level"] as? Int ?? 1))) + " " + inline(children)
        case "codeBlock":
            let value = children.map { $0["text"] as? String ?? "" }.joined()
            let fence = String(repeating: "`", count: max(3, value.split(separator: "`", omittingEmptySubsequences: false).count))
            return fence + (attrs["language"] as? String ?? "") + "\n" + value + "\n" + fence
        case "bulletList", "orderedList", "taskList":
            return children.enumerated().map { index, item in
                let checked = (item["attrs"] as? [String: Any])?["checked"] as? Bool == true
                let prefix = type == "taskList" ? (checked ? "- [x] " : "- [ ] ") : type == "orderedList" ? "\((attrs["start"] as? Int ?? 1) + index). " : "- "
                let content = blocks(item["content"] as? [[String: Any]] ?? [], page: page).components(separatedBy: "\n")
                return prefix + (content.first ?? "") + content.dropFirst().map { "\n" + String(repeating: " ", count: prefix.count) + $0 }.joined()
            }.joined(separator: "\n")
        case "listItem", "taskItem", "doc": return blocks(children, page: page)
        case "blockquote", "callout", "plainCallout":
            let prefix = type == "blockquote" ? "" : "[!NOTE]\n"
            return (prefix + blocks(children, page: page)).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        case "toggleItem":
            let heading = children.first.map { block($0, page: page) } ?? ""
            return heading + "\n\n" + blocks(Array(children.dropFirst()), page: page)
        case "divider", "horizontalRule": return settings.rule
        case "pageBreak": return ""
        case "table":
            let rows = children.map { row in (row["content"] as? [[String: Any]] ?? []).map {
                blocks($0["content"] as? [[String: Any]] ?? [], page: page).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
            } }
            guard let first = rows.first else { return "" }
            let count = rows.map(\.count).max() ?? first.count
            func row(_ cells: [String]) -> String { "| " + (cells + Array(repeating: "", count: max(0, count - cells.count))).joined(separator: " | ") + " |" }
            return ([row(first), row(Array(repeating: "---", count: count))] + rows.dropFirst().map(row)).joined(separator: "\n")
        case "attachment":
            // Markdown export excludes images and file links; keep non-image attachment names as plain text.
            guard let file = attrs["file"] as? [String: Any], let path = file["relativePath"] as? String else { return "" }
            if file["kind"] as? String == "image" { return "" }
            let name = escape(snapshot.assetNames[path] ?? URL(fileURLWithPath: path).lastPathComponent)
            return name + (attrs["caption"] as? String).map { "\n\n" + escape($0) }.orEmpty
        case "image": return ""  // Markdown export excludes images.
        case "pageReference": return ""  // Markdown export excludes nested-page links/content.
        case "collection":
            guard let id = attrs["collectionID"] as? String, let payload = snapshot.collections(for: page).first(where: { $0["id"] as? String == id }) else { return "Collection unavailable" }
            let fields = payload["fields"] as? [[String: Any]] ?? [], entries = payload["entries"] as? [[String: Any]] ?? []
            let header = ["Title"] + fields.map { $0["name"] as? String ?? "Property" }
            func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
            let rows = entries.map { entry -> String in
                let values = entry["values"] as? [String: [String: Any]] ?? [:]
                let row = [entry["title"] as? String ?? "Untitled"] + fields.map { values[$0["id"] as? String ?? ""]?["text"] as? String ?? "Not set" }
                return "| " + row.map(cell).joined(separator: " | ") + " |"
            }
            return "### " + escape(payload["name"] as? String ?? "Collection") + "\n\n| " + header.map(cell).joined(separator: " | ") + " |\n| " + header.map { _ in "---" }.joined(separator: " | ") + " |\n" + rows.joined(separator: "\n")
        case "inlineProperty":
            if let property = InlinePropertyDefinition.decode(attrs["property"]) { return "**" + escape(property.name) + ":** " + escape(property.displayValue()) }
            return blocks(children, page: page)
        case "templateComponent":
            let definition = attrs["definition"] as? [String: Any] ?? [:]
            let label = definition["label"] as? String ?? ""
            let choices = definition["choices"] as? [[String: Any]] ?? []
            let selected = Set((attrs["response"] as? [String]) ?? (attrs["response"] as? String).map { [$0] } ?? [])
            if !choices.isEmpty { return "**" + escape(label) + "**\n\n" + choices.map { "- [" + (selected.contains($0["id"] as? String ?? "") ? "x" : " ") + "] " + escape($0["label"] as? String ?? "") }.joined(separator: "\n") }
            return "**" + escape(label) + ":** " + String(describing: attrs["response"] ?? "Not set")
        default:
            if !children.isEmpty { return blocks(children, page: page) }
            let fields = attrs.keys.sorted().filter { !["id", "indent", "placeholderEnabled", "placeholderGuidance"].contains($0) }.compactMap { key -> String? in
                guard let value = attrs[key], value is String || value is NSNumber else { return nil }
                return "- " + escape(key) + ": " + escape(String(describing: value))
            }
            return fields.isEmpty ? "" : "**" + escape(type) + "**\n\n" + fields.joined(separator: "\n")
        }
    }
}

private extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }
