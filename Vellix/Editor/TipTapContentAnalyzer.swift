//
//  TipTapContentAnalyzer.swift
//  Vellix
//

import Foundation

struct TipTapAnalysis: Equatable {
    var canonicalJSON: String
    var plainText: String
    var previewText: String
    var headings: [String]
    var wordCount: Int
    var characterCount: Int
    var estimatedReadingMinutes: Int
    var isEffectivelyEmpty: Bool
}

enum TipTapContentAnalyzer {
    nonisolated static let emptyDocumentJSON = #"{"content":[{"attrs":{"id":"empty"},"type":"paragraph"}],"type":"doc"}"#

    nonisolated static func analyze(_ jsonString: String) throws -> TipTapAnalysis {
        guard let data = jsonString.data(using: .utf8) else {
            throw VellixError.invalidEditorJSON("The payload was not UTF-8 text.")
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            return try analyzeJSONObject(object)
        } catch let error as VellixError {
            throw error
        } catch {
            throw VellixError.invalidEditorJSON(error.localizedDescription)
        }
    }

    nonisolated static func analyzePayload(_ payload: Any?) throws -> TipTapAnalysis {
        guard let payload else {
            throw VellixError.invalidEditorJSON("The editor payload was empty.")
        }

        return try analyzeJSONObject(payload)
    }

    nonisolated static func normalizePayloadToJSON(_ payload: Any?) throws -> String {
        try analyzePayload(payload).canonicalJSON
    }

    nonisolated static func documentObject(from canonicalJSON: String) -> [String: Any] {
        guard
            let data = canonicalJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return [
                "type": "doc",
                "content": []
            ]
        }

        return normalizeDocumentObject(object)
    }

    nonisolated static func makeDocumentJSON(content: [Any]) throws -> String {
        try canonicalJSONString(from: [
            "type": "doc",
            "content": normalizeTipTapNodes(content)
        ])
    }

    nonisolated static func starterDocument(title: String, lines: [String] = []) -> String {
        let content = lines.map { line in
            [
                "type": "paragraph",
                "attrs": ["id": UUID().uuidString],
                "content": [
                    [
                        "type": "text",
                        "text": line
                    ]
                ]
            ] as [String: Any]
        }

        if let json = try? makeDocumentJSON(content: content) {
            return json
        }

        return emptyDocumentJSON
    }

    nonisolated static func pageReferenceIDs(in json: String) -> Set<String> {
        var result = Set<String>()
        func visit(_ node: [String: Any]) {
            if node["type"] as? String == "taskItem", let attrs = node["attrs"] as? [String: Any],
               let task = DocumentTaskMetadata.decode(attrs["trackedTask"]) {
                result.insert(DocumentTaskPages.detailID(task.id))
            }
            if node["type"] as? String == "pageReference",
               let attrs = node["attrs"] as? [String: Any],
               let id = attrs["documentID"] as? String, !id.isEmpty { result.insert(id) }
            for child in node["content"] as? [[String: Any]] ?? [] { visit(child) }
        }
        visit(documentObject(from: json))
        return result
    }

    nonisolated static func collectionIDs(in json: String) -> Set<String> {
        var result = Set<String>()
        func visit(_ node: [String: Any]) {
            if node["type"] as? String == "collection", let attrs = node["attrs"] as? [String: Any],
               let id = attrs["collectionID"] as? String, !id.isEmpty { result.insert(id) }
            for child in node["content"] as? [[String: Any]] ?? [] { visit(child) }
        }
        visit(documentObject(from: json))
        return result
    }

    nonisolated static func hasInlineProperties(in json: String) -> Bool {
        func contains(_ node: [String: Any]) -> Bool {
            node["type"] as? String == "inlineProperty"
                || (node["content"] as? [[String: Any]] ?? []).contains(where: contains)
        }
        return contains(documentObject(from: json))
    }

    nonisolated static func removingCollection(_ collectionID: String, from json: String) throws -> String {
        func remove(_ node: [String: Any]) -> [String: Any]? {
            if node["type"] as? String == "collection",
               (node["attrs"] as? [String: Any])?["collectionID"] as? String == collectionID { return nil }
            var result = node
            if let children = node["content"] as? [[String: Any]] { result["content"] = children.compactMap(remove) }
            return result
        }
        return try makeDocumentJSON(content: (documentObject(from: json)["content"] as? [[String: Any]] ?? []).compactMap(remove))
    }

    nonisolated static func hasCallouts(in json: String) -> Bool {
        func contains(_ node: [String: Any]) -> Bool {
            ["callout", "plainCallout"].contains(node["type"] as? String ?? "")
                || (node["content"] as? [[String: Any]] ?? []).contains(where: contains)
        }
        return contains(documentObject(from: json))
    }

    nonisolated static func hasInlineTags(in json: String) -> Bool {
        func contains(_ node: [String: Any]) -> Bool {
            node["type"] as? String == "inlineTag"
                || (node["content"] as? [[String: Any]] ?? []).contains(where: contains)
        }
        return contains(documentObject(from: json))
    }

    nonisolated static func hasToggles(in json: String) -> Bool {
        func contains(_ node: [String: Any]) -> Bool {
            node["type"] as? String == "toggleItem"
                || (node["content"] as? [[String: Any]] ?? []).contains(where: contains)
        }
        return contains(documentObject(from: json))
    }

    nonisolated static func appendingPageReferences(to json: String, documentIDs: [String]) throws -> String {
        var content = documentObject(from: json)["content"] as? [Any] ?? []
        let existing = pageReferenceIDs(in: json)
        for id in documentIDs where !existing.contains(id) {
            content.append(["type": "pageReference", "attrs": ["id": UUID().uuidString, "documentID": id]])
        }
        return try makeDocumentJSON(content: content)
    }

    nonisolated static func remappingPageReferences(in json: String, documentIDs: [String: String]) throws -> String {
        func remap(_ node: [String: Any]) -> [String: Any] {
            var result = node
            if ["pageReference", "collection"].contains(node["type"] as? String ?? ""), var attrs = node["attrs"] as? [String: Any],
               let old = attrs["documentID"] as? String, let new = documentIDs[old] {
                attrs["documentID"] = new
                result["attrs"] = attrs
            }
            if let children = node["content"] as? [[String: Any]] { result["content"] = children.map(remap) }
            return result
        }
        let content = documentObject(from: json)["content"] as? [[String: Any]] ?? []
        return try makeDocumentJSON(content: content.map(remap))
    }

    private nonisolated static func analyzeJSONObject(_ object: Any) throws -> TipTapAnalysis {
        let normalized = normalizeDocumentObject(object)
        guard JSONSerialization.isValidJSONObject(normalized) else {
            throw VellixError.invalidEditorJSON("The payload was not a valid JSON object.")
        }

        let content = normalized["content"] as? [Any] ?? []
        var fragments: [String] = []
        var headings: [String] = []
        collectText(fromNodes: content, fragments: &fragments, headings: &headings)

        let plainText = fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let compactText = plainText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let preview = compactText.isEmpty
            ? "No content yet"
            : String(compactText.prefix(180))

        let words = compactText
            .split { $0.isWhitespace || $0.isNewline }
            .count

        let characters = plainText.count
        let readingMinutes = words == 0 ? 0 : max(1, Int(ceil(Double(words) / 225.0)))

        return TipTapAnalysis(
            canonicalJSON: try canonicalJSONString(from: normalized),
            plainText: plainText,
            previewText: preview,
            headings: headings,
            wordCount: words,
            characterCount: characters,
            estimatedReadingMinutes: readingMinutes,
            isEffectivelyEmpty: compactText.isEmpty
        )
    }

    private nonisolated static func normalizeDocumentObject(_ object: Any) -> [String: Any] {
        if let dictionary = object as? [String: Any] {
            if let document = dictionary["document"] {
                return normalizeDocumentObject(document)
            }

            if dictionary["type"] as? String == "doc" {
                var document: [String: Any] = [
                    "type": "doc",
                    "content": normalizeTipTapNodes(dictionary["content"] as? [Any] ?? [])
                ]
                if let projection = (dictionary["attrs"] as? [String: Any])?["taskHistoryProjection"] as? [String: Any] {
                    document["attrs"] = ["taskHistoryProjection": projection]
                }
                return document
            }

            if let content = dictionary["content"] as? [Any], dictionary["blocks"] == nil {
                return [
                    "type": "doc",
                    "content": normalizeTipTapNodes(content)
                ]
            }

            if let blocks = dictionary["blocks"] as? [Any] {
                return [
                    "type": "doc",
                    "content": blocks.map(importLegacyBlock)
                ]
            }

            if dictionary["type"] != nil {
                return [
                    "type": "doc",
                    "content": normalizeTipTapNodes([dictionary])
                ]
            }
        }

        if let blocks = object as? [Any] {
            return [
                "type": "doc",
                "content": blocks.map(importLegacyBlock)
            ]
        }

        return [
            "type": "doc",
            "content": [emptyParagraph()]
        ]
    }

    nonisolated static func orderedPageReferenceIDs(in json: String) -> [String] {
        var result: [String] = []
        func walk(_ node: [String: Any]) {
            if node["type"] as? String == "pageReference", let id = (node["attrs"] as? [String: Any])?["documentID"] as? String {
                result.append(id)
            }
            for child in node["content"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(documentObject(from: json))
        return result
    }

    private nonisolated static func normalizeTipTapNodes(_ nodes: [Any]) -> [[String: Any]] {
        var seen: Set<String> = []
        func uniqueIDs(_ node: [String: Any]) -> [String: Any] {
            var copy = node
            if var attrs = copy["attrs"] as? [String: Any], let id = attrs["id"] as? String {
                if !seen.insert(id).inserted { attrs["id"] = UUID().uuidString }
                copy["attrs"] = attrs
            }
            if let children = copy["content"] as? [[String: Any]] { copy["content"] = children.map(uniqueIDs) }
            return copy
        }
        let normalized = unwrapRetiredColumns(nodes).map(normalizeTipTapNode).map(uniqueIDs)
        return normalized.isEmpty ? [emptyParagraph()] : normalized
    }

    private nonisolated static func unwrapRetiredColumns(_ nodes: [Any]) -> [Any] {
        nodes.flatMap { node -> [Any] in
            guard var dictionary = node as? [String: Any] else { return [node] }
            if ["columns", "column"].contains(dictionary["type"] as? String ?? "") {
                return unwrapRetiredColumns(dictionary["content"] as? [Any] ?? [])
            }
            if let content = dictionary["content"] as? [Any] {
                let unwrapped = unwrapRetiredColumns(content)
                dictionary["content"] = unwrapped
            }
            return [dictionary]
        }
    }

    private nonisolated static func normalizeTipTapNode(_ node: Any) -> [String: Any] {
        guard var dictionary = node as? [String: Any] else {
            return emptyParagraph()
        }

        let type = dictionary["type"] as? String ?? "paragraph"
        dictionary["type"] = type

        if type == "text" {
            dictionary["text"] = dictionary["text"] as? String ?? ""
            dictionary.removeValue(forKey: "attrs")
            dictionary.removeValue(forKey: "content")
            return dictionary
        }

        var attrs = dictionary["attrs"] as? [String: Any] ?? [:]
        attrs["id"] = trimmedString(attrs["id"]) ?? UUID().uuidString

        if type == "callout" {
            attrs["icon"] = trimmedString(attrs["icon"]) ?? "sparkle"
            attrs["color"] = trimmedString(attrs["color"]) ?? "#ffffff"
        }

        if type == "plainCallout" {
            attrs.removeValue(forKey: "icon")
            attrs["color"] = trimmedString(attrs["color"]) ?? "#ffffff"
        }

        if type == "divider" {
            attrs["style"] = normalizedDividerStyle(attrs["style"])
        }

        if type == "taskItem" {
            let crossed = attrs["crossed"] as? Bool ?? false
            attrs["checked"] = crossed ? false : (attrs["checked"] as? Bool ?? false)
            attrs["crossed"] = crossed
        }

        if attrs["placeholderProjection"] as? Bool == true {
            attrs["placeholderGuidance"] = dictionary["content"] as? [Any] ?? []
            attrs["placeholderEnabled"] = true
            attrs.removeValue(forKey: "placeholderProjection")
            dictionary["content"] = []
        }
        attrs.removeValue(forKey: "placeholderProjection")
        dictionary["attrs"] = attrs

        if let content = dictionary["content"] as? [Any] {
            let normalizedContent = content.map(normalizeTipTapNode)
            dictionary["content"] = ["callout", "plainCallout"].contains(type)
                ? normalizeCalloutContent(normalizedContent)
                : normalizedContent
        }

        return dictionary
    }

    private nonisolated static func normalizeCalloutContent(_ nodes: [[String: Any]]) -> [[String: Any]] {
        let hasBlockContent = nodes.contains { node in
            let type = node["type"] as? String
            return type != "text" && type != "hardBreak"
        }

        if hasBlockContent {
            return nodes.isEmpty ? [paragraph(content: [])] : nodes
        }

        return [paragraph(content: nodes)]
    }

    private nonisolated static func importLegacyBlock(_ block: Any) -> [String: Any] {
        guard let dictionary = block as? [String: Any] else {
            return emptyParagraph()
        }

        let blockID = trimmedString(dictionary["id"]) ?? UUID().uuidString
        let props = dictionary["props"] as? [String: Any] ?? [:]
        let inline = legacyInlineContent(dictionary["content"])

        switch dictionary["type"] as? String {
        case "heading":
            return [
                "type": "heading",
                "attrs": [
                    "id": blockID,
                    "level": props["level"] as? Int ?? 1
                ],
                "content": [paragraph(content: inline)]
            ]
        case "bulletListItem":
            return [
                "type": "bulletList",
                "attrs": ["id": blockID],
                "content": [[
                    "type": "listItem",
                    "attrs": ["id": UUID().uuidString],
                    "content": [paragraph(content: inline)]
                ]]
            ]
        case "numberedListItem":
            return [
                "type": "orderedList",
                "attrs": ["id": blockID],
                "content": [[
                    "type": "listItem",
                    "attrs": ["id": UUID().uuidString],
                    "content": [paragraph(content: inline)]
                ]]
            ]
        case "checkListItem":
            let crossed = props["crossed"] as? Bool ?? false
            return [
                "type": "taskList",
                "attrs": ["id": blockID],
                "content": [[
                    "type": "taskItem",
                    "attrs": [
                        "id": UUID().uuidString,
                        "checked": crossed ? false : (props["checked"] as? Bool ?? false),
                        "crossed": crossed
                    ],
                    "content": [paragraph(content: inline)]
                ]]
            ]
        case "quote":
            return [
                "type": "blockquote",
                "attrs": ["id": blockID],
                "content": [paragraph(content: inline)]
            ]
        case "callout":
            return [
                "type": "callout",
                "attrs": [
                    "id": blockID,
                    "icon": trimmedString(props["icon"]) ?? "sparkle",
                    "color": trimmedString(props["color"]) ?? "#ffffff"
                ],
                "content": [paragraph(content: inline)]
            ]
        case "plainCallout":
            return [
                "type": "plainCallout",
                "attrs": ["id": blockID, "color": trimmedString(props["color"]) ?? "#ffffff"],
                "content": [paragraph(content: inline)]
            ]
        case "divider":
            return [
                "type": "divider",
                "attrs": [
                    "id": blockID,
                    "style": normalizedDividerStyle(props["style"])
                ]
            ]
        case "pageBreak":
            return [
                "type": "pageBreak",
                "attrs": ["id": blockID]
            ]
        case "toggleListItem":
            return [
                "type": "toggleItem",
                "attrs": [
                    "id": blockID,
                    "open": true
                ],
                "content": [paragraph(content: inline)]
            ]
        default:
            return paragraph(id: blockID, content: inline)
        }
    }

    private nonisolated static func legacyInlineContent(_ content: Any?) -> [[String: Any]] {
        if let text = content as? String {
            return text.isEmpty ? [] : [["type": "text", "text": text]]
        }

        guard let items = content as? [Any] else {
            return []
        }

        return items.compactMap { item in
            guard let dictionary = item as? [String: Any] else {
                return nil
            }

            let text = dictionary["text"] as? String ?? dictionary["content"] as? String ?? ""
            return [
                "type": "text",
                "text": text
            ]
        }
    }

    private nonisolated static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func normalizedDividerStyle(_ value: Any?) -> String {
        switch trimmedString(value) {
        case "dottedCircles", "tinyDots":
            return "dottedCircles"
        case "fourCircles", "fourDots":
            return "fourCircles"
        case "thickLine":
            return "thickLine"
        case "thinLine":
            return "thinLine"
        default:
            return "thinLine"
        }
    }

    private nonisolated static func emptyParagraph() -> [String: Any] {
        paragraph(content: [])
    }

    private nonisolated static func paragraph(id: String = UUID().uuidString, content: [[String: Any]]) -> [String: Any] {
        var node: [String: Any] = [
            "type": "paragraph",
            "attrs": ["id": id]
        ]

        if !content.isEmpty {
            node["content"] = content
        }

        return node
    }

    private nonisolated static func canonicalJSONString(from object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw VellixError.invalidEditorJSON("The payload was not serializable JSON.")
        }

        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        guard let string = String(data: data, encoding: .utf8) else {
            throw VellixError.invalidEditorJSON("The payload could not be encoded as UTF-8.")
        }

        return string
    }

    private nonisolated static func collectText(
        fromNodes nodes: [Any],
        fragments: inout [String],
        headings: inout [String]
    ) {
        for node in nodes {
            guard let dictionary = node as? [String: Any] else {
                continue
            }

            let nodeType = dictionary["type"] as? String
            let text = textContent(from: dictionary)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty, isTextBearingBlock(nodeType) {
                fragments.append(text)
                if nodeType == "heading" {
                    headings.append(text)
                }
            }

            if let content = dictionary["content"] as? [Any] {
                collectText(fromNodes: content, fragments: &fragments, headings: &headings)
            }
        }
    }

    private nonisolated static func isTextBearingBlock(_ type: String?) -> Bool {
        switch type {
        case "paragraph", "caption", "heading", "blockquote", "callout", "plainCallout", "listItem", "taskItem", "toggleItem", "inlineProperty", "templateComponent", "attachment":
            return true
        default:
            return false
        }
    }

    private nonisolated static func textContent(from node: Any?) -> String {
        if let string = node as? String {
            return string
        }

        if let array = node as? [Any] {
            return array.map(textContent(from:)).filter { !$0.isEmpty }.joined(separator: " ")
        }

        if let dictionary = node as? [String: Any] {
            if dictionary["type"] as? String == "inlineTag",
               let name = (dictionary["attrs"] as? [String: Any])?["name"] as? String {
                return "#" + name
            }
            if dictionary["type"] as? String == "attachment",
               let attrs = dictionary["attrs"] as? [String: Any], let file = attrs["file"] as? [String: Any] {
                return file["name"] as? String ?? ""
            }
            if dictionary["type"] as? String == "templateComponent",
               let attrs = dictionary["attrs"] as? [String: Any],
               let definition = TemplateComponentDefinition.decode(attrs["definition"]) {
                let selected: [String]
                if let ids = attrs["response"] as? [String] { selected = definition.choices.filter { ids.contains($0.id) }.map(\.label) }
                else if let id = attrs["response"] as? String { selected = definition.choices.filter { $0.id == id }.map(\.label) }
                else if let value = attrs["response"] as? NSNumber { selected = [value.stringValue] }
                else { selected = [] }
                return ([definition.label] + selected).filter { !$0.isEmpty }.joined(separator: " ")
            }
            if dictionary["type"] as? String == "inlineProperty",
               let attrs = dictionary["attrs"] as? [String: Any],
               let property = InlinePropertyDefinition.decode(attrs["property"]) {
                return property.searchableText
            }
            if dictionary["type"] as? String == "text" {
                return dictionary["text"] as? String ?? ""
            }

            return textContent(from: dictionary["content"])
        }

        return ""
    }

}
