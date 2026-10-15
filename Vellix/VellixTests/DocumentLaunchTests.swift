import Foundation
import CoreGraphics
import CryptoKit
import GRDB
import ImageIO
import SwiftUI
import Testing
#if canImport(AppKit)
import AppKit
#endif
@testable import Vellix

@MainActor
struct DocumentLaunchTests {
    private func image(_ value: UInt8) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: CGFloat(value) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try #require(context.makeImage())
    }

    @Test func visiblePreviewDoesNotSwapWhenABackgroundRenderingFinishes() throws {
        let first = try image(30), next = try image(90)
        var presentation = DocumentPreviewPresentation()
        presentation.prepare(key: "saved:1") { first }
        var requestedReplacement = false
        presentation.prepare(key: "saved:1") { requestedReplacement = true; return next }
        #expect(!requestedReplacement)
        #expect(presentation.image === first)
        presentation.prepare(key: "saved:2") { next }
        #expect(presentation.image === next)
    }

    @Test func realEditsReplaceTheCompletePreviewAndNeverKeepTheOldRevision() throws {
        var presentation = DocumentPreviewPresentation()
        presentation.prepare(key: "before") { try? image(40) }
        presentation.prepare(key: "after") { nil }
        #expect(presentation.key == "after" && presentation.image == nil)
        let next = try image(80)
        presentation.prepare(key: "after") { next }
        #expect(presentation.image === next)
    }

    @Test func previewFilesAreDecodedAndCanBeAtomicallyReplacedAcrossLaunches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved.png")
        #expect(DocumentPreviewImageFile.read(url) == nil)
        try DocumentPreviewImageFile.write(image(30), to: url)
        let first = try #require(DocumentPreviewImageFile.read(url))
        #expect(first.width == 4 && first.height == 4)
        try DocumentPreviewImageFile.write(image(90), to: url)
        let next = try #require(DocumentPreviewImageFile.read(url))
        #expect(first.dataProvider?.data != next.dataProvider?.data)
        try Data("not an image".utf8).write(to: url, options: .atomic)
        #expect(DocumentPreviewImageFile.read(url) == nil)
    }

    @Test func startupWarmsOneRecentPageInsteadOfTheEntireLibrary() {
        let recent = (0..<200).map { DocumentRecord(title: "Page \($0)") }
        #expect(DocumentEditorWarmupPolicy.documentIDs(recent: recent, selectedID: nil) == [recent[0].id])
        #expect(DocumentEditorWarmupPolicy.documentIDs(recent: recent, selectedID: recent[150].id) == [recent[150].id])
        #expect(DocumentEditorWarmupPolicy.documentIDs(recent: [], selectedID: nil).isEmpty)
    }

    @Test func startupDoesNotWarmTrashedArchivedTemplateOrNestedEntries() {
        var trashed = DocumentRecord(title: "Trash"); trashed.isTrashed = true
        var archived = DocumentRecord(title: "Archive"); archived.isArchived = true
        var template = DocumentRecord(title: "Template"); template.templateID = "template"
        let nested = DocumentRecord(title: "Entry", parentDocumentID: "owner")
        let root = DocumentRecord(title: "Root")
        #expect(DocumentEditorWarmupPolicy.documentIDs(recent: [trashed, archived, template, nested, root], selectedID: nil) == [root.id])
    }

    @Test func pixelsMustBeConfirmedAfterTheCurrentLayoutBeforeAPageCanOpen() {
        var state = DocumentPresentationState()
        state.begin(documentID: "page")
        let generation = state.startPreparation()
        state.framePresented(generation: generation)
        state.prepared(generation: generation, nativeViews: ["block": "board"])
        state.framePresented(generation: generation)
        #expect(!state.isReady)
        state.nativeDidLayout(blockID: "block", viewID: "board")
        #expect(state.isContentReady && !state.isReady)
        state.framePresented(generation: generation)
        #expect(state.isReady)
        let next = state.startPreparation()
        state.prepared(generation: next, nativeViews: [:])
        state.framePresented(generation: generation)
        #expect(!state.isReady)
    }

    private var sampleProperties: [InlinePropertyDefinition] {
        func selected(_ name: String, _ names: [String], _ colors: [String]) -> InlinePropertyDefinition {
            var property = InlinePropertyDefinition()
            property.kind = names.count == 1 ? .select : .multiSelect
            property.name = name
            property.options = names.enumerated().map { InlinePropertyOption(id: "\(name)-\($0.offset)", name: $0.element, color: colors[$0.offset]) }
            property.selectedOptionIDs = property.options.map(\.id)
            return property
        }
        var date = InlinePropertyDefinition(); date.kind = .date; date.name = "Date"; date.value = "2026-10-13"
        return [selected("Zodiac Sign", ["Sagittarius"], ["#007ACC"]), date,
            selected("Element", ["Fire"], ["#E6B82E"]), selected("Modality", ["Mutable"], ["#2EC5F4"]),
            selected("Planet", ["Jupiter"], ["#A970FF"]),
            selected("Themes", ["Exploration", "Freedom", "Wisdom"], ["#2EC5F4", "#FFFFFF", "#A970FF"]),
            selected("Observation Status", ["Not Recorded"], ["#E85D9E"])]
    }

    private func propertyJSON(_ properties: [InlinePropertyDefinition]) throws -> String {
        try TipTapContentAnalyzer.makeDocumentJSON(content: properties.enumerated().map { index, property in
            ["type": "inlineProperty", "attrs": ["id": "property-\(index)", "property": try property.bridgeObject()]] as [String: Any]
        })
    }

    @Test func inlineSelectPreviewReadsSelectedIDsNotTheEmptyTextValue() {
        var property = sampleProperties[5]
        #expect(property.value.isEmpty)
        #expect(property.hasDisplayValue)
        #expect(property.selectedOptions.map(\.name) == ["Exploration", "Freedom", "Wisdom"])
        #expect(property.selectedOptions.map(\.color) == ["#2EC5F4", "#FFFFFF", "#A970FF"])
        property.selectedOptionIDs = ["missing", "Themes-2", "Themes-0", "Themes-2"]
        #expect(property.displayValue() == "Exploration, Wisdom")
        property.kind = .select
        #expect(property.selectedOptions.map(\.name) == ["Wisdom"])
        property.selectedOptionIDs = []
        property.placeholder = "Choose a theme"
        #expect(!property.hasDisplayValue && property.displayValue() == "Choose a theme")
    }

    @Test func inlineDatePreviewFormatsCivilDatesWithoutChangingTheCalendarDay() throws {
        var property = sampleProperties[1]
        let locale = Locale(identifier: "en_US")
        for zone in ["America/Chicago", "Pacific/Kiritimati", "Pacific/Honolulu"] {
            #expect(property.displayValue(locale: locale, timeZone: try #require(TimeZone(identifier: zone))) == "Oct 13, 2026")
        }
        property.includeTime = true; property.value = "2026-10-13T09:05"
        let display = property.displayValue(locale: locale, timeZone: try #require(TimeZone(identifier: "America/Chicago")))
        #expect(display.contains("Oct 13, 2026") && display.contains("9:05"))
        property.value = "invalid"; property.placeholder = "Choose a date"
        #expect(!property.hasDisplayValue && property.displayValue() == "Choose a date")
    }

    @Test func inlinePreviewRetainsNumberFormattingLinksCheckboxesAndPlaceholders() {
        var property = InlinePropertyDefinition(); property.name = "Value"; property.kind = .number
        property.value = "40"; property.prefix = "$"; property.suffix = "%"
        #expect(property.displayValue() == "$40%")
        property.kind = .url; property.value = "example.com"; property.urlLabel = "Website"
        #expect(property.displayValue() == "Website")
        property.kind = .checkbox; property.value = ""; property.checked = true
        #expect(property.hasDisplayValue && property.displayValue() == "Checked")
        property.checked = false
        #expect(property.hasDisplayValue && property.displayValue() == "Unchecked")
        property.kind = .text; property.placeholder = "Write a note"
        #expect(!property.hasDisplayValue && property.displayValue() == "Write a note")
    }

    @Test func coldPreviewCanResolveAllInlinePropertiesFromAReopenedDatabaseWithoutAnEditor() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("penned-inline-preview-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        var id = "", key = ""
        do {
            let database = try AppDatabase(DatabaseQueue(path: path)), documents = DocumentRepository(database: database)
            let saved = try documents.create(DocumentDraft(title: "Properties", tipTapJSON: propertyJSON(sampleProperties)))
            id = saved.id
            key = try CollectionRepository(database: database, documents: documents).previewContent(for: saved, documents: documents).cacheKey
        }
        let database = try AppDatabase(DatabaseQueue(path: path)), documents = DocumentRepository(database: database)
        let saved = try documents.requireDocument(id: id)
        let content = try CollectionRepository(database: database, documents: documents).previewContent(for: saved, documents: documents)
        let nodes = try #require(TipTapContentAnalyzer.documentObject(from: saved.tipTapJSON)["content"] as? [[String: Any]])
        let properties = nodes.compactMap { InlinePropertyDefinition.decode(($0["attrs"] as? [String: Any])?["property"]) }
        #expect(properties == sampleProperties)
        #expect(properties.allSatisfy { $0.hasDisplayValue })
        #expect(properties[0].displayValue() == "Sagittarius")
        #expect(properties[5].selectedOptions.count == 3)
        #expect(key == content.cacheKey)
    }

    @Test func inlineRendererRevisionInvalidatesAffectedImagesButKeepsOtherPreviewKeys() throws {
        func oldKey(_ document: DocumentRecord) throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let metadata = try encoder.encode([CollectionSnapshot]())
            let inputs = [["library-preview-v10-collections", metadata.base64EncodedString(), document.title, document.tipTapJSON,
                document.appearanceJSON ?? "", document.cover ?? "", document.cardStyleJSON ?? "", document.icon ?? ""]]
            return document.id + "-" + SHA256.hash(data: try encoder.encode(inputs)).map { String(format: "%02x", $0) }.joined()
        }
        let plain = DocumentRecord(title: "No properties")
        let previousPlainKey = try oldKey(plain)
        #expect(DocumentPreviewContent.cacheKey(plain, children: []) == previousPlainKey)
        var inline = plain; inline.tipTapJSON = try propertyJSON(sampleProperties)
        let previousInlineKey = try oldKey(inline)
        #expect(DocumentPreviewContent.cacheKey(inline, children: []) != previousInlineKey)
        var changed = inline; var properties = sampleProperties
        properties[0].options[0].color = "#FF0000"; changed.tipTapJSON = try propertyJSON(properties)
        #expect(DocumentPreviewContent.cacheKey(inline, children: []) != DocumentPreviewContent.cacheKey(changed, children: []))
        let nested = try TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "blockquote", "content": [[
            "type": "inlineProperty", "attrs": ["property": try sampleProperties[0].bridgeObject()]
        ]]]])
        #expect(TipTapContentAnalyzer.hasInlineProperties(in: nested))
        #expect(!TipTapContentAnalyzer.hasInlineProperties(in: plain.tipTapJSON))
    }

    @Test func nativeInlinePreviewRendersColoredChipsAndWrapsAtPhoneAndTabletWidths() throws {
        guard let directory = ProcessInfo.processInfo.environment["PENNED_INLINE_PROPERTY_PREVIEW_IMAGES_DIR"] else { return }
        #if canImport(AppKit)
        _ = NSApplication.shared
        #endif
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var heights: [Int] = []
        for width: CGFloat in [320, 720] {
            let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(sampleProperties.enumerated()), id: \.offset) { _, property in
                    InlinePropertyPreview(property: property, appearance: .plain)
                }
            }.frame(width: width).background(.black).environment(\.colorScheme, .dark))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == Int(width * 2) && image.height >= 600)
            heights.append(image.height)
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
            var blue = 0, purple = 0, gold = 0
            for pixel in 0..<(image.width * image.height) {
                let i = pixel * 4, r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
                if b > 20 && b > r * 1.4 && b > g * 1.1 { blue += 1 }
                if r > 20 && b > r * 1.2 && r > g * 1.2 { purple += 1 }
                if r > 20 && r > b * 1.6 && g > b * 1.2 { gold += 1 }
            }
            #expect(blue > 20 && purple > 20 && gold > 20, "Selected option colors must be present in the first native frame")
            try DocumentPreviewImageFile.write(image, to: URL(fileURLWithPath: directory).appendingPathComponent("inline-\(Int(width)).png"))
        }
        #expect(heights[0] > heights[1], "Phone multi-select chips should wrap without overlapping following properties")
    }
}
