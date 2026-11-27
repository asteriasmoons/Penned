import SwiftUI

struct PageCardEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    var request: PageCardEditorRequest
    var store: AttachmentStore
    @ObservedObject var previews: DocumentPreviewCache
    var save: (PageCardStyle, Data?, Data?) async throws -> Void
    @State private var style: PageCardStyle
    @State private var pendingImage: Data?
    @State private var pendingSpineImage: Data?
    @State private var backdropTarget: CardSurfaceTarget?
    @State private var bookColorTarget: BookColorPart?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(request: PageCardEditorRequest, store: AttachmentStore, previews: DocumentPreviewCache, save: @escaping (PageCardStyle, Data?, Data?) async throws -> Void) {
        self.request = request
        self.store = store
        self.previews = previews
        self.save = save
        let style = request.document.cardStyle ?? PageCardStyle()
        _style = State(initialValue: style)
    }

    var body: some View {
        VStack(spacing: 12) {
            carousel
            stylePanel
                .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .padding(.top, 8)
        .buttonStyle(.plain)
        .pennedSheet(title: style.isBook ? "Book" : "Card", closeDisabled: isSaving, close: { dismiss() }) {
            #if os(iOS)
            if style.isBook { PennedSheetKeyboardDismissButton {} }
            #endif
            Button(isSaving ? "Saving..." : "Done") {
                isSaving = true
                Task {
                    do {
                        try await save(style,
                            style.backdrop == .photo && style.remotePhoto == nil ? pendingImage : nil,
                            style.isBook && style.spineBackdrop == .photo && style.spineRemotePhoto == nil ? pendingSpineImage : nil)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription; isSaving = false }
                }
            }.disabled(isSaving)
        }
        .interactiveDismissDisabled(isSaving)
        .sheet(item: $backdropTarget) { target in
            backdropSheet(target)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $bookColorTarget) { part in
            BookColorEditorSheet(part: part, paint: bookColor(part))
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .alert("Card", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private func backdropSheet(_ target: CardSurfaceTarget) -> some View {
        switch target {
        case .face:
            CardBackdropSheet(backdrop: $style.backdrop, startColor: $style.startColor, endColor: $style.endColor,
                imagePath: $style.imagePath, remotePhoto: $style.remotePhoto,
                textColorHex: style.textColor, title: style.isBook ? "Face" : "Backdrop",
                allowedModes: style.isBook ? [.solid, .gradient, .photo] : PageCardBackdrop.allCases,
                showsKeyboardDismiss: style.isBook) { data in pendingImage = data }
        case .spine:
            CardBackdropSheet(backdrop: $style.spineBackdrop, startColor: $style.spineStartColor, endColor: $style.spineEndColor,
                imagePath: $style.spineImagePath, remotePhoto: $style.spineRemotePhoto,
                textColorHex: "#FFFFFF", title: "Spine", allowedModes: [.solid, .gradient, .photo],
                showsKeyboardDismiss: true) { data in pendingSpineImage = data }
        }
    }

    @ViewBuilder private var carousel: some View {
        if style.isBook {
            let scale = min(1, 196 / style.renderSize.height)
            PageCardView(document: request.document, style: style, photo: currentPhoto, spinePhoto: currentSpinePhoto,
                isStylePreview: false, attachmentStore: store, previews: previews)
                .frame(width: style.renderSize.width, height: style.renderSize.height)
                .scaleEffect(scale)
                .frame(width: style.renderSize.width * scale, height: style.renderSize.height * scale)
                .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 14)
                .frame(maxWidth: .infinity, minHeight: 216)
        } else {
            sizeCarousel
        }
    }

    private var sizeCarousel: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                #if os(iOS)
                TabView(selection: $style.size) {
                    ForEach(PageCardSize.allCases) { size in
                        PageCardView(document: request.document, style: sampleStyle(size), photo: currentPhoto,
                            isStylePreview: style.previewStyle != .openPage, previews: previews)
                            .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 14)
                            .frame(width: proxy.size.width, height: 216)
                            .tag(size)
                            .accessibilityLabel(size.title)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .accessibilityIdentifier("card-size-pager")
                #else
                ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(PageCardSize.allCases) { size in
                            PageCardView(document: request.document, style: sampleStyle(size), photo: currentPhoto,
                                isStylePreview: style.previewStyle != .openPage, previews: previews)
                                .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 14)
                                .frame(width: size == .wide || size == .large ? max(318, min(350, proxy.size.width - 24)) : 250, height: 216)
                                .contentShape(Rectangle())
                                .onTapGesture { style.size = size }
                                .id(size)
                                .accessibilityLabel(size.title)
                        }
                    }
                }
                .contentMargins(.horizontal, max(0, (proxy.size.width - 250) / 2), for: .scrollContent)
                .onChange(of: style.size) { _, size in
                    withAnimation { reader.scrollTo(size, anchor: .center) }
                }
                .onAppear { reader.scrollTo(style.size, anchor: .center) }
                }
                #endif
            }.frame(height: 216)
            HStack(spacing: 7) {
                ForEach(PageCardSize.allCases) { size in
                    Button { style.size = size } label: {
                        Circle().fill(size == style.size ? VellixSurface.controlInk : VellixSurface.controlInk.opacity(0.25)).frame(width: 5, height: 5)
                            .frame(width: 26, height: 28)
                    }.buttonStyle(.plain).accessibilityLabel(size.title)
                        .accessibilityIdentifier("card-size-\(size.rawValue)")
                }
            }
        }
    }

    private var currentPhoto: CGImage? {
        guard style.backdrop == .photo, style.remotePhoto == nil else { return nil }
        if let pendingImage { return CardImageLoader.image(data: pendingImage) }
        return CardImageLoader.image(path: style.imagePath, store: store)
    }

    private var currentSpinePhoto: CGImage? {
        guard style.spineBackdrop == .photo, style.spineRemotePhoto == nil else { return nil }
        if let pendingSpineImage { return CardImageLoader.image(data: pendingSpineImage) }
        return CardImageLoader.image(path: style.spineImagePath, store: store)
    }

    private func bookColor(_ part: BookColorPart) -> Binding<BookPaint> {
        Binding(get: { style.bookPaint(part, appearance: request.document.appearance.resolved(for: colorScheme)) },
            set: { style.bookColors[part.rawValue] = $0 })
    }

    private func sampleStyle(_ size: PageCardSize) -> PageCardStyle {
        var sample = style
        sample.size = size
        return sample
    }

    private var stylePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(style.isBook ? "Book Style" : "Card Style").font(.system(size: 18, weight: .semibold))
            PennedSheetFieldDivider()
            if style.isBook {
                ScrollView {
                    BookAppearanceControls(style: $style, appearance: request.document.appearance.resolved(for: colorScheme),
                        editSurface: { backdropTarget = $0 }, editColor: { bookColorTarget = $0 })
                }.scrollIndicators(.hidden)
            } else {
                Text("PREVIEWS").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                PageCardPreviewOptions(style: $style, appearance: paperOptionAppearance)
                Text("CUSTOM BACKGROUND").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                surfaceButton("Custom", target: .face, backdrop: style.backdrop, start: style.startColor, end: style.endColor)
                if style.backdrop == .photo, let photo = style.remotePhoto { CardPhotoCredit(photo: photo) }
            }
            Spacer(minLength: 12)
        }
        .padding(18).frame(maxWidth: 550, maxHeight: .infinity, alignment: .topLeading)
        .background(VellixSurface.controlInk.opacity(0.015), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(VellixSurface.controlInk.opacity(0.10), lineWidth: 1))
    }

    private func surfaceButton(_ title: String, target: CardSurfaceTarget, backdrop: PageCardBackdrop, start: String, end: String) -> some View {
        Button { backdropTarget = target } label: {
            HStack {
                Text(title).font(.body)
                Spacer()
                ZStack {
                    LinearGradient(colors: [Color(vellixHex: start), Color(vellixHex: backdrop == .gradient ? end : start)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if backdrop == .photo { Image("imagesign").resizable().scaledToFit().padding(12) }
                }
                .frame(width: 48, height: 40).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(VellixSurface.controlInk.opacity(0.1), lineWidth: 1))
            }.foregroundStyle(.primary).padding(.horizontal, 12).frame(minHeight: 44).pennedSheetField()
        }.buttonStyle(.plain)
    }

    private var paperOptionAppearance: DocumentAppearance {
        var appearance = request.document.appearance
        appearance.innerPageBackground = .solid("#FAFAF8")
        appearance.textColorHex = "#57595D"
        return appearance
    }
}
