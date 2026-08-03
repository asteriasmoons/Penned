//
//  BlockNoteContentAnalyzer.swift
//  Vellix
//

import Foundation

struct BlockNoteAnalysis: Equatable {
    var canonicalJSON: String
    var plainText: String
    var previewText: String
    var headings: [String]
    var wordCount: Int
    var characterCount: Int
    var estimatedReadingMinutes: Int
    var isEffectivelyEmpty: Bool
}

struct InstantPreviewBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading
        case bullet
        case numbered
        case checklist
        case quote
        case callout
        case divider
        case pageBreak
    }

    var id: String
    var kind: Kind
    var text: String
    var level: Int
    var checked: Bool
}

enum BlockNoteContentAnalyzer {
    static let emptyDocumentJSON = #"{"blocks":[]}"#

    static func analyze(_ jsonString: String) throws -> BlockNoteAnalysis {
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

    static func analyzePayload(_ payload: Any?) throws -> BlockNoteAnalysis {
        guard let payload else {
            throw VellixError.invalidEditorJSON("The editor payload was empty.")
        }

        return try analyzeJSONObject(payload)
    }

    static func normalizePayloadToJSON(_ payload: Any?) throws -> String {
        try analyzePayload(payload).canonicalJSON
    }

    static func blocksJSONValue(from canonicalJSON: String) -> JSONValue {
        guard
            let data = canonicalJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let blocks = dictionary["blocks"]
        else {
            return .array([])
        }

        return JSONValue(blocks)
    }

    static func instantPreviewBlocks(from canonicalJSON: String) -> [InstantPreviewBlock] {
        guard
            let data = canonicalJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }

        let normalized = normalizeDocumentObject(object)
        let blocks = normalized["blocks"] as? [Any] ?? []
        return flattenPreviewBlocks(blocks)
    }

    static func makeDocumentJSON(blocks: [Any]) throws -> String {
        try canonicalJSONString(from: ["blocks": blocks])
    }

    static func starterDocument(title: String, lines: [String] = []) -> String {
        let blocks = lines.map { line in
            [
                "id": UUID().uuidString,
                "type": "paragraph",
                "props": [
                    "textColor": "default",
                    "backgroundColor": "default",
                    "textAlignment": "left"
                ],
                "content": [
                    [
                        "type": "text",
                        "text": line,
                        "styles": [:]
                    ]
                ],
                "children": []
            ] as [String: Any]
        }

        if let json = try? makeDocumentJSON(blocks: blocks) {
            return json
        }

        return emptyDocumentJSON
    }

    private static func analyzeJSONObject(_ object: Any) throws -> BlockNoteAnalysis {
        let normalized = normalizeDocumentObject(object)
        guard JSONSerialization.isValidJSONObject(normalized) else {
            throw VellixError.invalidEditorJSON("The payload was not a valid JSON object.")
        }

        let blocks = normalized["blocks"] as? [Any] ?? []
        var fragments: [String] = []
        var headings: [String] = []
        collectText(fromBlocks: blocks, fragments: &fragments, headings: &headings)

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

        return BlockNoteAnalysis(
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

    private static func normalizeDocumentObject(_ object: Any) -> [String: Any] {
        let rawBlocks: [Any]

        if let dictionary = object as? [String: Any] {
            if let blocks = dictionary["blocks"] as? [Any] {
                rawBlocks = blocks
                return ["blocks": normalizeBlocks(rawBlocks)]
            }

            if dictionary["type"] != nil {
                rawBlocks = [dictionary]
                return ["blocks": normalizeBlocks(rawBlocks)]
            }
        }

        if let blocks = object as? [Any] {
            rawBlocks = blocks
            return ["blocks": normalizeBlocks(rawBlocks)]
        }

        return ["blocks": []]
    }

    private static func normalizeBlocks(_ blocks: [Any]) -> [[String: Any]] {
        blocks.map { block in
            normalizeBlock(block)
        }
    }

    private static func normalizeBlock(_ block: Any) -> [String: Any] {
        guard var dictionary = block as? [String: Any] else {
            return [
                "id": UUID().uuidString,
                "type": "paragraph",
                "props": [:],
                "content": [],
                "children": []
            ]
        }

        let type = dictionary["type"] as? String ?? "paragraph"
        var props = dictionary["props"] as? [String: Any] ?? [:]
        let children = normalizeBlocks(dictionary["children"] as? [Any] ?? [])

        dictionary["type"] = type
        dictionary["props"] = props
        dictionary["children"] = children

        if type == "callout" {
            props["icon"] = (props["icon"] as? String)?.trimmedNonEmpty ?? "sparkle"
            props["color"] = (props["color"] as? String)?.trimmedNonEmpty ?? "#ffffff"
            dictionary["props"] = props
            dictionary["content"] = normalizeInlineContent(dictionary["content"])
        }

        return dictionary
    }

    private static func normalizeInlineContent(_ content: Any?) -> [[String: Any]] {
        if let text = content as? String {
            guard !text.isEmpty else {
                return []
            }
            return [[
                "type": "text",
                "text": text,
                "styles": [:]
            ]]
        }

        guard let items = content as? [Any] else {
            return []
        }

        return items.compactMap { item in
            guard var dictionary = item as? [String: Any] else {
                return nil
            }

            if dictionary["type"] as? String == "text" {
                dictionary["text"] = dictionary["text"] as? String ?? ""
                dictionary["styles"] = dictionary["styles"] as? [String: Any] ?? [:]
            }

            return dictionary
        }
    }

    private static func canonicalJSONString(from object: Any) throws -> String {
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

    private static func collectText(
        fromBlocks blocks: [Any],
        fragments: inout [String],
        headings: inout [String]
    ) {
        for block in blocks {
            guard let dictionary = block as? [String: Any] else {
                continue
            }

            let blockType = dictionary["type"] as? String
            let text = textContent(from: dictionary["content"])
            if !text.isEmpty {
                fragments.append(text)
                if blockType == "heading" {
                    headings.append(text)
                }
            }

            if let children = dictionary["children"] as? [Any] {
                collectText(fromBlocks: children, fragments: &fragments, headings: &headings)
            }
        }
    }

    private static func textContent(from content: Any?) -> String {
        if let string = content as? String {
            return string
        }

        if let array = content as? [Any] {
            return array.map { item -> String in
                if let dictionary = item as? [String: Any] {
                    let text = dictionary["text"] as? String ?? dictionary["content"] as? String ?? ""
                    let children = textContent(from: dictionary["children"])
                    return [text, children].filter { !$0.isEmpty }.joined(separator: " ")
                }

                return String(describing: item)
            }
            .joined(separator: " ")
        }

        if let dictionary = content as? [String: Any] {
            return dictionary.values.map { textContent(from: $0) }.joined(separator: " ")
        }

        return ""
    }

    private static func flattenPreviewBlocks(_ blocks: [Any]) -> [InstantPreviewBlock] {
        var preview: [InstantPreviewBlock] = []

        for (index, block) in blocks.enumerated() {
            guard let dictionary = block as? [String: Any] else {
                continue
            }

            if let item = previewBlock(from: dictionary, fallbackIndex: index) {
                preview.append(item)
            }

            if let children = dictionary["children"] as? [Any] {
                preview.append(contentsOf: flattenPreviewBlocks(children))
            }
        }

        return preview
    }

    private static func previewBlock(
        from dictionary: [String: Any],
        fallbackIndex: Int
    ) -> InstantPreviewBlock? {
        let type = dictionary["type"] as? String ?? "paragraph"
        let props = dictionary["props"] as? [String: Any] ?? [:]
        let text = textContent(from: dictionary["content"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch type {
        case "heading":
            return InstantPreviewBlock(
                id: dictionary["id"] as? String ?? "heading-\(fallbackIndex)",
                kind: .heading,
                text: text,
                level: props["level"] as? Int ?? 1,
                checked: false
            )
        case "bulletListItem":
            return InstantPreviewBlock(
                id: dictionary["id"] as? String ?? "bullet-\(fallbackIndex)",
                kind: .bullet,
                text: text,
                level: 1,
                checked: false
            )
        case "numberedListItem":
            return InstantPreviewBlock(
                id: dictionary["id"] as? String ?? "numbered-\(fallbackIndex)",
                kind: .numbered,
                text: text,
                level: props["level"] as? Int ?? 1,
                checked: false
            )
        case "checkListItem":
            return InstantPreviewBlock(
                id: dictionary["id"] as? String ?? "checklist-\(fallbackIndex)",
                kind: .checklist,
                text: text,
                level: 1,
                checked: props["checked"] as? Bool ?? false
            )
        case "quote":
            return InstantPreviewBlock(
                id: dictionary["id"] as? String ?? "quote-\(fallbackIndex)",
                kind: .quote,
                text: text,
                level: 1,
                checked: false
            )
        case "callout":
            return InstantPreviewBlock(
                id: dictionary["id"] as? String ?? "callout-\(fallbackIndex)",
                kind: .callout,
                text: text,
                level: 1,
                checked: false
            )
        case "divider":
            return InstantPreviewBlock(
                id: dictionary["id"] as? String ?? "divider-\(fallbackIndex)",
                kind: .divider,
                text: "",
                level: 1,
                checked: false
            )
        case "pageBreak":
            return InstantPreviewBlock(
                id: dictionary["id"] as? String ?? "page-break-\(fallbackIndex)",
                kind: .pageBreak,
                text: "",
                level: 1,
                checked: false
            )
        default:
            guard !text.isEmpty else {
                return nil
            }
            return InstantPreviewBlock(
                id: dictionary["id"] as? String ?? "paragraph-\(fallbackIndex)",
                kind: .paragraph,
                text: text,
                level: 1,
                checked: false
            )
        }
    }
}
