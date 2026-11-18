import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

struct LibraryDocumentPreview: View {
    static var phoneGalleryHeightFraction: CGFloat? {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? 0.6 : nil
        #else
        return nil
        #endif
    }

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.pennedWorkspaceTabActive) private var workspaceTabActive
    #else
    private let workspaceTabActive = true
    #endif
    let document: DocumentRecord
    var fixedAspectRatio: CGFloat?
    var showsStar = true
    var cornerRadius: CGFloat = 14
    var visibleHeightFraction: CGFloat = 1
    @State private var loadedSnapshot: CGImage?
    @State private var loadedSnapshotKey: String?
    @State private var latestDocument: DocumentRecord?
    @State private var childRevision = ""
    @State private var collectionRevision = 0

    private var current: DocumentRecord {
        let matchingRecord = latestDocument.flatMap { $0.id == document.id && $0.spaceID == document.spaceID ? $0 : nil }
        return environment.documentPreviews.content(for: matchingRecord ?? document).document
    }
    private var currentKey: String { environment.documentPreviews.presentationCacheKey(for: current, colorScheme: colorScheme) }
    private var presentationKey: String { currentKey + ":" + String(environment.documentPreviews.presentationEpoch) }
    private var availableSnapshot: CGImage? {
        if loadedSnapshotKey == presentationKey { return loadedSnapshot }
        return environment.documentPreviews.cachedPresentationImage(for: current, colorScheme: colorScheme)
    }

    private var previewActivityKey: String {
        let activity = workspaceTabActive && environment.selectedDocumentID == nil ? "active" : "inactive"
        return presentationKey + ":" + activity
    }

    private func loadVisibleSnapshot() async {
        guard workspaceTabActive, environment.selectedDocumentID == nil else { return }
        let key = presentationKey
        let record = current
        if (record.title.localizedCaseInsensitiveContains("Code Den") || record.title == "Untitled") { print("🟡 CODE-DEN-PREVIEW [gallery] snapshot lookup START title=\(record.title) id=\(record.id.prefix(8))") }
        var image = await environment.documentPreviews.loadPresentationImage(for: record, colorScheme: colorScheme)
        if (record.title.localizedCaseInsensitiveContains("Code Den") || record.title == "Untitled") { print("🟡 CODE-DEN-PREVIEW [gallery] saved lookup result=\(image == nil ? "MISS" : "HIT")") }
        if image == nil {
            // No snapshot has been persisted yet. Generate it, which renders the
            // preview AND writes the PNG to disk, so it is cached on disk for the next
            // launch. Without this the gallery only ever READS snapshots (via
            // loadPresentationImage) and nothing is written, so every launch
            // re-renders every card live. The body-free fast path is unaffected: this
            // runs only on the record fallback, for cards that have no cached preview.
            // This runs only when no document is open (guarded above by
            // selectedDocumentID == nil), so a warmed background editor must not block
            // snapshot generation — otherwise nothing is ever persisted.
            image = await environment.documentPreviews.image(for: record, colorScheme: colorScheme, ignoringActiveEditors: true)
            if (record.title.localizedCaseInsensitiveContains("Code Den") || record.title == "Untitled") { print("🟡 CODE-DEN-PREVIEW [gallery] generate result=\(image == nil ? "NIL" : "IMAGE")") }
        }
        guard !Task.isCancelled, presentationKey == key else { return }
        loadedSnapshotKey = key
        loadedSnapshot = image
    }

    var body: some View {
        let snapshot = availableSnapshot
        GeometryReader { geometry in
            if let snapshot {
                Image(decorative: snapshot, scale: 1).resizable().scaledToFill()
                    .id(presentationKey)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            } else {
                let record = current
                let width: CGFloat = record.isThemed ? 376 : 360
                let height: CGFloat = 740
                ImmediateDocumentPreview(document: record)
                    .frame(width: width, height: height, alignment: .topLeading)
                    .scaleEffect(max(geometry.size.width / width, geometry.size.height / height), anchor: .top)
                    .position(x: geometry.size.width / 2, y: height / 2)
            }
        }
        .aspectRatio((fixedAspectRatio ?? (snapshot.map { CGFloat($0.width) / CGFloat($0.height) } ?? 0.66))
            / min(1, max(0.01, visibleHeightFraction)), contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if showsStar && document.isFavorite {
                LibraryIcon(name: "starfill", size: 22).foregroundStyle(VellixSurface.gold).padding(12)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(VellixSurface.controlInk.opacity(0.08), lineWidth: 0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current.title + (document.isFavorite ? ", starred" : ""))
        .onReceive(environment.editorCache.model(for: document.id)?.$document.eraseToAnyPublisher()
            ?? Just(Optional(document)).eraseToAnyPublisher()) { record in
            latestDocument = record.flatMap { $0.updatedAt >= document.updatedAt ? $0 : nil }
        }
        .onReceive(environment.editorCache.model(for: document.id)?.$children.eraseToAnyPublisher()
            ?? Just([DocumentRecord]()).eraseToAnyPublisher()) { children in
            childRevision = children.map { $0.id + String($0.revision) + String($0.updatedAt.timeIntervalSince1970) }.joined()
        }
        .onChange(of: document) { _, record in
            latestDocument = record
        }
        .onReceive(environment.documentPreviews.$contentRevision) { collectionRevision = $0 }
        .task(id: previewActivityKey) { await loadVisibleSnapshot() }
    }

    private var requestKey: String {
        return currentKey + childRevision + String(collectionRevision)
    }
}

// A gallery cell driven by a body-free DocumentSummary. When a cached preview
// exists it is resolved and displayed from the document's descriptor alone — the
// document body is never loaded. Only when no cached preview is available is the
// full record loaded, and then the unchanged, full-fidelity LibraryDocumentPreview
// takes over (rendering ImmediateDocumentPreview and generating the snapshot). The
// cell self-heals: once the snapshot exists it drops the record and shows the image.
struct LibraryDocumentCell: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.pennedWorkspaceTabActive) private var workspaceTabActive
    #else
    private let workspaceTabActive = true
    #endif
    let summary: DocumentSummary
    var fixedAspectRatio: CGFloat?
    var showsStar = true
    var cornerRadius: CGFloat = 14
    var visibleHeightFraction: CGFloat = 1

    @State private var snapshot: CGImage?
    @State private var record: DocumentRecord?

    private var activity: String {
        (workspaceTabActive && environment.selectedDocumentID == nil) ? "active" : "inactive"
    }
    private var resolveKey: String {
        summary.id + "|" + String(summary.updatedAt.timeIntervalSince1970)
            + "|" + (colorScheme == .dark ? "d" : "l") + "|" + activity
            + "|" + String(environment.documentPreviews.contentRevision)
    }

    // The image the card paints right now. Prefers the resolved `snapshot`; before
    // `resolve()` has run it reads the cached preview synchronously (memory, then a
    // one-time disk read of a prior-launch PNG) so a persisted preview appears on the
    // card's first frame rather than after an async load. nil only when no cached
    // preview exists yet, in which case the record/live path takes over via `resolve`.
    private var resolvedPreview: CGImage? {
        snapshot ?? environment.documentPreviews.cachedPresentationImage(for: summary, colorScheme: colorScheme)
    }

    var body: some View {
        let resolvedPreview = record == nil ? self.resolvedPreview : nil
        Group {
            if let record {
                LibraryDocumentPreview(document: record, fixedAspectRatio: fixedAspectRatio, showsStar: showsStar,
                                       cornerRadius: cornerRadius, visibleHeightFraction: visibleHeightFraction)
            } else {
                GeometryReader { geometry in
                    if let resolved = resolvedPreview {
                        Image(decorative: resolved, scale: 1).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    } else {
                        LibrarySnapshotSurface(style: summary.appearance.resolved(for: colorScheme).editorBackground, photo: nil)
                    }
                }
                .aspectRatio((fixedAspectRatio ?? (resolvedPreview.map { CGFloat($0.width) / CGFloat($0.height) } ?? 0.66))
                    / min(1, max(0.01, visibleHeightFraction)), contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if showsStar && summary.isFavorite {
                        LibraryIcon(name: "starfill", size: 22).foregroundStyle(VellixSurface.gold).padding(12)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(VellixSurface.controlInk.opacity(0.08), lineWidth: 0.75)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.title + (summary.isFavorite ? ", starred" : ""))
            }
        }
        .task(id: resolveKey) { await resolve() }
    }

    private func resolve() async {
        let traced = summary.title == "Untitled" || summary.title.localizedCaseInsensitiveContains("Code Den")
        if traced { print("🟡 CODE-DEN-PREVIEW [summary] resolve ENTER title=\(summary.title) id=\(summary.id.prefix(8)) workspaceActive=\(workspaceTabActive) documentOpen=\(environment.selectedDocumentID != nil)") }
        guard workspaceTabActive, environment.selectedDocumentID == nil else { return }
        // Fast path: a cached preview resolved from the descriptor, no body load.
        if let image = environment.documentPreviews.cachedPresentationImage(for: summary, colorScheme: colorScheme) {
            if traced { print("🟡 CODE-DEN-PREVIEW [summary] memory/disk cache HIT") }
            snapshot = image; record = nil; return
        }
        if traced { print("🟡 CODE-DEN-PREVIEW [summary] immediate cache MISS; trying async disk") }
        if let image = await environment.documentPreviews.loadPresentationImage(for: summary, colorScheme: colorScheme) {
            if traced { print("🟡 CODE-DEN-PREVIEW [summary] async disk HIT") }
            guard !Task.isCancelled else { return }
            snapshot = image; record = nil; return
        }
        if traced { print("🟡 CODE-DEN-PREVIEW [summary] async disk MISS; loading full document") }
        // No cached preview: load the full record for full-fidelity rendering + snapshot generation.
        let id = summary.id
        let repository = environment.documents
        let loaded = await Task.detached(priority: .userInitiated) { try? repository.document(id: id) }.value
        if traced { print("🟡 CODE-DEN-PREVIEW [summary] record load=\(loaded == nil ? "FAILED" : "SUCCESS") cancelled=\(Task.isCancelled) loadedTitle=\(loaded?.title ?? "none")") }
        guard !Task.isCancelled, let loaded else { return }
        snapshot = nil; record = loaded
    }
}
