import Foundation
import ImageIO
import UniformTypeIdentifiers

// OOXML, not HTML with a .docx extension. Word's unsupported effects fall back
// to editable text, with the full-fidelity rendition available as PDF.
struct DocumentWordExport {
    let snapshot: DocumentExportSnapshot
    let settings: DocumentExportSettings
    private var relationships: [String] = []
    private var media: [DocumentExportArchive.Entry] = []
    private var drawingID = 0
    private var font = "Arial"
    private var color = "222222"
    private var baseSize = 30
    private var listDefinitions: [String] = []
    private let x = DocumentExportNames.xml

    init(snapshot: DocumentExportSnapshot, settings: DocumentExportSettings) {
        self.snapshot = snapshot; self.settings = settings
    }

    mutating func write(to url: URL) throws {
        var body = ""
        for (index, page) in snapshot.pages.enumerated() {
            try Task.checkCancellation()
            let appearance = page.appearance
            font = settings.useStyle ? (appearance.fontStyle == .hachiMaruPop ? "Hachi Maru Pop" : appearance.fontStyle == .serif ? "Georgia" : appearance.fontStyle == .mono ? "Courier New" : appearance.fontStyle == .rounded ? "Arial Rounded MT Bold" : "Arial") : "Arial"
            color = settings.useStyle ? hex(appearance.textColorHex) : "222222"
            baseSize = Int(30 * settings.fontSize.scale)
            if index > 0 { body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" }
            if settings.showCover && appearance.displaysCover, let cover = page.cover { body += picture(path: cover, name: page.title) }
            if settings.showTitle { body += paragraph(run(page.title, extra: "<w:b/><w:sz w:val=\"52\"/>"), properties: "<w:pStyle w:val=\"Title\"/>") }
            if let subtitle = page.subtitle, !subtitle.isEmpty { body += paragraph(run(subtitle, extra: "<w:i/>")) }
            if let context = snapshot.contents[page.id]?.entryContext {
                for field in context.0.fields {
                    let value = context.1.values[field.id] ?? CollectionValue()
                    body += paragraph(run(field.name + ": ", extra: "<w:b/>") + run(field.display(value)))
                }
            }
            let nodes = TipTapContentAnalyzer.documentObject(from: page.tipTapJSON)["content"] as? [[String: Any]] ?? []
            body += blocks(nodes, page: page)
        }
        let size = settings.paper.size
        let section = "<w:sectPr><w:pgSz w:w=\"\(Int(size.width * 20))\" w:h=\"\(Int(size.height * 20))\"/><w:pgMar w:top=\"720\" w:right=\"720\" w:bottom=\"720\" w:left=\"720\"/></w:sectPr>"
        let background = settings.useStyle ? "<w:background w:color=\"\(hex(snapshot.root.appearance.innerPageBackground.colorHex))\"/>" : ""
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">\(background)<w:body>\(body)\(section)</w:body></w:document>"
        let types = "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/><Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/></Types>"
        let rootRels = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"document\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        let rels = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"styles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/><Relationship Id=\"numbering\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>\(relationships.joined())</Relationships>"
        let styles = "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:docDefaults><w:pPrDefault><w:pPr><w:spacing w:after=\"140\" w:line=\"280\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style><w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:keepNext/></w:pPr></w:style></w:styles>"
        let parts: [(String, String)] = [("[Content_Types].xml", types), ("_rels/.rels", rootRels), ("word/document.xml", document), ("word/_rels/document.xml.rels", rels), ("word/styles.xml", styles), ("word/numbering.xml", numbering)]
        try DocumentExportArchive.write(parts.map { .init($0.0, data: Data($0.1.utf8)) } + media, to: url)
    }

    private func hex(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "#", with: "")
        return clean.count == 6 && clean.allSatisfy(\.isHexDigit) ? clean : "222222"
    }
    private func paragraph(_ text: String, properties: String = "") -> String { "<w:p><w:pPr>\(properties)</w:pPr>\(text)</w:p>" }
    private func run(_ text: String, extra: String = "") -> String {
        let fonts = extra.contains("<w:rFonts") ? "" : "<w:rFonts w:ascii=\"\(x(font))\" w:hAnsi=\"\(x(font))\"/>"
        let ink = extra.contains("<w:color") ? "" : "<w:color w:val=\"\(color)\"/>"
        let size = extra.contains("<w:sz ") ? "" : "<w:sz w:val=\"\(baseSize)\"/>"
        let properties = fonts + ink + size + extra
        let pieces = text.components(separatedBy: "\n").map { "<w:t xml:space=\"preserve\">\(x($0))</w:t>" }.joined(separator: "<w:br/>")
        return "<w:r><w:rPr>\(properties)</w:rPr>\(pieces)</w:r>"
    }
    private mutating func inline(_ nodes: [[String: Any]]) -> String {
        nodes.map { node in
            let type = node["type"] as? String ?? "text"
            if type == "hardBreak" { return "<w:r><w:br/></w:r>" }
            if type == "inlineTag" {
                guard settings.showTags else { return "" }
                return run("#" + ((node["attrs"] as? [String: Any])?["name"] as? String ?? ""))
            }
            var properties = "", href: String?
            for mark in node["marks"] as? [[String: Any]] ?? [] {
                let attrs = mark["attrs"] as? [String: Any] ?? [:]
                switch mark["type"] as? String {
                case "bold": properties += "<w:b/>"
                case "italic": properties += "<w:i/>"
                case "underline": properties += "<w:u w:val=\"single\"/>"
                case "strike": properties += "<w:strike/>"
                case "code": properties += "<w:rFonts w:ascii=\"Courier New\"/><w:shd w:fill=\"EEEEEE\"/>"
                case "link": href = attrs["href"] as? String
                case "highlight": properties += "<w:shd w:fill=\"\(hex(attrs["color"] as? String ?? "#FFFF00"))\"/>"
                case "textStyle":
                    if let value = InlineTextColor.markAttributes(attrs) { properties += "<w:color w:val=\"\(hex(value.start))\"/>" }
                default: break
                }
            }
            let value = run(node["text"] as? String ?? "", extra: properties)
            guard let href, let url = URL(string: href), ["https", "http", "mailto", "penned"].contains(url.scheme?.lowercased() ?? "") else { return value }
            let id = relationship(type: "hyperlink", target: href, external: true)
            return "<w:hyperlink r:id=\"\(id)\">\(value)</w:hyperlink>"
        }.joined()
    }
    private mutating func blocks(_ nodes: [[String: Any]], page: DocumentRecord, depth: Int = 0, list: Int? = nil) -> String {
        var output = ""
        for node in nodes {
            let type = node["type"] as? String ?? "paragraph", attrs = node["attrs"] as? [String: Any] ?? [:]
            let children = node["content"] as? [[String: Any]] ?? []
            var properties = ""
            if let align = attrs["textAlign"] as? String, ["left", "right", "center", "justify"].contains(align) { properties += "<w:jc w:val=\"\(align)\"/>" }
            if let list { properties += "<w:numPr><w:ilvl w:val=\"\(min(depth, 8))\"/><w:numId w:val=\"\(list)\"/></w:numPr>" }
            switch type {
            case "paragraph", "heading", "caption":
                var text = inline(children)
                if type == "heading" {
                    let level = min(6, max(1, attrs["level"] as? Int ?? 1))
                    properties += "<w:keepNext/><w:outlineLvl w:val=\"\(level - 1)\"/>"
                    let scale = [2.05, 1.62, 1.42, 1.2, 1.1, 1.0][level - 1]
                    text = text.replacingOccurrences(of: "<w:b/>", with: "").replacingOccurrences(of: "<w:sz w:val=\"\(baseSize)\"/>", with: "<w:b/><w:sz w:val=\"\(Int(Double(baseSize) * scale))\"/>")
                } else if type == "caption" { text = text.replacingOccurrences(of: "<w:sz w:val=\"\(baseSize)\"/>", with: "<w:sz w:val=\"\(max(12, baseSize - 4))\"/>") }
                output += paragraph(text, properties: properties)
            case "bulletList", "orderedList", "taskList":
                let nextDepth = list == nil ? depth : depth + 1
                var numberID = type == "taskList" ? nil : Optional(1)
                if type == "orderedList" {
                    let id = listDefinitions.count + 3
                    let start = max(1, attrs["start"] as? Int ?? 1)
                    listDefinitions.append("<w:num w:numId=\"\(id)\"><w:abstractNumId w:val=\"2\"/><w:lvlOverride w:ilvl=\"\(min(nextDepth, 8))\"><w:startOverride w:val=\"\(start)\"/></w:lvlOverride></w:num>")
                    numberID = id
                }
                for item in children {
                    var content = item["content"] as? [[String: Any]] ?? []
                    if type == "taskList", !content.isEmpty {
                        var first = content[0], text = first["content"] as? [[String: Any]] ?? []
                        let checked = (item["attrs"] as? [String: Any])?["checked"] as? Bool == true
                        text.insert(["type": "text", "text": checked ? "[x] " : "[ ] "], at: 0); first["content"] = text; content[0] = first
                    }
                    output += blocks(content, page: page, depth: nextDepth, list: numberID)
                }
            case "blockquote", "callout", "plainCallout":
                let nested = blocks(children, page: page, depth: depth)
                let shade = hex(attrs["color"] as? String ?? "#EEEEEE")
                output += nested.replacingOccurrences(of: "<w:pPr>", with: "<w:pPr><w:ind w:left=\"360\"/><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"\(shade)\"/></w:pBdr>")
            case "codeBlock":
                let text = children.map { $0["text"] as? String ?? "" }.joined()
                output += paragraph(run(text, extra: "<w:rFonts w:ascii=\"Courier New\"/><w:sz w:val=\"18\"/>"), properties: "<w:shd w:fill=\"EEEEEE\"/>")
            case "divider", "horizontalRule": output += paragraph("", properties: "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:color=\"888888\"/></w:pBdr>")
            case "pageBreak": output += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            case "table":
                let rows = children.map { row in
                    "<w:tr>" + (row["content"] as? [[String: Any]] ?? []).map { cell in
                        let a = cell["attrs"] as? [String: Any] ?? [:]
                        let span = max(1, a["colspan"] as? Int ?? 1)
                        let shading = ((a["fillColor"] ?? a["backgroundColor"]) as? String).map { "<w:shd w:fill=\"\(hex($0))\"/>" } ?? ""
                        let originalColor = color
                        if let ink = a["textColor"] as? String { color = hex(ink) }
                        var text = blocks(cell["content"] as? [[String: Any]] ?? [], page: page)
                        color = originalColor
                        if let calculated = a["calculated"], !(calculated is NSNull), a["formula"] as? String != nil {
                            text = paragraph(run(String(describing: calculated)))
                        }
                        if let align = a["align"] as? String, ["left", "center", "right", "justify"].contains(align) {
                            text = text.replacingOccurrences(of: "<w:pPr>", with: "<w:pPr><w:jc w:val=\"\(align)\"/>")
                        }
                        return "<w:tc><w:tcPr><w:gridSpan w:val=\"\(span)\"/>\(shading)</w:tcPr>\(text.isEmpty ? "<w:p/>" : text)</w:tc>"
                    }.joined() + "</w:tr>"
                }.joined()
                output += table(rows)
            case "attachment":
                let file = attrs["file"] as? [String: Any] ?? [:], path = file["relativePath"] as? String ?? ""
                if file["kind"] as? String == "image" { output += picture(path: path, name: file["name"] as? String ?? "Image") }
                else { output += paragraph(run("Attachment: " + (file["name"] as? String ?? path))) }
                if let caption = attrs["caption"] as? String, !caption.isEmpty { output += paragraph(run(caption, extra: "<w:i/>")) }
            case "image":
                let src = attrs["src"] as? String ?? ""
                if snapshot.assets[src] != nil { output += picture(path: src, name: attrs["alt"] as? String ?? "Image") }
                else { output += paragraph(run("Image: " + (attrs["alt"] as? String ?? src))) }
            case "inlineProperty":
                if let property = InlinePropertyDefinition.decode(attrs["property"]) { output += paragraph(run(property.name + ": ", extra: "<w:b/>") + run(property.displayValue())) }
            case "collection":
                if let payload = snapshot.collections(for: page).first(where: { $0["id"] as? String == attrs["collectionID"] as? String }) {
                    output += paragraph(run(payload["name"] as? String ?? "Collection", extra: "<w:b/>"))
                    let fields = payload["fields"] as? [[String: Any]] ?? []
                    var rows = "<w:tr>" + (["Title"] + fields.map { $0["name"] as? String ?? "Property" }).map { "<w:tc>\(paragraph(run($0, extra: "<w:b/>")))</w:tc>" }.joined() + "</w:tr>"
                    for entry in payload["entries"] as? [[String: Any]] ?? [] {
                        let values = entry["values"] as? [String: [String: Any]] ?? [:]
                        let cells = [entry["title"] as? String ?? "Untitled"] + fields.map { values[$0["id"] as? String ?? ""]?["text"] as? String ?? "Not set" }
                        rows += "<w:tr>" + cells.map { "<w:tc>\(paragraph(run($0)))</w:tc>" }.joined() + "</w:tr>"
                    }
                    output += table(rows)
                }
            case "pageReference":
                let id = attrs["documentID"] as? String ?? ""
                let child = snapshot.pages.first { $0.id == id } ?? snapshot.contents[page.id]?.children.first { $0.id == id }
                output += paragraph(run(child?.title ?? "Nested Page", extra: "<w:b/>"))
            case "templateComponent":
                let value = DocumentMarkdownExport(snapshot: snapshot, settings: settings)
                // The response is emitted by the same semantic serializer as Markdown.
                output += paragraph(run(value.componentText(attrs)))
            default: output += blocks(children, page: page, depth: depth, list: list)
            }
        }
        return output
    }
    private func table(_ rows: String) -> String {
        let edges = ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"AAAAAA\"/>" }.joined()
        return "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>\(edges)</w:tblBorders></w:tblPr>\(rows)</w:tbl><w:p/>"
    }
    private mutating func relationship(type: String, target: String, external: Bool = false) -> String {
        let id = "rId\(relationships.count + 1)"
        relationships.append("<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(type)\" Target=\"\(x(target))\"\(external ? " TargetMode=\"External\"" : "")/>")
        return id
    }
    private mutating func picture(path: String, name: String) -> String {
        guard let url = snapshot.assets[path], let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return paragraph(run("Image unavailable: " + name)) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return paragraph(run(name)) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return paragraph(run(name)) }
        drawingID += 1
        let file = "image\(drawingID).png"
        media.append(.init("word/media/" + file, data: data as Data))
        let id = relationship(type: "image", target: "media/" + file)
        let maxWidth = Double(settings.paper.size.width - 72), maxHeight = Double(settings.paper.size.height - 120)
        let scale = min(1, min(maxWidth / Double(image.width), maxHeight / Double(image.height)))
        let width = Int(Double(image.width) * scale * 12700), height = Int(Double(image.height) * scale * 12700)
        return "<w:p><w:r><w:drawing><wp:inline><wp:extent cx=\"\(width)\" cy=\"\(height)\"/><wp:docPr id=\"\(drawingID)\" name=\"\(x(name))\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(drawingID)\" name=\"\(x(name))\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(id)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
    }
    private var numbering: String {
        let definitions = [(1, "bullet", "•"), (2, "decimal", "%1.")].map { id, format, text in
            let levels = (0...8).map { level in "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(format == "decimal" ? "%\(level + 1)." : text)\"/><w:pPr><w:ind w:left=\"\((level + 1) * 360)\" w:hanging=\"240\"/></w:pPr></w:lvl>" }.joined()
            return "<w:abstractNum w:abstractNumId=\"\(id)\">\(levels)</w:abstractNum><w:num w:numId=\"\(id)\"><w:abstractNumId w:val=\"\(id)\"/></w:num>"
        }.joined()
        return "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(definitions)\(listDefinitions.joined())</w:numbering>"
    }
}
