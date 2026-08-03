//
//  EditorBridgeTypes.swift
//  Vellix
//

import Foundation
import CoreGraphics

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(_ value: Any?) {
        switch value {
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues { JSONValue($0) })
        case let array as [Any]:
            self = .array(array.map { JSONValue($0) })
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let bool as Bool:
            self = .bool(bool)
        case .none:
            self = .null
        default:
            self = .string(String(describing: value ?? ""))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }

        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }

        return nil
    }

    var bridgeObject: Any {
        switch self {
        case .object(let dictionary):
            return dictionary.mapValues(\.bridgeObject)
        case .array(let array):
            return array.map(\.bridgeObject)
        case .string(let string):
            return string
        case .number(let number):
            return number
        case .bool(let bool):
            return bool
        case .null:
            return NSNull()
        }
    }
}

struct EditorBridgeEnvelope: Codable, Equatable, Sendable {
    var version: Int
    var id: String
    var type: String
    var payload: JSONValue

    init(
        version: Int = 1,
        id: String = UUID().uuidString,
        type: String,
        payload: JSONValue = .object([:])
    ) {
        self.version = version
        self.id = id
        self.type = type
        self.payload = payload
    }
}

enum EditorEvent: Equatable {
    case editorReady(blockCount: Int)
    case documentChanged(String)
    case documentSnapshot(String)
    case editorError(String)
    case focusChanged(Bool)
    case statisticsChanged(wordCount: Int, characterCount: Int)
    case contentHeightChanged(CGFloat)
    case blockSelectionChanged(Int)
    case requestCalloutIconPicker(blockID: String, icon: String)
    case selectedBlocksForSubpage(title: String, canonicalJSON: String)
    case requestHaptic(style: String)
    case unknown(String)

    init(envelope: EditorBridgeEnvelope) throws {
        switch envelope.type {
        case "editorReady":
            let blockCount = envelope.payload.objectValue?["blockCount"]?.numberIntValue ?? 0
            self = .editorReady(blockCount: blockCount)

        case "documentChanged":
            self = .documentChanged(try Self.documentJSON(from: envelope.payload))

        case "documentSnapshot":
            self = .documentSnapshot(try Self.documentJSON(from: envelope.payload))

        case "editorError":
            let message = envelope.payload.objectValue?["message"]?.stringValue ?? "The editor reported an unknown error."
            self = .editorError(message)

        case "editorFocusChanged":
            let focused = envelope.payload.objectValue?["focused"]?.boolValue ?? false
            self = .focusChanged(focused)

        case "documentStatisticsChanged":
            let words = envelope.payload.objectValue?["wordCount"]?.numberIntValue ?? 0
            let characters = envelope.payload.objectValue?["characterCount"]?.numberIntValue ?? 0
            self = .statisticsChanged(wordCount: words, characterCount: characters)

        case "contentHeightChanged":
            let height = envelope.payload.objectValue?["height"]?.numberValue ?? 0
            self = .contentHeightChanged(CGFloat(height))

        case "blockSelectionChanged":
            let count = envelope.payload.objectValue?["count"]?.numberIntValue ?? 0
            self = .blockSelectionChanged(count)

        case "requestCalloutIconPicker":
            let blockID = envelope.payload.objectValue?["blockId"]?.stringValue ?? ""
            let icon = envelope.payload.objectValue?["icon"]?.stringValue ?? "sparkle"
            self = .requestCalloutIconPicker(blockID: blockID, icon: icon)

        case "selectedBlocksForSubpage":
            let title = envelope.payload.objectValue?["title"]?.stringValue ?? "New Sub Page"
            self = .selectedBlocksForSubpage(
                title: title,
                canonicalJSON: try Self.documentJSON(from: envelope.payload)
            )

        case "requestHaptic":
            let style = envelope.payload.objectValue?["style"]?.stringValue ?? "light"
            self = .requestHaptic(style: style)

        default:
            self = .unknown(envelope.type)
        }
    }

    private static func documentJSON(from payload: JSONValue) throws -> String {
        try BlockNoteContentAnalyzer.normalizePayloadToJSON(payload.bridgeObject)
    }
}

extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }

        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }

        return nil
    }

    var numberIntValue: Int? {
        if case .number(let value) = self {
            return Int(value)
        }

        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self {
            return value
        }

        return nil
    }
}

enum EditorSaveState: Equatable {
    case idle
    case unsaved
    case saving
    case saved(Date)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .unsaved:
            return "Unsaved"
        case .saving:
            return "Saving"
        case .saved:
            return "Saved"
        case .failed:
            return "Save failed"
        }
    }
}

enum EditorCommand {
    static func loadDocument(canonicalJSON: String) -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(
            type: "loadDocument",
            payload: .object([
                "blocks": BlockNoteContentAnalyzer.blocksJSONValue(from: canonicalJSON)
            ])
        )
    }

    static func requestSnapshot() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "requestSnapshot")
    }

    static func focusEditor() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "focusEditor")
    }

    static func setEditable(_ editable: Bool) -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(
            type: "setEditable",
            payload: .object(["editable": .bool(editable)])
        )
    }

    static func setTheme(_ theme: String) -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(
            type: "setTheme",
            payload: .object(["theme": .string(theme)])
        )
    }

    static func setAppearance(_ appearance: DocumentAppearance) -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(
            type: "setAppearance",
            payload: .object([
                "textColor": .string(appearance.textColorHex),
                "fontFamily": .string(appearance.fontStyle.cssFamily),
                "pageBackground": .string("transparent")
            ])
        )
    }

    static func insertDivider(_ style: VellixDividerStyle) -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(
            type: "insertDivider",
            payload: .object([
                "style": .string(style.rawValue)
            ])
        )
    }

    static func insertPageBreak() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "insertPageBreak")
    }

    static func insertCallout(icon: String, text: String, color: String = "#ffffff") -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(
            type: "insertCallout",
            payload: .object([
                "icon": .string(icon),
                "text": .string(text),
                "color": .string(color)
            ])
        )
    }

    static func setSelectedBlockType(_ blockType: String, level: Int? = nil, color: String? = nil) -> EditorBridgeEnvelope {
        var payload: [String: JSONValue] = [
            "blockType": .string(blockType)
        ]

        if let level {
            payload["level"] = .number(Double(level))
        }

        if let color {
            payload["color"] = .string(color)
        }

        return EditorBridgeEnvelope(type: "setSelectedBlockType", payload: .object(payload))
    }

    static func indentSelectedBlocks() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "indentSelectedBlocks")
    }

    static func outdentSelectedBlocks() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "outdentSelectedBlocks")
    }

    static func setSelectedCalloutColor(_ color: String) -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(
            type: "setSelectedCalloutColor",
            payload: .object(["color": .string(color)])
        )
    }

    static func updateCalloutIcon(blockID: String?, icon: String) -> EditorBridgeEnvelope {
        var payload: [String: JSONValue] = [
            "icon": .string(icon)
        ]

        if let blockID {
            payload["blockId"] = .string(blockID)
        }

        return EditorBridgeEnvelope(type: "updateCalloutIcon", payload: .object(payload))
    }

    static func deleteSelectedBlocks() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "deleteSelectedBlocks")
    }

    static func copySelectedBlocks() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "copySelectedBlocks")
    }

    static func cutSelectedBlocks() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "cutSelectedBlocks")
    }

    static func duplicateSelectedBlocks() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "duplicateSelectedBlocks")
    }

    static func requestSelectedBlocksForSubpage() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "requestSelectedBlocksForSubpage")
    }

    static func selectAllBlocks() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "selectAllBlocks")
    }

    static func clearBlockSelection() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "clearBlockSelection")
    }

    static func undo() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "undo")
    }

    static func redo() -> EditorBridgeEnvelope {
        EditorBridgeEnvelope(type: "redo")
    }
}
