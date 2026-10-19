import SwiftUI

struct PageCardEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var request: PageCardEditorRequest
    var store: AttachmentStore
    var save: (PageCardStyle, Data?) async throws -> Void
    @State private var style: PageCardStyle
    @State private var pendingImage: Data?
    @State private var showBackdrop = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(request: PageCardEditorRequest, store: AttachmentStore, save: @escaping (PageCardStyle, Data?) async throws -> Void) {
        self.request = request
        self.store = store
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
        .pennedSheet(title: "Card", closeDisabled: isSaving, close: { dismiss() }) {
            Button(isSaving ? "Saving..." : "Done") {
                isSaving = true
                Task {
                    do {
                        try await save(style, style.backdrop == .photo && style.remotePhoto == nil ? pendingImage : nil)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription; isSaving = false }
                }
            }.disabled(isSaving)
        }
        .interactiveDismissDisabled(isSaving)
        .sheet(isPresented: $showBackdrop) {
            CardBackdropSheet(style: $style) { data in pendingImage = data }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Card", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var carousel: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                #if os(iOS)
                TabView(selection: $style.size) {
                    ForEach(PageCardSize.allCases) { size in
                        PageCardView(document: request.document, style: sampleStyle(size), photo: currentPhoto, isStylePreview: true)
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
                            PageCardView(document: request.document, style: sampleStyle(size), photo: currentPhoto, isStylePreview: true)
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
                        Circle().fill(size == style.size ? Color.white : Color.white.opacity(0.25)).frame(width: 5, height: 5)
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

    private func sampleStyle(_ size: PageCardSize) -> PageCardStyle {
        var sample = style
        sample.size = size
        return sample
    }

    private var stylePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Card Style").font(.system(size: 18, weight: .semibold))
            PennedSheetFieldDivider()
            Text("PREVIEWS").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                previewOption(pages: true)
                previewOption(pages: false)
            }
            Text("CUSTOM BACKGROUND").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Button { showBackdrop = true } label: {
                HStack {
                    Text("Custom").font(.body)
                    Spacer()
                    ZStack {
                        LinearGradient(colors: [Color(vellixHex: style.startColor), Color(vellixHex: style.backdrop == .gradient ? style.endColor : style.startColor)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        if style.backdrop == .photo { Image("imagesign").resizable().scaledToFit().padding(12) }
                    }
                    .frame(width: 48, height: 40).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.1), lineWidth: 1))
                }.foregroundStyle(.primary).padding(.horizontal, 12).frame(minHeight: 44).pennedSheetField()
            }.buttonStyle(.plain)
            if style.backdrop == .photo, let photo = style.remotePhoto { CardPhotoCredit(photo: photo) }
            Spacer(minLength: 12)
        }
        .padding(18).frame(maxWidth: 550, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.015), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func previewOption(pages: Bool) -> some View {
        Button { style.showsPages = pages } label: {
            Group {
                if pages {
                    NestedPageThumbnail(json: TipTapContentAnalyzer.emptyDocumentJSON, title: "Card Title", appearance: paperOptionAppearance,
                        size: style.size == .compact ? CGSize(width: 23, height: 30) : CGSize(width: 37, height: 48), isCardSheet: true, isStylePreview: true)
                        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 2)
                        .frame(width: 38, height: 38)
                        .background { if style.size == .compact { Circle().fill(Color.white.opacity(0.08)) } }
                        .overlay { if style.size == .compact { Circle().stroke(.white.opacity(0.7), lineWidth: 1) } }
                }
                else { Image("eyeslash").renderingMode(.template).resizable().scaledToFit().frame(width: 24, height: 24).foregroundStyle(.secondary) }
            }
            .frame(width: 92, height: 66)
            .pennedSheetField()
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(pages == style.showsPages ? Color(vellixHex: "#2EC5F4") : Color.white.opacity(0.12), lineWidth: pages == style.showsPages ? 2 : 1))
        }.buttonStyle(.plain).accessibilityLabel(pages ? "Page Sheets" : "No Page Sheets")
    }

    private var paperOptionAppearance: DocumentAppearance {
        var appearance = request.document.appearance
        appearance.innerPageBackground = .solid("#FAFAF8")
        appearance.textColorHex = "#57595D"
        return appearance
    }
}
