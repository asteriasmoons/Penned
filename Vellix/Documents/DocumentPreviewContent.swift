import Foundation
import CryptoKit
import SwiftUI

struct DocumentPreviewContent: Equatable {
    var document: DocumentRecord
    var children: [DocumentRecord]
    var collections: [CollectionSnapshot]

    var entryContext: (CollectionSnapshot, CollectionEntrySummary)? {
        for collection in collections {
            if let entry = collection.entries.first(where: { $0.id == document.id }) { return (collection, entry) }
        }
        return nil
    }

    var payloads: [[String: Any]] {
        let ids = TipTapContentAnalyzer.collectionIDs(in: document.tipTapJSON)
        return CollectionStore.payloads(from: collections.filter { ids.contains($0.record.id) })
    }

    var cacheKey: String { Self.cacheKey(document, children: children, collections: collections) }
    func cacheKey(for scheme: ColorScheme) -> String {
        guard ([document] + children).contains(where: { $0.appearance.isThemeDependent }) else { return cacheKey }
        return cacheKey + (scheme == .light ? "-appearance-light-v1" : "-appearance-dark-v1")
    }
    var hasResolvedCollections: Bool {
        TipTapContentAnalyzer.collectionIDs(in: document.tipTapJSON).isSubset(of: Set(collections.map { $0.record.id }))
    }

    static func cacheKey(_ document: DocumentRecord, children: [DocumentRecord], collections: [CollectionSnapshot] = []) -> String {
        func content(_ record: DocumentRecord) -> [String] {
            [record.title, record.tipTapJSON, record.appearanceJSON ?? "", record.cover ?? "", record.cardStyleJSON ?? "", record.icon ?? ""] + (record.spaceID.map { [$0] } ?? []) + (record.dailyNoteDate.map { [$0, "daily-note-presentation-v1"] } ?? [])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadata = (try? encoder.encode(collections.sorted { $0.record.id < $1.record.id })) ?? Data()
        let inlineRevision = ([document] + children).contains { TipTapContentAnalyzer.hasInlineProperties(in: $0.tipTapJSON) }
            ? ["inline-property-presentation-v1", Locale.current.identifier, TimeZone.current.identifier] : []
        let calloutRevision = ([document] + children).contains { TipTapContentAnalyzer.hasCallouts(in: $0.tipTapJSON) }
            ? ["callout-presentation-v6"] : []
        let componentRevision = ([document] + children).contains { TemplateComponentDefinition.contains(in: $0.tipTapJSON) }
            ? ["template-component-presentation-v4"] : []
        let attachmentRevision = ([document] + children).contains { !EditorAttachment.paths(in: $0.tipTapJSON).isEmpty }
            ? ["attachment-presentation-v3-video-frame"] : []
        let tagRevision = ([document] + children).contains { TipTapContentAnalyzer.hasInlineTags(in: $0.tipTapJSON) } ? ["inline-tag-presentation-v1"] : []
        let toggleRevision = ([document] + children).contains { TipTapContentAnalyzer.hasToggles(in: $0.tipTapJSON) } ? ["toggle-icon-presentation-v1"] : []
        let fontRevision = ([document] + children).contains { $0.appearance.fontStyle == .hachiMaruPop }
            ? ["hachi-font-presentation-v2"] : []
        let inputs = [["library-preview-v12-named-typography-solid-circles", metadata.base64EncodedString()] + content(document) + inlineRevision + calloutRevision + componentRevision + attachmentRevision + tagRevision + toggleRevision + fontRevision]
            + children.sorted { $0.id < $1.id }.map { [$0.id] + content($0) }
        let data = (try? encoder.encode(inputs)) ?? Data()
        return document.id + "-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension CollectionRepository {
    func previewContent(for document: DocumentRecord, documents: DocumentRepository) throws -> DocumentPreviewContent {
        let current = try documents.requireDocument(id: document.id)
        guard current.spaceID == document.spaceID else { throw VellixError.documentNotFound(document.id) }
        var children = try documents.children(of: document.id, includingCollectionEntries: false)
        let known = Set(children.map(\.id))
        for id in TipTapContentAnalyzer.pageReferenceIDs(in: document.tipTapJSON) where id != document.id && !known.contains(id) {
            if let child = try documents.document(id: id), child.spaceID == document.spaceID, !child.isTrashed, !child.isArchived { children.append(child) }
        }
        var ids = Set(try collectionIDs(forDocument: document.id))
        if let parent = try collectionID(forEntry: document.id) { ids.insert(parent) }
        return DocumentPreviewContent(document: document, children: children, collections: try ids.sorted().map { try snapshot(id: $0) })
    }
}
