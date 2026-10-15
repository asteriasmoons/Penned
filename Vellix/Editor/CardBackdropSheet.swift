import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct CardBackdropSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var style: PageCardStyle
    var imageSelected: (Data) -> Void
    @State private var colorTarget: CardColorTarget?
    @State private var photoItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var showUnsplash = false
    @State private var photos: [CardRemotePhoto] = []
    @State private var loading = false
    @State private var errorMessage: String?
    private let palette = ["#FFD6A8", "#FFC700", "#559EFA", "#2545B6", "#07BBA8", "#075442", "#007994", "#FF7300", "#C00016", "#FFC6C7", "#C6B0F7"]
    private let gradients = [("#68D9BA", "#DFE9A7"), ("#D6F5BE", "#FFC5D3"), ("#E1ECF5", "#768992"), ("#E3AF98", "#B2DEDB"), ("#9B91F1", "#FAC4D5"), ("#E7CDA3", "#F5D4A7"), ("#E6C5BD", "#7267B4"), ("#AEF4D3", "#F0AB9C"), ("#CDBFE5", "#FABAC7"), ("#606C9B", "#B0C5CB"), ("#FFE28B", "#F9B493"), ("#349BCB", "#DAEDF4")]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Backdrop").font(.system(size: 19, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image("xmarkwavy").renderingMode(.template).resizable().scaledToFit().frame(width: 18, height: 18).frame(width: 36, height: 36) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close Backdrop")
            }
            Divider()
            modes
            ScrollView {
                switch style.backdrop {
                case .none: EmptyView()
                case .solid: solidColors
                case .gradient: gradientColors
                case .photo: photoOptions
                }
            }.scrollIndicators(.hidden)
        }
        .padding(18).frame(maxWidth: 550, maxHeight: .infinity, alignment: .topLeading)
        .background(VellixSurface.paperLifted)
        .sheet(item: $colorTarget) { target in
            CardThreeModeColorPicker(selection: colorBinding(target), title: target == .start && style.backdrop != .gradient ? "Select Color" : target.title)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showUnsplash) {
            CardPhotoSearchSheet { photo in select(photo) }
        }
        .task(id: photoItem) {
            guard let photoItem else { return }
            do {
                guard let data = try await photoItem.loadTransferable(type: Data.self), !Task.isCancelled else { return }
                try select(data)
            } catch { errorMessage = error.localizedDescription }
        }
        .task(id: style.backdrop) { if style.backdrop == .photo && photos.isEmpty { await loadPhotos() } }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            Task {
                do {
                    guard let url = try result.get().first else { return }
                    let data = try await Task.detached(priority: .userInitiated) {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        return try Data(contentsOf: url, options: .mappedIfSafe)
                    }.value
                    try select(data)
                } catch { errorMessage = error.localizedDescription }
            }
        }
        .alert("Card Background", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var modes: some View {
        HStack(spacing: 0) {
            ForEach(PageCardBackdrop.allCases) { mode in
                Button { style.backdrop = mode } label: {
                    Group {
                        switch mode {
                        case .none: Image("eyeslash").renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20)
                        case .photo: Image("imagesign").renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20)
                        case .solid: RoundedRectangle(cornerRadius: 3).fill(Color(vellixHex: style.startColor)).frame(width: 17, height: 17).overlay(RoundedRectangle(cornerRadius: 3).stroke(.white, lineWidth: 1))
                        case .gradient: RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [Color(vellixHex: style.startColor), Color(vellixHex: style.endColor)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 17, height: 17).overlay(RoundedRectangle(cornerRadius: 3).stroke(.white, lineWidth: 1))
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background(mode == style.backdrop ? Color.black : Color.clear, in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel(mode.title)
            }
        }.padding(3).background(Color.white.opacity(0.12), in: Capsule())
    }

    private var solidColors: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
            ForEach(palette, id: \.self) { hex in
                Button { style.startColor = hex } label: {
                    Circle().fill(Color(vellixHex: hex)).frame(width: 36, height: 36)
                        .overlay(Circle().stroke(style.startColor == hex ? .white : .clear, lineWidth: 2).padding(-3))
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Color \(hex)")
            }
            Button { colorTarget = .start } label: {
                Circle().fill(Color(vellixHex: style.startColor)).frame(width: 36, height: 36)
                    .overlay(Circle().stroke(AngularGradient(colors: [.pink, .yellow, .green, .cyan, .blue, .purple, .pink], center: .center), lineWidth: 3))
                    .overlay(Image("colorpicker").renderingMode(.template).resizable().scaledToFit().frame(width: 14, height: 14).foregroundStyle(Color(vellixHex: style.textColor)))
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("Custom Color")
        }
    }

    private var gradientColors: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                ForEach(gradients.indices, id: \.self) { index in
                    let colors = gradients[index]
                    Button { style.startColor = colors.0; style.endColor = colors.1 } label: {
                        Circle().fill(LinearGradient(colors: [Color(vellixHex: colors.0), Color(vellixHex: colors.1)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(style.startColor == colors.0 && style.endColor == colors.1 ? .white : .clear, lineWidth: 2).padding(-3))
                            .frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Gradient \(index + 1)")
                }
            }
            Text("GRADIENT").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            colorRow(.start)
            colorRow(.end)
        }
    }

    private func colorRow(_ target: CardColorTarget) -> some View {
        Button { colorTarget = target } label: {
            HStack {
                Text(target.title)
                Spacer()
                RoundedRectangle(cornerRadius: 9).fill(Color(vellixHex: target == .start ? style.startColor : style.endColor)).frame(width: 48, height: 40)
            }.foregroundStyle(.primary)
        }.buttonStyle(.plain)
    }

    private var photoOptions: some View {
        VStack(spacing: 10) {
            if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 44) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(photos) { photo in
                    VStack(alignment: .leading, spacing: 4) {
                        Button { select(photo) } label: {
                            GeometryReader { proxy in
                                AsyncImage(url: URL(string: photo.thumbURL)) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.05) }
                                    .frame(width: proxy.size.width, height: 72).clipped()
                            }.frame(height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.remotePhoto?.id == photo.id ? Color(vellixHex: "#2EC5F4") : .clear, lineWidth: 2))
                        }.buttonStyle(.plain).accessibilityLabel("Photo by \(photo.photographer)")
                        CardPhotoCredit(photo: photo, compact: true)
                    }
                }
            }
            HStack(spacing: 8) {
                sourceButton("Shuffle", asset: "repeatarrows") { Task { await loadPhotos(shuffle: true) } }
                sourceButton("Unsplash", asset: "searchwavy") { showUnsplash = true }
                PhotosPicker(selection: $photoItem, matching: .images) { sourceLabel("Photo Library", asset: "imagesign") }.buttonStyle(.plain)
                sourceButton("Files", asset: "folderhand") { showFiles = true }
            }
            if let photo = style.remotePhoto { CardPhotoCredit(photo: photo) }
        }
    }

    private func sourceButton(_ title: String, asset: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { sourceLabel(title, asset: asset) }.buttonStyle(.plain).disabled(loading && title == "Shuffle")
    }
    private func sourceLabel(_ title: String, asset: String) -> some View {
        VStack(spacing: 8) {
            Image(asset).renderingMode(.template).resizable().scaledToFit().frame(width: 18, height: 18)
            Text(title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    private func colorBinding(_ target: CardColorTarget) -> Binding<Color> {
        Binding(get: { Color(vellixHex: target == .start ? style.startColor : style.endColor) }, set: {
            if target == .start { style.startColor = $0.vellixHexString(fallback: style.startColor) }
            else { style.endColor = $0.vellixHexString(fallback: style.endColor) }
        })
    }
    private func select(_ photo: CardRemotePhoto) { style.remotePhoto = photo; style.imagePath = nil; style.backdrop = .photo }
    private func select(_ data: Data) throws {
        guard CardImageLoader.image(data: data) != nil else { throw NSError(domain: "VellixCard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a supported image up to 20 MB."]) }
        style.remotePhoto = nil; style.imagePath = nil; style.backdrop = .photo
        imageSelected(data)
    }
    private func loadPhotos(shuffle: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            let result = try await CardPhotoService().search(shuffle: shuffle)
            guard !Task.isCancelled else { return }
            photos = result.photos
        }
        catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}

enum CardColorTarget: String, Identifiable {
    case start, end
    var id: String { rawValue }
    var title: String { self == .start ? "Start Color" : "End Color" }
}

struct CardPhotoCredit: View {
    var photo: CardRemotePhoto
    var compact = false
    @ViewBuilder
    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 2) {
                Link(photo.photographer, destination: creditURL(photo.photographerURL))
                Link("Unsplash", destination: creditURL(photo.sourceURL))
            }.font(.system(size: 9)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 4) {
                Text("Photo by").foregroundStyle(.secondary)
                Link(photo.photographer, destination: creditURL(photo.photographerURL))
                Text("on").foregroundStyle(.secondary)
                Link("Unsplash", destination: creditURL(photo.sourceURL))
            }.font(.caption2).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func creditURL(_ value: String) -> URL {
        guard let url = URL(string: value), url.scheme == "https", url.host == "unsplash.com" else {
            return URL(string: "https://unsplash.com/?utm_source=vellix&utm_medium=referral")!
        }
        return url
    }
}
