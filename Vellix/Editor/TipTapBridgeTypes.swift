//
//  TipTapBridgeTypes.swift
//  Vellix
//

import Foundation
import CoreGraphics
import SwiftUI

enum TipTapEditorEvent: Equatable {
    case tagRequest(InlineTagRequest)
    case requestCollection(CollectionEditorRequest)
    case requestTemplateComponent(TemplateComponentRequest)
    case requestAttachment(AttachmentEditorRequest)
    case requestAttachmentActions(AttachmentEditorRequest)
    case importAttachments(token: String, files: [AttachmentImportData])
    case attachmentClipboard(token: String, html: String, text: String)
    case editorReady(blockCount: Int)
    case documentChanged(String)
    case documentSnapshot(String)
    case editorError(String)
    case focusChanged(Bool)
    case formattingStateChanged(TipTapFormattingState)
    case textConversionStateChanged(TipTapTextConversionState)
    case statisticsChanged(wordCount: Int, characterCount: Int)
    case contentHeightChanged(height: CGFloat, visualContentBottom: CGFloat)
    case caretChanged(TipTapCaretUpdate)
    case pageBreakRegionsChanged([TipTapPageBreakRegion])
    case collectionRegionsChanged([TipTapCollectionRegion])
    case blockSelectionChanged(Int)
    case selectionModeChanged(String)
    case requestCalloutIconPicker(blockID: String, icon: String, color: String)
    case requestCalloutColorPicker(blockID: String, color: String)
    case requestBlockquoteColorPicker(blockID: String, color: String)
    case requestInlinePropertyEditor(blockID: String, property: InlinePropertyDefinition)
    case requestPropertyURL(String)
    case requestNestedPage(blockID: String)
    case requestPageCard(blockID: String)
    case requestOpenPage(documentID: String)
    case requestPageActions(documentID: String)
    case requestBlockDeletion(token: String)
    case slashMenuChanged(TipTapSlashMenuState?)
    case selectedBlocksForSubpage(title: String, canonicalJSON: String)
    case requestHaptic(style: String)
    case requestPlaceholderConversion(token: String)
    case requestTableCreation
    case requestTableMenu(TipTapTableContext)
    case tableStateChanged(TipTapTableContext?)
    case tableFormulaPreview(String)
    case tableClipboard(text: String, cut: Bool)
    case tableDocumentSnapshot(String)
    case taskStateChanged(DocumentTaskContext?)
    case requestTaskMenu(DocumentTaskContext)
    case requestTaskCompletion(DocumentTaskContext, completed: Bool, skipped: Bool)
    case taskDocumentSnapshot(String)
    case unknown(String)

    init(kind: String, payload: [String: Any]) throws {
        switch kind {
        case "textConversionState":
            self = .textConversionStateChanged(TipTapTextConversionState.decode(payload))
        case "tagRequest":
            self = InlineTagRequest.decode(payload).map(Self.tagRequest) ?? .unknown(kind)
        case "attachmentClipboard":
            guard let token = payload["token"] as? String, let html = payload["html"] as? String,
                  html.utf8.count <= 4 * 1024 * 1024 else { self = .editorError("The selected blocks are too large to copy together."); return }
            self = .attachmentClipboard(token: token, html: html, text: payload["text"] as? String ?? "")
        case "attachmentMenu", "attachmentActions":
            guard let id = payload["blockID"] as? String, !id.isEmpty,
                  let path = payload["relativePath"] as? String else { self = .unknown(kind); return }
            let request = AttachmentEditorRequest(blockID: id, relativePath: path,
                mode: payload["mode"] as? String ?? "card", width: payload["width"] as? Double,
                alignment: payload["alignment"] as? String ?? "left")
            self = kind == "attachmentActions" ? .requestAttachmentActions(request) : .requestAttachment(request)
        case "attachmentImport":
            guard let token = payload["token"] as? String, let raw = payload["files"] as? [[String: Any]], raw.count <= 20 else {
                self = .editorError("The pasted files could not be imported."); return
            }
            var files: [AttachmentImportData] = []
            var total = 0
            for file in raw {
                guard let text = file["base64"] as? String, text.count <= 45 * 1024 * 1024,
                      let data = Data(base64Encoded: text), data.count <= 32 * 1024 * 1024 else {
                    self = .editorError("Use Add > File to import this file."); return
                }
                total += data.count
                guard total <= 64 * 1024 * 1024 else { self = .editorError("Import these files separately using Add > File."); return }
                files.append(AttachmentImportData(name: file["name"] as? String ?? "Attachment", mimeType: file["mimeType"] as? String, data: data))
            }
            self = .importAttachments(token: token, files: files)
        case "templateComponentConfigure":
            guard let id = payload["blockID"] as? String, !id.isEmpty,
                  let definition = TemplateComponentDefinition.decode(payload["definition"]) else {
                self = .editorError("The component configuration could not be read."); return
            }
            self = .requestTemplateComponent(TemplateComponentRequest(blockID: id, definition: definition))
        case "collectionRequest":
            guard let action = payload["action"] as? String else { self = .unknown(kind); return }
            self = .requestCollection(CollectionEditorRequest(action: action,
                blockID: payload["blockID"] as? String ?? "", collectionID: payload["collectionID"] as? String ?? "",
                documentID: payload["documentID"] as? String ?? "", fieldID: payload["fieldID"] as? String ?? "",
                viewID: payload["viewID"] as? String ?? ""))
        case "taskState": self = .taskStateChanged(DocumentTaskContext.decode(payload))
        case "taskMenuRequest", "taskCompletionRequest":
            guard let context = DocumentTaskContext.decode(payload) else { self = .unknown(kind); return }
            self = kind == "taskMenuRequest" ? .requestTaskMenu(context)
                : .requestTaskCompletion(context, completed: payload["completed"] as? Bool ?? false,
                                         skipped: payload["skipped"] as? Bool ?? false)
        case "taskSnapshot": self = .taskDocumentSnapshot(try Self.documentJSON(from: payload))
        case "tableCreateRequest": self = .requestTableCreation
        case "tableMenuRequest":
            guard let context = TipTapTableContext.decode(payload) else {
                self = .editorError("The selected table cell could not be read.")
                return
            }
            self = .requestTableMenu(context)
        case "tableState": self = .tableStateChanged(TipTapTableContext.decode(payload))
        case "tableFormulaPreview": self = .tableFormulaPreview(payload["result"] as? String ?? "")
        case "tableClipboard": self = .tableClipboard(text: payload["text"] as? String ?? "", cut: payload["cut"] as? Bool ?? false)
        case "tableSnapshot": self = .tableDocumentSnapshot(try Self.documentJSON(from: payload))
        case "ready":
            let blockCount = payload["blockCount"] as? Int
                ?? (payload["blockCount"] as? NSNumber)?.intValue
                ?? 0
            self = .editorReady(blockCount: blockCount)

        case "update":
            self = .documentChanged(try Self.documentJSON(from: payload))

        case "snapshot":
            self = .documentSnapshot(try Self.documentJSON(from: payload))

        case "error":
            let message = payload["message"] as? String ?? "The editor reported an unknown error."
            self = .editorError(message)

        case "focus":
            let focused = payload["focused"] as? Bool ?? false
            self = .focusChanged(focused)

        case "formattingState":
            self = .formattingStateChanged(TipTapFormattingState.decode(payload))

        case "statistics":
            let words = payload["wordCount"] as? Int
                ?? (payload["wordCount"] as? NSNumber)?.intValue
                ?? 0
            let characters = payload["characterCount"] as? Int
                ?? (payload["characterCount"] as? NSNumber)?.intValue
                ?? 0
            self = .statisticsChanged(wordCount: words, characterCount: characters)

        case "height":
            let height = payload["height"] as? Double
                ?? (payload["height"] as? NSNumber)?.doubleValue
                ?? 0
            let visualContentBottom = payload["visualContentBottom"] as? Double
                ?? (payload["visualContentBottom"] as? NSNumber)?.doubleValue
                ?? height
            self = .contentHeightChanged(
                height: CGFloat(height),
                visualContentBottom: CGFloat(visualContentBottom)
            )

        case "caret":
            guard let update = TipTapCaretUpdate.decode(payload) else {
                self = .unknown(kind)
                return
            }
            self = .caretChanged(update)

        case "pageBreaks":
            self = .pageBreakRegionsChanged(Self.pageBreakRegions(from: payload))

        case "nativeCollections":
            let regions = (payload["regions"] as? [[String: Any]] ?? []).compactMap { raw -> TipTapCollectionRegion? in
                guard let blockID = raw["blockID"] as? String, !blockID.isEmpty,
                      let collectionID = raw["collectionID"] as? String, !collectionID.isEmpty,
                      let x = raw.cgFloatValue(for: "x"), let y = raw.cgFloatValue(for: "y"),
                      let width = raw.cgFloatValue(for: "width"), let height = raw.cgFloatValue(for: "height"),
                      x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
                return TipTapCollectionRegion(id: blockID, collectionID: collectionID, rect: CGRect(x: x, y: y, width: width, height: height))
            }
            self = .collectionRegionsChanged(regions)

        case "selection":
            let count = payload["count"] as? Int
                ?? (payload["count"] as? NSNumber)?.intValue
                ?? 0
            self = .blockSelectionChanged(count)

        case "selectionMode":
            let mode = payload["mode"] as? String ?? "off"
            self = .selectionModeChanged(mode)

        case "iconPickerRequest":
            let blockID = payload["blockId"] as? String ?? ""
            let icon = payload["currentIcon"] as? String ?? "sparkle"
            let color = payload["currentColor"] as? String ?? "#ffffff"
            self = .requestCalloutIconPicker(blockID: blockID, icon: icon, color: color)

        case "blockquoteColorPickerRequest":
            let blockID = payload["blockId"] as? String ?? ""
            let color = payload["currentColor"] as? String ?? "#ffffff"
            self = .requestBlockquoteColorPicker(blockID: blockID, color: color)

        case "calloutColorPickerRequest":
            let blockID = payload["blockId"] as? String ?? ""
            let color = payload["currentColor"] as? String ?? "#ffffff"
            self = .requestCalloutColorPicker(blockID: blockID, color: color)

        case "propertyEditorRequest":
            guard let blockID = payload["blockId"] as? String, !blockID.isEmpty,
                  let property = InlinePropertyDefinition.decode(payload["property"]) else {
                self = .editorError("The property configuration could not be read.")
                return
            }
            self = .requestInlinePropertyEditor(blockID: blockID, property: property)

        case "propertyURLRequest":
            guard let value = payload["url"] as? String,
                  let url = InlinePropertyDefinition.safeURL(value) else {
                self = .unknown(kind)
                return
            }
            self = .requestPropertyURL(url.absoluteString)

        case "slashMenu":
            let visible = payload["visible"] as? Bool ?? false
            self = .slashMenuChanged(visible ? Self.slashMenuState(from: payload) : nil)

        case "nestedPageRequest":
            self = .requestNestedPage(blockID: payload["blockId"] as? String ?? "")

        case "pageCardRequest":
            self = .requestPageCard(blockID: payload["blockId"] as? String ?? "")

        case "pageOpenRequest":
            self = .requestOpenPage(documentID: payload["documentId"] as? String ?? "")

        case "pageActionsRequest":
            self = .requestPageActions(documentID: payload["documentId"] as? String ?? "")

        case "blockActionsRequest":
            guard let token = payload["token"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self = .unknown(kind)
                return
            }
            self = .requestBlockDeletion(token: token)

        case "selectedBlocksForSubpage":
            let title = payload["title"] as? String ?? "New Sub Page"
            self = .selectedBlocksForSubpage(
                title: title,
                canonicalJSON: try Self.documentJSON(from: payload)
            )

        case "haptic":
            let style = payload["style"] as? String ?? "light"
            self = .requestHaptic(style: style)

        case "placeholderConversionRequest":
            self = .requestPlaceholderConversion(token: payload["token"] as? String ?? "")

        default:
            self = .unknown(kind)
        }
    }

    private static func documentJSON(from payload: [String: Any]) throws -> String {
        if let document = payload["document"] {
            return try TipTapContentAnalyzer.normalizePayloadToJSON(document)
        }

        return try TipTapContentAnalyzer.normalizePayloadToJSON(payload)
    }

    private static func slashMenuState(from payload: [String: Any]) -> TipTapSlashMenuState? {
        guard let rawItems = payload["items"] as? [[String: Any]], !rawItems.isEmpty else {
            return nil
        }

        let items = rawItems.compactMap { item -> TipTapSlashMenuItem? in
            guard let key = item["key"] as? String, !key.isEmpty else { return nil }
            return TipTapSlashMenuItem(
                key: key,
                title: item["title"] as? String ?? key,
                detail: item["detail"] as? String ?? "",
                icon: item["icon"] as? String ?? "sparkle"
            )
        }

        guard !items.isEmpty else { return nil }

        let selectedIndex = Int(payload.cgFloatValue(for: "selectedIndex") ?? 0)

        return TipTapSlashMenuState(
            query: payload["query"] as? String ?? "",
            selectedIndex: max(0, min(selectedIndex, items.count - 1)),
            anchorX: payload.cgFloatValue(for: "anchorX") ?? 0,
            anchorY: payload.cgFloatValue(for: "anchorY") ?? 0,
            width: payload.cgFloatValue(for: "width") ?? 342,
            items: items
        )
    }

    private static func pageBreakRegions(from payload: [String: Any]) -> [TipTapPageBreakRegion] {
        guard let rawRegions = payload["regions"] as? [[String: Any]] else {
            return []
        }

        return rawRegions.compactMap { region in
            guard
                let y = region.cgFloatValue(for: "y"),
                let height = region.cgFloatValue(for: "height"),
                height > 0
            else {
                return nil
            }
            return TipTapPageBreakRegion(y: y, height: height)
        }
    }
}

nonisolated struct TipTapFormattingState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var code = false
    var alignment: String?
    var checklist = false
    var bulletList = false
    var numberList = false
    var hasTextSelection = false
    var textColor: InlineTextColor?
    var canColorText = false
    var textColorToken: String?

    static func decode(_ payload: [String: Any]) -> Self {
        let alignment = payload["alignment"] as? String
        return Self(bold: payload["bold"] as? Bool ?? false,
            italic: payload["italic"] as? Bool ?? false,
            underline: payload["underline"] as? Bool ?? false,
            strike: payload["strike"] as? Bool ?? false,
            code: payload["code"] as? Bool ?? false,
            alignment: alignment.flatMap { ["left", "center", "right", "justify"].contains($0) ? $0 : nil },
            checklist: payload["checklist"] as? Bool ?? false,
            bulletList: payload["bulletList"] as? Bool ?? false,
            numberList: payload["numberList"] as? Bool ?? false,
            hasTextSelection: payload["hasTextSelection"] as? Bool ?? false,
            textColor: InlineTextColor.decode(payload["textColor"]),
            canColorText: payload["canColorText"] as? Bool ?? (payload["hasTextSelection"] as? Bool ?? false),
            textColorToken: payload["textColorToken"] as? String)
    }
}

nonisolated struct TipTapCaretUpdate: Equatable {
    var rect: CGRect
    var revision: Int

    static func decode(_ payload: [String: Any]) -> Self? {
        guard let x = payload.cgFloatValue(for: "x"), let y = payload.cgFloatValue(for: "y"),
              let width = payload.cgFloatValue(for: "width"), let height = payload.cgFloatValue(for: "height"),
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0,
              let revision = payload["revision"] as? Int, revision >= 0 else { return nil }
        return Self(rect: CGRect(x: x, y: y, width: width, height: height), revision: revision)
    }
}

nonisolated enum TipTapCaretVisibility {
    static func targetOffset(caret: CGRect, viewport: CGRect, current: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat? {
        guard [caret.minY, caret.maxY, viewport.minY, viewport.maxY, current, minimum, maximum].allSatisfy(\.isFinite),
              caret.height > 0, viewport.height > 0, maximum >= minimum else { return nil }
        let delta: CGFloat
        if caret.maxY > viewport.maxY || caret.height >= viewport.height {
            delta = caret.maxY - viewport.maxY
        } else if caret.minY < viewport.minY {
            delta = caret.minY - viewport.minY
        } else {
            return nil
        }
        guard abs(delta) > 1 else { return nil }
        return min(maximum, max(minimum, current + delta))
    }
}

struct TipTapPageBreakRegion: Equatable, Identifiable {
    var y: CGFloat
    var height: CGFloat

    var id: String {
        "\(Int((y * 10).rounded()))-\(Int((height * 10).rounded()))"
    }
}

struct TipTapCollectionRegion: Equatable, Identifiable {
    var id: String
    var collectionID: String
    var rect: CGRect
}

struct TipTapSlashMenuItem: Equatable, Identifiable {
    var key: String
    var title: String
    var detail: String
    var icon: String

    var id: String { key }
}

struct TipTapSlashMenuState: Equatable {
    var query: String
    var selectedIndex: Int
    var anchorX: CGFloat
    var anchorY: CGFloat
    var width: CGFloat
    var items: [TipTapSlashMenuItem]
}

private extension Dictionary where Key == String, Value == Any {
    nonisolated func cgFloatValue(for key: String) -> CGFloat? {
        if let value = self[key] as? CGFloat {
            return value
        }
        if let value = self[key] as? Double {
            return CGFloat(value)
        }
        if let value = self[key] as? NSNumber {
            return CGFloat(truncating: value)
        }
        return nil
    }
}

enum TipTapSaveState: Equatable {
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

struct TipTapEditorCommand {
    var name: String
    var args: [String: Any]

    init(_ name: String, args: [String: Any] = [:]) {
        self.name = name
        self.args = args
    }

    static func loadDocument(canonicalJSON: String) -> TipTapEditorCommand {
        TipTapEditorCommand(
            "setContent",
            args: [
                "document": TipTapContentAnalyzer.documentObject(from: canonicalJSON)
            ]
        )
    }

    static func requestSnapshot() -> TipTapEditorCommand {
        TipTapEditorCommand("requestSnapshot")
    }

    static func focusEditor() -> TipTapEditorCommand {
        TipTapEditorCommand("focus")
    }

    static func focusDocumentEnd() -> TipTapEditorCommand {
        TipTapEditorCommand("focusDocumentEnd")
    }

    static func setEditable(_ editable: Bool) -> TipTapEditorCommand {
        TipTapEditorCommand("setEditable", args: ["editable": editable])
    }

    static func setTheme(_ theme: String) -> TipTapEditorCommand {
        TipTapEditorCommand("setTheme", args: ["theme": theme])
    }

    static func setAppearance(_ appearance: DocumentAppearance, interfaceScheme: ColorScheme = .dark) -> TipTapEditorCommand {
        TipTapEditorCommand(
            "setAppearance",
            args: [
                "textColor": appearance.textColorHex,
                "fontFamily": appearance.fontStyle.cssFamily,
                "pageBackground": "transparent",
                "colorScheme": appearance.presentationColorScheme == .light ? "light" : "dark",
                "interfaceScheme": interfaceScheme == .light ? "light" : "dark"
            ]
        )
    }

    static func registerIconAsset(icon: String, src: String) -> TipTapEditorCommand {
        TipTapEditorCommand(
            "registerIconAsset",
            args: [
                "icon": icon,
                "src": src
            ]
        )
    }

    static func registerIconAssets(_ assets: [String: String]) -> TipTapEditorCommand {
        TipTapEditorCommand(
            "registerIconAssets",
            args: ["assets": assets]
        )
    }

    static func insertDivider(_ style: VellixDividerStyle) -> TipTapEditorCommand {
        TipTapEditorCommand("insertDivider", args: ["style": style.rawValue])
    }

    static func insertPageBreak() -> TipTapEditorCommand {
        TipTapEditorCommand("insertPageBreak")
    }

    static func insertBlock(_ blockType: String) -> TipTapEditorCommand {
        TipTapEditorCommand("insertBlock", args: ["blockType": blockType])
    }

    static func insertCallout(icon: String, text: String, color: String = "#ffffff") -> TipTapEditorCommand {
        TipTapEditorCommand(
            "insertCallout",
            args: [
                "icon": icon,
                "text": text,
                "color": color
            ]
        )
    }

    static func setSelectedBlockType(_ blockType: String, level: Int? = nil, color: String? = nil) -> TipTapEditorCommand {
        var args: [String: Any] = [
            "blockType": blockType
        ]

        if let level {
            args["level"] = level
        }

        if let color {
            args["color"] = color
        }

        return TipTapEditorCommand("setSelectedBlockType", args: args)
    }

    static func indentSelectedBlocks() -> TipTapEditorCommand {
        TipTapEditorCommand("indentSelectedBlocks")
    }

    static func outdentSelectedBlocks() -> TipTapEditorCommand {
        TipTapEditorCommand("outdentSelectedBlocks")
    }

    static func setSelectedCalloutColor(_ color: String) -> TipTapEditorCommand {
        TipTapEditorCommand("setSelectedCalloutColor", args: ["color": color])
    }

    static func formatSelectedBlocks(action: String, value: String? = nil) -> TipTapEditorCommand {
        var args: [String: Any] = ["action": action]
        if let value {
            args["value"] = value
        }
        return TipTapEditorCommand("formatSelectedBlocks", args: args)
    }

    static func toggleTextMark(_ mark: String) -> TipTapEditorCommand {
        TipTapEditorCommand("toggleTextMark", args: ["mark": mark])
    }

    static func formatCurrentSelection(action: String, value: String? = nil) -> TipTapEditorCommand {
        var args: [String: Any] = ["action": action]
        if let value {
            args["value"] = value
        }
        return TipTapEditorCommand("formatCurrentSelection", args: args)
    }

    static func updateCalloutIcon(blockID: String?, icon: String) -> TipTapEditorCommand {
        var args: [String: Any] = ["icon": icon]

        if let blockID {
            args["blockId"] = blockID
        }

        return TipTapEditorCommand("updateCalloutIcon", args: args)
    }

    static func updateCalloutColor(blockID: String, color: String) -> TipTapEditorCommand {
        TipTapEditorCommand(
            "updateCalloutColor",
            args: [
                "blockId": blockID,
                "color": color
            ]
        )
    }

    static func deleteSelectedBlocks() -> TipTapEditorCommand {
        TipTapEditorCommand("deleteSelectedBlocks")
    }

    static func updateBlockquoteColor(blockID: String, color: String) -> TipTapEditorCommand {
        TipTapEditorCommand(
            "updateBlockquoteColor",
            args: ["blockId": blockID, "color": color]
        )
    }

    static func updateInlineProperty(blockID: String, property: InlinePropertyDefinition) throws -> TipTapEditorCommand {
        TipTapEditorCommand("updateInlineProperty", args: ["blockId": blockID, "property": try property.bridgeObject()])
    }

    static func deleteInlineProperty(blockID: String) -> TipTapEditorCommand {
        TipTapEditorCommand("deleteInlineProperty", args: ["blockId": blockID])
    }

    static func copySelectedBlocks() -> TipTapEditorCommand {
        TipTapEditorCommand("copySelectedBlocks")
    }

    static func cutSelectedBlocks() -> TipTapEditorCommand {
        TipTapEditorCommand("cutSelectedBlocks")
    }

    static func duplicateSelectedBlocks() -> TipTapEditorCommand {
        TipTapEditorCommand("duplicateSelectedBlocks")
    }

    static func requestSelectedBlocksForSubpage() -> TipTapEditorCommand {
        TipTapEditorCommand("requestSelectedBlocksForSubpage")
    }

    static func selectAllBlocks() -> TipTapEditorCommand {
        TipTapEditorCommand("selectAllBlocks")
    }

    static func setSelectionMode(_ mode: String) -> TipTapEditorCommand {
        TipTapEditorCommand("setSelectionMode", args: ["mode": mode])
    }

    static func clearBlockSelection() -> TipTapEditorCommand {
        TipTapEditorCommand("clearBlockSelection")
    }

    static func chooseSlashMenuItem(_ key: String) -> TipTapEditorCommand {
        TipTapEditorCommand("chooseSlashItem", args: ["key": key])
    }

    static func undo() -> TipTapEditorCommand {
        TipTapEditorCommand("undo")
    }

    static func redo() -> TipTapEditorCommand {
        TipTapEditorCommand("redo")
    }
}
