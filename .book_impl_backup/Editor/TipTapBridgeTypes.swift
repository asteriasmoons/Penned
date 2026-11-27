//
//  TipTapBridgeTypes.swift
//  Vellix
//

import Foundation
import CoreGraphics
import SwiftUI

enum TipTapEditorEvent: Equatable {
    case requestTemplates(token: String)
    case tagRequest(InlineTagRequest)
    case requestCollection(CollectionEditorRequest)
    case requestTemplateComponent(TemplateComponentRequest)
    case requestAttachment(AttachmentEditorRequest)
    case requestAttachmentActions(AttachmentEditorRequest)
    case importAttachments(token: String, files: [AttachmentImportData])
    case attachmentClipboard(token: String, html: String, text: String, nativeJSON: String)
    case editorReady(blockCount: Int)
    case documentChanged(String)
    case documentTextChanged(String)
    case documentSnapshot(String)
    case editorError(String)
    case focusChanged(Bool)
    case formattingStateChanged(TipTapFormattingState)
    case textConversionStateChanged(TipTapTextConversionState)
    case requestBlockConversion(TipTapBlockConversionRequest)
    case statisticsChanged(wordCount: Int, characterCount: Int)
    case contentHeightChanged(height: CGFloat, visualContentBottom: CGFloat)
    case caretChanged(TipTapCaretUpdate)
    case pageBreakRegionsChanged([TipTapPageBreakRegion])
    case collectionRegionsChanged([TipTapCollectionRegion])
    case blockSelectionChanged(Int)
    case selectionModeChanged(String)
    case requestGridCardSettings(GridCardSettingsRequest)
    case requestIconCalloutSettings(IconCalloutSettingsRequest)
    case requestWashiTapeSettings(WashiTapeRequest)
    case requestHeadingLabelSettings(HeadingLabelRequest)
    case requestCalloutColorPicker(blockID: String, color: String)
    case requestBlockquoteColorPicker(blockID: String, color: String)
    case requestInlinePropertyEditor(blockID: String, property: InlinePropertyDefinition, resumeEditing: Bool = true)
    case requestPropertyURL(String)
    case requestNestedPage(blockID: String)
    case requestPageCard(blockID: String)
    case requestOpenPage(documentID: String)
    case requestPageActions(documentID: String)
    case requestPageCardSettings(documentID: String)
    case requestBlockDeletion(token: String, blockType: String, blockID: String)
    case requestListGridSettings(TipTapListGridSettings)
    case requestCodeBlockEditor(CodeBlockEditorRequest)
    case requestTabsSettings(TipTapTabsSettings)
    case requestWeekStripSettings(WeekStripSettingsRequest)
    case requestMoodBarSettings(MoodBarSettingsRequest)
    case requestCountdownSettings(CountdownSettingsRequest)
    case requestCalculatorSettings(CalculatorSettingsRequest)
    case calculatorAction(blockID: String, action: String, settings: CalculatorSettings, value: String?)
    case requestExistingEventPicker
    case openLinkedCalendarEvent(eventID: String, identity: CalendarEventIdentity, start: Date)
    case requestMinimalFieldsSettings(TipTapMinimalFieldsSettings)
    case requestInformationCardSettings(TipTapInformationCardSettings)
    case slashMenuChanged(TipTapSlashMenuState?)
    case selectedBlocksForSubpage(token: String, canonicalJSON: String)
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
        case "templateRequest":
            guard let token = payload["token"] as? String, !token.isEmpty else { self = .unknown(kind); return }
            self = .requestTemplates(token: token)
        case "textConversionState":
            self = .textConversionStateChanged(TipTapTextConversionState.decode(payload))
        case "blockConversionRequest":
            guard let target = payload["target"] as? String, let token = payload["token"] as? String else {
                self = .unknown(kind); return
            }
            let json = try (payload["document"] as? [String: Any]).map {
                String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
            }
            self = .requestBlockConversion(TipTapBlockConversionRequest(target: target, token: token,
                documentIDs: payload["documentIDs"] as? [String] ?? [], canonicalJSON: json))
        case "tagRequest":
            self = InlineTagRequest.decode(payload).map(Self.tagRequest) ?? .unknown(kind)
        case "attachmentClipboard":
            guard let token = payload["token"] as? String, let html = payload["html"] as? String,
                  let nativeJSON = payload["nativeJSON"] as? String,
                  html.utf8.count <= 4 * 1024 * 1024,
                  nativeJSON.utf8.count <= 4 * 1024 * 1024 else {
                self = .editorError("The selected blocks are too large to copy together.")
                return
            }
            self = .attachmentClipboard(token: token, html: html,
                text: payload["text"] as? String ?? "", nativeJSON: nativeJSON)
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
            if let json = payload["textDocumentJSON"] as? String {
                // The matching editor bundle sends its normalized document as one
                // string. Validate/canonicalize it with the repository save,
                // not by converting a full WKScriptMessage object on main.
                guard json.hasPrefix("{\"type\":\"doc\",") else {
                    throw VellixError.invalidEditorJSON("The editor text checkpoint did not contain a document.")
                }
                self = .documentTextChanged(json)
            } else {
                self = .documentChanged(try Self.documentJSON(from: payload))
            }

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

        case "gridCardSettings":
            self = GridCardSettingsRequest(payload: payload).map(Self.requestGridCardSettings) ?? .unknown(kind)
        case "iconCalloutSettings":
            self = IconCalloutSettingsRequest(payload: payload).map(Self.requestIconCalloutSettings) ?? .unknown(kind)

        case "washiTapeSettings":
            self = WashiTapeRequest(payload: payload).map(Self.requestWashiTapeSettings) ?? .unknown(kind)

        case "headingLabelSettings":
            self = HeadingLabelRequest(payload: payload).map(Self.requestHeadingLabelSettings) ?? .unknown(kind)

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
            self = .requestInlinePropertyEditor(blockID: blockID, property: property,
                resumeEditing: payload["resumeEditing"] as? Bool ?? true)

        case "propertyURLRequest":
            guard let value = payload["url"] as? String,
                  let url = InlinePropertyDefinition.safeURL(value) else {
                self = .unknown(kind)
                return
            }
            self = .requestPropertyURL(url.absoluteString)

        case "documentLinkOpen":
            self = (payload["url"] as? String).flatMap(DocumentLinkURL.openable)
                .map { .requestPropertyURL($0.absoluteString) } ?? .unknown(kind)

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

        case "pageCardSettingsRequest":
            self = .requestPageCardSettings(documentID: payload["documentId"] as? String ?? "")

        case "blockActionsRequest":
            guard let token = payload["token"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self = .unknown(kind)
                return
            }
            self = .requestBlockDeletion(token: token,
                blockType: payload["blockType"] as? String ?? "",
                blockID: payload["blockId"] as? String ?? "")

        case "codeBlockEdit":
            self = CodeBlockEditorRequest(payload: payload).map(Self.requestCodeBlockEditor) ?? .unknown(kind)
        case "listGridSettings":
            guard let blockID = payload["blockId"] as? String, !blockID.isEmpty else { self = .unknown(kind); return }
            let defaults = payload["defaults"] as? [String: Any] ?? [:]
            let rawRows = payload["rows"] as? [[String: Any]] ?? []
            let rows = rawRows.map { row in
                let style = TipTapListGridRowStyle(rawValue: row["rowStyle"] as? String ?? "")
                    ?? ((row["isHeader"] as? Bool) == true ? .filled : .standard)
                return TipTapListGridRow(label: row["label"] as? String ?? "", value: row["value"] as? String ?? "", style: style)
            }
            let leftFractionValue = (payload["leftFraction"] as? Int) ?? (payload["leftFraction"] as? NSNumber)?.intValue ?? 34
            let defaultFractionValue = (defaults["leftFraction"] as? Int) ?? (defaults["leftFraction"] as? NSNumber)?.intValue ?? 34
            self = .requestListGridSettings(TipTapListGridSettings(
                blockID: blockID,
                cardBackground: payload["cardBackground"] as? String ?? "#E8DEF5",
                cardBorder: payload["cardBorder"] as? String ?? "#DBCEEF",
                leftBackground: payload["leftBackground"] as? String ?? "#D3C6E7",
                rightBorder: payload["rightBorder"] as? String ?? "#E4D9F3",
                leftFraction: leftFractionValue,
                defaultLeftFraction: defaultFractionValue,
                rows: rows))

        case "linkedCalendarEventTap":
            guard let eventID = payload["eventID"] as? String,
                  let rawIdentity = payload["eventIdentity"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: rawIdentity),
                  let identity = try? JSONDecoder().decode(CalendarEventIdentity.self, from: data),
                  let rawStart = payload["start"] as? String,
                  let start = ISO8601DateFormatter().date(from: rawStart) else {
                self = .unknown(kind); return
            }
            self = .openLinkedCalendarEvent(eventID: eventID, identity: identity, start: start)
        case "existingEventPickerRequest":
            self = .requestExistingEventPicker
        case "moodBarSettings":
            guard let blockID = payload["blockId"] as? String, !blockID.isEmpty else { self = .unknown(kind); return }
            self = .requestMoodBarSettings(MoodBarSettingsRequest(blockID: blockID,
                settings: MoodBarSettings(payload["settings"] as? [String: Any] ?? [:])))
        case "countdownSettings":
            guard let blockID = payload["blockId"] as? String, !blockID.isEmpty else { self = .unknown(kind); return }
            self = .requestCountdownSettings(CountdownSettingsRequest(blockID: blockID,
                settings: CountdownSettings(payload["settings"] as? [String: Any] ?? [:])))
        case "calculatorSettings":
            guard let blockID = payload["blockId"] as? String, !blockID.isEmpty else { self = .unknown(kind); return }
            self = .requestCalculatorSettings(CalculatorSettingsRequest(blockID: blockID,
                settings: CalculatorSettings(payload["settings"] as? [String: Any] ?? [:]),
                state: CalculatorState(payload["state"] as? [String: Any] ?? [:])))
        case "calculatorAction":
            guard let blockID = payload["blockID"] as? String, !blockID.isEmpty,
                  let action = payload["action"] as? String, ["press", "copy"].contains(action) else { self = .unknown(kind); return }
            self = .calculatorAction(blockID: blockID, action: action,
                settings: CalculatorSettings(payload["settings"] as? [String: Any] ?? [:]), value: payload["value"] as? String)
        case "weekStripSettings":
            guard let blockID = payload["blockId"] as? String, !blockID.isEmpty else {
                self = .unknown(kind)
                return
            }
            self = .requestWeekStripSettings(WeekStripSettingsRequest(blockID: blockID, settings: payload["settings"] as? [String: Any] ?? [:]))
        case "tabsSettings":
            guard let blockID = payload["blockId"] as? String, !blockID.isEmpty else { self = .unknown(kind); return }
            let rawTabs = payload["tabs"] as? [[String: Any]] ?? []
            let tabs = rawTabs.compactMap { tab -> TipTapTabInfo? in
                guard let id = tab["id"] as? String, !id.isEmpty else { return nil }
                return TipTapTabInfo(tabID: id, name: tab["name"] as? String ?? "")
            }
            func tabsInt(_ key: String, _ fallback: Int) -> Int {
                (payload[key] as? Int) ?? (payload[key] as? NSNumber)?.intValue ?? fallback
            }
            self = .requestTabsSettings(TipTapTabsSettings(
                blockID: blockID,
                activeTab: payload["activeTab"] as? String ?? (tabs.first?.tabID ?? ""),
                tabs: tabs,
                showContainer: payload["showContainer"] as? Bool ?? true,
                showHeader: payload["showHeader"] as? Bool ?? false,
                title: payload["title"] as? String ?? "",
                subtitle: payload["subtitle"] as? String ?? "",
                icon: payload["icon"] as? String ?? "",
                tabBarStyle: payload["tabBarStyle"] as? String ?? "filled",
                alignment: payload["alignment"] as? String ?? "leading",
                dividerVisible: payload["dividerVisible"] as? Bool ?? true,
                activeTabBg: payload["activeTabBg"] as? String ?? "#3A3A3C",
                activeTabText: payload["activeTabText"] as? String ?? "#FFFFFF",
                inactiveTabBg: payload["inactiveTabBg"] as? String ?? "#1C1C1E",
                inactiveTabText: payload["inactiveTabText"] as? String ?? "#9A9AA0",
                indicatorColor: payload["indicatorColor"] as? String ?? "#7C5CFF",
                titleColor: payload["titleColor"] as? String ?? "#FFFFFF",
                subtitleColor: payload["subtitleColor"] as? String ?? "#9A9AA0",
                tabCornerRadius: tabsInt("tabCornerRadius", 10),
                tabSpacing: tabsInt("tabSpacing", 8),
                containerBg: payload["containerBg"] as? String ?? "#111113",
                containerBorder: payload["containerBorder"] as? String ?? "#2A2A2E",
                borderWidth: tabsInt("borderWidth", 1),
                cornerRadius: tabsInt("cornerRadius", 16),
                padding: tabsInt("padding", 14),
                outerSpacing: tabsInt("outerSpacing", 8),
                shadow: payload["shadow"] as? Bool ?? false))

        case "informationCardSettings":
            guard let blockID = payload["blockId"] as? String, !blockID.isEmpty else { self = .unknown(kind); return }
            self = .requestInformationCardSettings(TipTapInformationCardSettings(
                blockID: blockID,
                backgroundColor: payload["backgroundColor"] as? String ?? "#202024",
                borderColor: payload["borderColor"] as? String ?? "#393940",
                dividerColor: payload["dividerColor"] as? String ?? "#393940",
                titleColor: payload["titleColor"] as? String ?? "#FFFFFF",
                textColor: payload["textColor"] as? String ?? "#E4E4EA",
                cornerRadius: (payload["cornerRadius"] as? NSNumber)?.intValue ?? 16,
                padding: (payload["padding"] as? NSNumber)?.intValue ?? 16,
                showBorder: payload["showBorder"] as? Bool ?? true,
                borderThickness: (payload["borderThickness"] as? NSNumber)?.intValue ?? 1,
                showLabels: payload["showLabels"] as? Bool ?? true,
                collapsible: payload["collapsible"] as? Bool ?? false,
                hideTitle: payload["hideTitle"] as? Bool ?? false,
                hideDescription: payload["hideDescription"] as? Bool ?? false,
                hideDivider: payload["hideDivider"] as? Bool ?? false))
        case "minimalFieldsSettings":
            guard let blockID = payload["blockId"] as? String, !blockID.isEmpty else { self = .unknown(kind); return }
            let rawRecords = payload["records"] as? [[String: Any]] ?? []
            let records = rawRecords.compactMap { record -> TipTapMinimalRecord? in
                guard let id = record["id"] as? String, !id.isEmpty else { return nil }
                let rawFields = record["fields"] as? [[String: Any]] ?? []
                let fields = rawFields.compactMap { field -> TipTapMinimalFieldInfo? in
                    guard let fieldID = field["id"] as? String, !fieldID.isEmpty else { return nil }
                    return TipTapMinimalFieldInfo(fieldID: fieldID, label: field["label"] as? String ?? "")
                }
                return TipTapMinimalRecord(recordID: id, title: record["title"] as? String ?? "", fields: fields)
            }
            func minInt(_ key: String, _ fallback: Int) -> Int {
                (payload[key] as? Int) ?? (payload[key] as? NSNumber)?.intValue ?? fallback
            }
            self = .requestMinimalFieldsSettings(TipTapMinimalFieldsSettings(
                blockID: blockID,
                records: records,
                accentColor: payload["accentColor"] as? String ?? "#7C5CFF",
                accentWidth: minInt("accentWidth", 3),
                titleColor: payload["titleColor"] as? String ?? "#FFFFFF",
                labelColor: payload["labelColor"] as? String ?? "#B98CFF",
                valueColor: payload["valueColor"] as? String ?? "#E4E4EA",
                dividerColor: payload["dividerColor"] as? String ?? "#2A2A2E",
                dividerVisible: payload["dividerVisible"] as? Bool ?? true,
                showRecordTitles: payload["showRecordTitles"] as? Bool ?? true,
                labelUppercase: payload["labelUppercase"] as? Bool ?? true,
                titleSize: minInt("titleSize", 20),
                labelSize: minInt("labelSize", 12),
                valueSize: minInt("valueSize", 15),
                fieldSpacing: minInt("fieldSpacing", 12),
                recordSpacing: minInt("recordSpacing", 18),
                outerSpacing: minInt("outerSpacing", 8)))

        case "selectedBlocksForSubpage":
            guard let token = payload["token"] as? String, !token.isEmpty else {
                throw VellixError.editorBridge("The editor bundle must be updated before grouping blocks.")
            }
            self = .selectedBlocksForSubpage(
                token: token,
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
                title: DocumentTextStyleNames.menuTitle(for: key, fallback: item["title"] as? String ?? key),
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
            anchorAboveY: payload.cgFloatValue(for: "anchorAboveY"),
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

enum TipTapListGridRowStyle: String, CaseIterable {
    case standard = "default"
    case filled
    case outlined

    var title: String {
        switch self {
        case .standard: return "Default"
        case .filled: return "Both Filled"
        case .outlined: return "Both Outlined"
        }
    }
}

struct TipTapListGridRow: Equatable {
    var label: String
    var value: String
    var style: TipTapListGridRowStyle = .standard
}

struct TipTapListGridSettings: Identifiable, Equatable {
    let id = UUID()
    var blockID: String
    var cardBackground: String
    var cardBorder: String
    var leftBackground: String
    var rightBorder: String
    var leftFraction: Int
    var defaultLeftFraction: Int
    var rows: [TipTapListGridRow]
}

struct TipTapTabInfo: Identifiable, Equatable {
    var tabID: String
    var name: String
    var id: String { tabID }
}

struct WeekStripSettingsRequest: Identifiable, Equatable {
    let id = UUID()
    let blockID: String
    let settings: [String: Any]
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.blockID == rhs.blockID && lhs.id == rhs.id }
}

struct TipTapTabsSettings: Identifiable, Equatable {
    let id = UUID()
    var blockID: String
    var activeTab: String
    var tabs: [TipTapTabInfo]
    // General
    var showContainer: Bool
    var showHeader: Bool
    var title: String
    var subtitle: String
    var icon: String
    // Appearance
    var tabBarStyle: String
    var alignment: String
    var dividerVisible: Bool
    var activeTabBg: String
    var activeTabText: String
    var inactiveTabBg: String
    var inactiveTabText: String
    var indicatorColor: String
    var titleColor: String
    var subtitleColor: String
    var tabCornerRadius: Int
    var tabSpacing: Int
    // Container
    var containerBg: String
    var containerBorder: String
    var borderWidth: Int
    var cornerRadius: Int
    var padding: Int
    var outerSpacing: Int
    var shadow: Bool
}

struct TipTapMinimalFieldInfo: Identifiable, Equatable {
    var fieldID: String
    var label: String
    var id: String { fieldID }
}

struct TipTapMinimalRecord: Identifiable, Equatable {
    var recordID: String
    var title: String
    var fields: [TipTapMinimalFieldInfo]
    var id: String { recordID }
}

struct TipTapInformationCardSettings: Identifiable, Equatable {
    let id = UUID()
    var blockID: String
    var backgroundColor: String
    var borderColor: String
    var dividerColor: String
    var titleColor: String
    var textColor: String
    var cornerRadius: Int
    var padding: Int
    var showBorder: Bool
    var borderThickness: Int
    var showLabels: Bool
    var collapsible: Bool
    var hideTitle = false
    var hideDescription = false
    var hideDivider = false
}

struct TipTapMinimalFieldsSettings: Identifiable, Equatable {
    let id = UUID()
    var blockID: String
    var records: [TipTapMinimalRecord]
    // Appearance
    var accentColor: String
    var accentWidth: Int
    var titleColor: String
    var labelColor: String
    var valueColor: String
    var dividerColor: String
    var dividerVisible: Bool
    var showRecordTitles: Bool
    var labelUppercase: Bool
    var titleSize: Int
    var labelSize: Int
    var valueSize: Int
    var fieldSpacing: Int
    var recordSpacing: Int
    var outerSpacing: Int
}

nonisolated struct TipTapSelectedBlocksStyle: Equatable {
    var type: String?
    var alignment: String?
    var list: String?
    var font: String?
    var target: String?
    var marks: Set<String> = []
    var canLabel = false
    var canColorDivider = false
    var dividerColor: String?

    static func decode(_ value: Any?) -> Self? {
        guard let payload = value as? [String: Any] else { return nil }
        return Self(type: payload["type"] as? String, alignment: payload["alignment"] as? String,
                    list: payload["list"] as? String, font: payload["font"] as? String,
                    target: payload["target"] as? String,
                    marks: Set(payload["marks"] as? [String] ?? []), canLabel: payload["canLabel"] as? Bool ?? false,
                    canColorDivider: payload["canColorDivider"] as? Bool ?? false, dividerColor: payload["dividerColor"] as? String)
    }
}

nonisolated struct TipTapSelectedBlockSettings: Equatable {
    let kind: String
    let blockID: String
    let selectionTarget: String

    static func decode(_ value: Any?) -> Self? {
        guard let payload = value as? [String: Any], let kind = payload["kind"] as? String,
              let blockID = payload["blockID"] as? String, !blockID.isEmpty,
              let target = payload["selectionTarget"] as? String, !target.isEmpty else { return nil }
        return Self(kind: kind, blockID: blockID, selectionTarget: target)
    }

    var title: String? { Self.title(for: kind) }

    static func title(for kind: String?) -> String? {
        switch kind {
        case "headingLabel": "Heading Label Settings"
        case "minimalFields": "Fields Settings"
        case "informationCard": "Information Card Settings"
        case "tabs": "Tabs Settings"
        case "plainCallout": "Callout Settings"
        case "blockquote": "Blockquote Color"
        case "listGrid": "List Grid Settings"
        case "moodBar": "Mood Bar Settings"
        case "countdown": "Countdown Settings"
        case "calculator": "Calculator Settings"
        case "gridCard": "Grid Card Settings"
        case "iconCallout": "Icon Callout Settings"
        case "codeBlock": "Code Block Settings"
        case "washiTape": "Washi Tape Settings"
        case "table": "Table Settings"
        case "attachment": "File Settings"
        case "taskItem": "Task Settings"
        case "inlineProperty": "Property Settings"
        case "templateComponent": "Component Settings"
        case "collection": "Collection Settings"
        case "pageCard": "Page Card Settings"
        case "documentLink": "Link Settings"
        default: nil
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
    var canLinkText = false
    var textLinkActive = false
    var canOpenListGridSettings = false
    var blockSettingsKind: String?
    var selectedBlockSettings: TipTapSelectedBlockSettings?
    var selectedLink: SelectedDocumentLink?
    var selectedBlocksStyle: TipTapSelectedBlocksStyle?

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
            textColorToken: payload["textColorToken"] as? String,
            canLinkText: payload["canLinkText"] as? Bool ?? false,
            textLinkActive: payload["textLinkActive"] as? Bool ?? false,
            canOpenListGridSettings: payload["canOpenListGridSettings"] as? Bool ?? false,
            blockSettingsKind: payload["blockSettingsKind"] as? String,
            selectedBlockSettings: TipTapSelectedBlockSettings.decode(payload["selectedBlockSettings"]),
            selectedLink: SelectedDocumentLink(payload["selectedLink"]),
            selectedBlocksStyle: TipTapSelectedBlocksStyle.decode(payload["selectedBlocksStyle"]))
    }

    var blockSettingsTitle: String? {
        TipTapSelectedBlockSettings.title(for: blockSettingsKind) ?? (canOpenListGridSettings ? "List Grid Settings" : nil)
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

enum DocumentTextStyleNames {
    nonisolated static func heading(_ level: Int) -> String {
        switch level {
        case 1: return "Title"
        case 2: return "Subtitle"
        case 3: return "Heading"
        case 4: return "Subheading"
        default: return "Subheading"
        }
    }

    nonisolated static func menuTitle(for key: String, fallback: String) -> String {
        if key.hasPrefix("heading"), let level = Int(key.dropFirst("heading".count)), (1...4).contains(level) {
            return heading(level)
        }
        if key.hasPrefix("toggleHeading"), let level = Int(key.dropFirst("toggleHeading".count)), (1...4).contains(level) {
            return "Toggle " + heading(level)
        }
        return fallback
    }
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
    var anchorAboveY: CGFloat? = nil
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
                "document": TipTapContentAnalyzer.documentObject(from: canonicalJSON),
                "textCheckpoints": true
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

    static func setEditable(_ editable: Bool, preservingBlockSelection: Bool = false) -> TipTapEditorCommand {
        TipTapEditorCommand("setEditable", args: ["editable": editable, "preservingBlockSelection": preservingBlockSelection])
    }

    static func setTheme(_ theme: String) -> TipTapEditorCommand {
        TipTapEditorCommand("setTheme", args: ["theme": theme])
    }

    static func setAppearance(_ appearance: DocumentAppearance, interfaceScheme: ColorScheme = .dark) -> TipTapEditorCommand {
        let paper = appearance.themeID == nil ? appearance.editorBackground : appearance.innerPageBackground
        // The paper is painted by SwiftUI. This token describes it to the
        // WebView for contrast calculations; the WebView stays transparent.
        return TipTapEditorCommand(
            "setAppearance",
            args: [
                "textColor": appearance.textColorHex,
                "fontFamily": appearance.fontStyle.cssFamily,
                "pageBackground": paper.kind == .solid ? paper.colorHex : "transparent",
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

    static func setSelectedBlockType(_ blockType: String, level: Int? = nil, color: String? = nil,
                                     selectionTarget: String? = nil) -> TipTapEditorCommand {
        var args: [String: Any] = [
            "blockType": blockType
        ]

        if let level {
            args["level"] = level
        }

        if let color {
            args["color"] = color
        }
        if let selectionTarget { args["selectionTarget"] = selectionTarget }

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

    static func formatSelectedBlocks(action: String, value: String? = nil, selectionTarget: String? = nil) -> TipTapEditorCommand {
        var args: [String: Any] = ["action": action]
        if let value {
            args["value"] = value
        }
        if let selectionTarget { args["selectionTarget"] = selectionTarget }
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
