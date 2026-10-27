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
    let document: DocumentRecord
    var fixedAspectRatio: CGFloat?
    var showsStar = true
    var cornerRadius: CGFloat = 14
    var visibleHeightFraction: CGFloat = 1
    @State private var presentation = DocumentPreviewPresentation()
    @State private var latestDocument: DocumentRecord?
    @State private var childRevision = ""
    @State private var collectionRevision = 0

    private var current: DocumentRecord { latestDocument ?? document }
    private var currentKey: String { environment.documentPreviews.content(for: current).cacheKey(for: colorScheme) }
    private var presentationKey: String { currentKey + ":" + String(environment.documentPreviews.presentationEpoch) }
    private var availableSnapshot: CGImage? {
        if presentation.key == presentationKey, let image = presentation.image { return image }
        return preparedImage()
    }

    private func preparedImage() -> CGImage? {
        environment.documentPreviews.presentationImage(for: current, colorScheme: colorScheme) {
            let renderer = ImageRenderer(content: ImmediateDocumentPreview(document: current)
                .environmentObject(environment).environment(\.colorScheme, colorScheme)
                .frame(width: current.isThemed ? 376 : 360, height: 740, alignment: .topLeading))
            renderer.scale = 2
            return renderer.cgImage
        }
    }

    private func preparePresentation() {
        presentation.prepare(key: presentationKey) { preparedImage() }
    }

    var body: some View {
        GeometryReader { geometry in
            if let snapshot = availableSnapshot {
                Image(decorative: snapshot, scale: 1).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
        }
        .aspectRatio((fixedAspectRatio ?? (availableSnapshot.map { CGFloat($0.width) / CGFloat($0.height) } ?? 0.66))
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
            if record.updatedAt >= current.updatedAt { latestDocument = record }
        }
        .onReceive(environment.documentPreviews.$contentRevision) { collectionRevision = $0 }
        .onAppear { preparePresentation() }
        .onChange(of: presentationKey) { _, _ in preparePresentation() }
        .task(id: requestKey) {
            // Persist the next accurate rendering without changing an already-visible frame.
            _ = await environment.documentPreviews.image(for: current, colorScheme: colorScheme)
        }
    }

    private var requestKey: String {
        return currentKey + childRevision + String(collectionRevision)
    }
}
