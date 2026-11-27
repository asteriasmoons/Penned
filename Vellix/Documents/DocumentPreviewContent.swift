import Foundation
import CryptoKit
import SwiftUI

// The minimal surface the preview cache key needs from a document: cheap metadata
// plus the derived appearance/card style. Both the body-bearing DocumentRecord and
// the body-free DocumentSummary conform, so the identical key can be produced from
// a record (the snapshot generator) or a summary (the gallery), given a descriptor
// for each document to stand in for the JSON-derived facts.
protocol DocumentPreviewSubject {
    var id: String { get }
    var title: String { get }
    var appearanceJSON: String? { get }
    var cover: String? { get }
    var cardStyleJSON: String? { get }
    var icon: String? { get }
    var spaceID: String? { get }
    var dailyNoteDate: String? { get }
    var appearance: DocumentAppearance { get }
    var cardStyle: PageCardStyle? { get }
}

extension DocumentRecord: DocumentPreviewSubject {}
extension DocumentSummary: DocumentPreviewSubject {}

struct DocumentPreviewContent: Equatable {
    var document: DocumentRecord
    var children: [DocumentRecord]
    var collections: [CollectionSnapshot]
    var cardPreviewKeys: [String: String] = [:]

    // The preview-cache version token embedded in every preview cache key. Changing
    // it invalidates all cached previews, which then regenerate lazily on demand.
    static let previewCacheVersion = "library-preview-v19-block-coverage"

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

    var cacheKey: String {
        Self.cacheKey(document, children: children, descriptors: Self.descriptors(for: [document] + children),
                      collections: collections, cardPreviewKeys: cardPreviewKeys)
    }

    // Descriptors computed directly from records, for the snapshot-generator path.
    // These equal the stored descriptors the gallery reads from the database, so the
    // two paths produce byte-identical keys.
    static func descriptors(for records: [DocumentRecord]) -> [String: DocumentPreviewDescriptor] {
        var map: [String: DocumentPreviewDescriptor] = [:]
        for record in records { map[record.id] = DocumentPreviewDescriptorIndex.descriptor(for: record) }
        return map
    }
    func cacheKey(for scheme: ColorScheme) -> String {
        guard !cardPreviewKeys.isEmpty || ([document] + children).contains(where: { $0.appearance.isThemeDependent }) else { return cacheKey }
        return cacheKey + (scheme == .light ? "-appearance-light-v1" : "-appearance-dark-v1")
    }
    var hasResolvedCollections: Bool {
        TipTapContentAnalyzer.collectionIDs(in: document.tipTapJSON).isSubset(of: Set(collections.map { $0.record.id }))
    }

    // Record-based convenience: computes descriptors from the records, so every
    // existing caller that passes DocumentRecords keeps working unchanged. It is
    // unambiguous against the descriptor-taking overload because that one requires a
    // `descriptors:` argument this one omits.
    static func cacheKey(_ document: DocumentRecord, children: [DocumentRecord],
                         collections: [CollectionSnapshot] = [], cardPreviewKeys: [String: String] = [:]) -> String {
        cacheKey(document, children: children, descriptors: descriptors(for: [document] + children),
                 collections: collections, cardPreviewKeys: cardPreviewKeys)
    }

    // Produces the preview cache key from descriptors instead of re-scanning the
    // document bodies. Every token string and the input ordering are preserved from
    // the previous JSON-scanning implementation; the ONLY substantive change is that
    // a document's `tipTapJSON` is replaced by its descriptor `contentHash`, and each
    // former `TipTapContentAnalyzer.hasX(in:)` / string-contains test is replaced by
    // the matching descriptor feature flag. Because a descriptor computed from a
    // record equals the one stored for it, the record path (generator) and the
    // summary path (gallery) yield identical keys. The version token is bumped so the
    // one-time format change cleanly regenerates existing cached previews.
    static func cacheKey(_ document: any DocumentPreviewSubject, children: [any DocumentPreviewSubject],
                         descriptors: [String: DocumentPreviewDescriptor],
                         collections: [CollectionSnapshot] = [], cardPreviewKeys: [String: String] = [:]) -> String {
        func content(_ record: any DocumentPreviewSubject) -> [String] {
            [record.title, descriptors[record.id]?.contentHash ?? "", record.appearanceJSON ?? "", record.cover ?? "", record.cardStyleJSON ?? "", record.icon ?? ""] + (record.spaceID.map { [$0] } ?? []) + (record.dailyNoteDate.map { [$0, "daily-note-presentation-v1"] } ?? [])
        }
        func has(_ subject: any DocumentPreviewSubject, _ feature: DocumentPreviewDescriptor.Features) -> Bool {
            descriptors[subject.id]?.features.contains(feature) ?? false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadata = (try? encoder.encode(collections.sorted { $0.record.id < $1.record.id })) ?? Data()
        let inlineRevision = ([document] + children).contains { has($0, .inlineProperties) }
            ? ["inline-property-presentation-v1", Locale.current.identifier, TimeZone.current.identifier] : []
        let calloutRevision = ([document] + children).contains { has($0, .callouts) }
            ? ["callout-presentation-v8-disclosure-alpha-mask"] : []
        let listGridRevision = ([document] + children).contains { has($0, .listGrids) }
            ? ["list-grid-preview-v2-borderless-fill"] : []
        let codeBlockRevision = ([document] + children).contains { has($0, .codeBlock) }
            ? ["code-block-monospaced-view-v2"] : []
        let gridCardRevision = ([document] + children).contains { has($0, .gridCards) }
            ? ["grid-card-presentation-v1"] : []
        let headingLabelRevision = ([document] + children).contains { has($0, .headingLabel) }
            ? ["heading-label-presentation-v5-tinted-grain-and-glass-highlight"] : []
        let texturedLabelRevision = ([document] + children).contains { has($0, .texturedLabel) }
            ? ["heading-label-tone-on-tone-grain-v1"] : []
        let decorativeLabelRevision = ([document] + children).contains { has($0, .decorativeLabel) }
            ? ["heading-label-decorative-perimeter-v4"] : []
        let tableRevision = ([document] + children).contains { has($0, .table) }
            ? ["table-presentation-v1"] : []
        let blockquoteRevision = ([document] + children).contains { has($0, .blockquote) }
            ? ["blockquote-presentation-v1"] : []
        let informationCardRevision = ([document] + children).contains { has($0, .informationCard) }
            ? ["information-card-presentation-v1"] : []
        let richLinkRevision = ([document] + children).contains { has($0, .richLink) }
            ? ["rich-link-presentation-v1"] : []
        let blockRevisions = [listGridRevision, codeBlockRevision, gridCardRevision, headingLabelRevision, decorativeLabelRevision, texturedLabelRevision,
                              tableRevision, blockquoteRevision, informationCardRevision, richLinkRevision]
            .filter { !$0.isEmpty }
        let tabsRevision = ([document] + children).contains { has($0, .tabs) }
            ? ["tabs-preview-v1"] : []
        let minimalFieldsRevision = ([document] + children).contains { has($0, .minimalFields) }
            ? ["minimal-fields-preview-v1"] : []
        let stickyRevision = ([document] + children).contains { $0.cardStyle?.previewStyle == .stickyNote }
            ? ["sticky-content-preview-v1"] : []
        let openPageRevision = ([document] + children).contains { $0.cardStyle?.previewStyle == .openPage }
            ? ["open-page-flow-preview-v2-visible-snapshots"] : []
        let cardTitleRevision = ([document] + children).contains { $0.cardStyle?.showsPages == true }
            ? ["card-miniature-no-title-v1", "card-paper-depth-v1"] : []
        let bookRevision = ([document] + children).contains { $0.cardStyle?.isBook == true }
            ? ["book-presentation-v10-adaptive-description"] : []
        let dividerRevision = ([document] + children).contains { has($0, .fourDotDivider) }
            ? ["four-dot-presentation-v3-4px"] : []
        let componentRevision = ([document] + children).contains { has($0, .templateComponent) }
            ? ["template-component-presentation-v4"] : []
        let attachmentRevision = ([document] + children).contains { has($0, .attachment) }
            ? ["attachment-presentation-v3-video-frame"] : []
        let tagRevision = ([document] + children).contains { has($0, .inlineTags) } ? ["inline-tag-presentation-v1"] : []
        let toggleRevision = ([document] + children).contains { has($0, .toggles) } ? ["toggle-icon-presentation-v1"] : []
        let collectionIconRevision = !collections.isEmpty ? ["collection-icon-snapshot-v1"] : []
        let fontRevision = ([document] + children).contains { $0.appearance.fontStyle == .hachiMaruPop }
            ? ["hachi-font-presentation-v2"] : []
        let sourceRevision = ([document] + children).contains { has($0, .clipSources) }
            ? ["clip-source-presentation-v1", String(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)] : []
        let inputs = [[previewCacheVersion, metadata.base64EncodedString()] + cardPreviewKeys.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] } + content(document) + inlineRevision + calloutRevision + stickyRevision + openPageRevision + cardTitleRevision + bookRevision + dividerRevision + componentRevision + attachmentRevision + tagRevision + toggleRevision + collectionIconRevision + fontRevision + sourceRevision]
            + blockRevisions
            + (tabsRevision.isEmpty ? [] : [tabsRevision])
            + (minimalFieldsRevision.isEmpty ? [] : [minimalFieldsRevision])
            + children.sorted { $0.id < $1.id }.map { [$0.id] + content($0) }
        let data = (try? encoder.encode(inputs)) ?? Data()
        return document.id + "-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension CollectionRepository {
    func previewContent(for document: DocumentRecord, documents: DocumentRepository, includeCardPreviews: Bool = true,
                        cardDepth: Int = 0, ancestors: Set<String> = []) throws -> DocumentPreviewContent {
        let current = try documents.requireDocument(id: document.id)
        guard current.spaceID == document.spaceID else { throw VellixError.documentNotFound(document.id) }
        var children = try documents.children(of: document.id, includingCollectionEntries: false)
        let known = Set(children.map(\.id))
        for id in TipTapContentAnalyzer.pageReferenceIDs(in: current.tipTapJSON) where id != document.id && !known.contains(id) {
            if let child = try documents.document(id: id), child.spaceID == document.spaceID, !child.isTrashed, !child.isArchived { children.append(child) }
        }
        var ids = Set(try collectionIDs(forDocument: document.id))
        if let parent = try collectionID(forEntry: document.id) { ids.insert(parent) }
        var cardKeys: [String: String] = [:]
        let visited = ancestors.union([document.id])
        if includeCardPreviews && cardDepth < 3 {
            for child in children where child.cardStyle.map({ $0.isBook || $0.showsPages }) == true && !visited.contains(child.id) {
                cardKeys[child.id] = try previewContent(for: child, documents: documents, cardDepth: cardDepth + 1, ancestors: visited).cacheKey
            }
        }
        return DocumentPreviewContent(document: document, children: children, collections: try ids.sorted().map { try snapshot(id: $0) }, cardPreviewKeys: cardKeys)
    }
}

// Raised when a descriptor needed to build a summary's preview key is missing or
// stale. The caller then falls back to the body-bearing record path, which is
// always correct, so a not-yet-reconciled document is never shown a wrong preview.
enum PreviewKeyResolutionError: Error { case missingDescriptor }

extension CollectionRepository {
    // The descriptor-based preview key for a body-free summary. Mirrors
    // `previewContent(for:documents:)` + `DocumentPreviewContent.cacheKey(for:)`
    // exactly — same children set, same collection snapshots, same nested-card
    // recursion, same scheme suffix — so it yields the identical key the snapshot
    // generator produced from the full record. Throws if any required descriptor is
    // missing, so the caller can fall back to the record path.
    func presentationCacheKey(forSummary summary: DocumentSummary, documents: DocumentRepository, colorScheme: ColorScheme) throws -> String {
        let resolved = try resolveSummaryKeyInputs(summary, documents: documents, cardDepth: 0, ancestors: [])
        let base = DocumentPreviewContent.cacheKey(summary, children: resolved.children, descriptors: resolved.descriptors,
                                                   collections: resolved.collections, cardPreviewKeys: resolved.cardKeys)
        guard !resolved.cardKeys.isEmpty || ([summary] + resolved.children).contains(where: { $0.appearance.isThemeDependent }) else { return base }
        return base + (colorScheme == .light ? "-appearance-light-v1" : "-appearance-dark-v1")
    }

    private func resolveSummaryKeyInputs(_ summary: DocumentSummary, documents: DocumentRepository, cardDepth: Int, ancestors: Set<String>)
        throws -> (children: [DocumentSummary], collections: [CollectionSnapshot], cardKeys: [String: String], descriptors: [String: DocumentPreviewDescriptor]) {
        guard let descriptor = try documents.previewDescriptor(id: summary.id) else { throw PreviewKeyResolutionError.missingDescriptor }
        var descriptors: [String: DocumentPreviewDescriptor] = [summary.id: descriptor]
        var children = try documents.childrenSummaries(of: summary.id, includingCollectionEntries: false)
        let known = Set(children.map(\.id))
        for id in descriptor.pageReferenceIDs where id != summary.id && !known.contains(id) {
            if let child = try documents.summary(id: id), child.spaceID == summary.spaceID, !child.isTrashed, !child.isArchived { children.append(child) }
        }
        for child in children where descriptors[child.id] == nil {
            guard let childDescriptor = try documents.previewDescriptor(id: child.id) else { throw PreviewKeyResolutionError.missingDescriptor }
            descriptors[child.id] = childDescriptor
        }
        var ids = Set(try collectionIDs(forDocument: summary.id, referencedCollectionIDs: descriptor.collectionIDs))
        if let parent = try collectionID(forEntry: summary.id) { ids.insert(parent) }
        var cardKeys: [String: String] = [:]
        let visited = ancestors.union([summary.id])
        if cardDepth < 3 {
            for child in children where child.cardStyle.map({ $0.isBook || $0.showsPages }) == true && !visited.contains(child.id) {
                // Nested card keys use the base key (no scheme suffix), as the record path does.
                let nested = try resolveSummaryKeyInputs(child, documents: documents, cardDepth: cardDepth + 1, ancestors: visited)
                cardKeys[child.id] = DocumentPreviewContent.cacheKey(child, children: nested.children, descriptors: nested.descriptors,
                                                                     collections: nested.collections, cardPreviewKeys: nested.cardKeys)
            }
        }
        return (children, try ids.sorted().map { try snapshot(id: $0) }, cardKeys, descriptors)
    }
}
