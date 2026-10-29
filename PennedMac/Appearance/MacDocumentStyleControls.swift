// Mac-target platform adapter. Based on Vellix/Editor/DocumentStyleSheet.swift.
// iPhone/iPad implementations remain in their original target.
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private enum DocumentStylePanel: String, Identifiable {
    case overview, font, cover, backdrop, styles
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Page Style"
        case .font: return "Font"
        case .cover: return "Choose an Image"
        case .backdrop: return "Backdrop"
        case .styles: return "Style Gallery"
        }
    }
}

private enum DocumentStyleColor: String, Identifiable {
    case text, paper, start, end
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: return "Text Color"
        case .paper: return "Paper"
        case .start: return "Start Color"
        case .end: return "End Color"
        }
    }
}

struct DocumentStyleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var environment: AppEnvironment
    let documentID: String
    let onChange: (DocumentStyleDefinition) -> Void
    @State private var definition: DocumentStyleDefinition
    private let initial: DocumentStyleDefinition
    @State private var panel: DocumentStylePanel = .overview
    @State private var colorTarget: DocumentStyleColor?
    @State private var styles: [SavedDocumentStyle] = []
    @State private var search = ""
    @State private var saving = false
    @State private var styleName = ""
    @State private var renameTarget: SavedDocumentStyle?
    @State private var deleteTarget: SavedDocumentStyle?
    @State private var errorMessage: String?
    @State private var photos: [CardRemotePhoto] = []
    @State private var showPhotoSearch = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var importTask: Task<Void, Never>?
    @State private var importToken = UUID()
    @State private var photoRequest = UUID()
    @State private var importing = false

    init(documentID: String, definition: DocumentStyleDefinition, startWithCover: Bool = false,
         onChange: @escaping (DocumentStyleDefinition) -> Void) {
        self.documentID = documentID
        self.initial = definition
        self._definition = State(initialValue: definition)
        self.onChange = onChange
        self._panel = State(initialValue: startWithCover ? .cover : .overview)
    }

    private let accent = PennedSheetStyle.accent
    private let solids = ["#FFD6A8", "#FFC700", "#559EFA", "#2545B6", "#07BBA8", "#075442",
                          "#007994", "#FF7300", "#C00016", "#FFC6C7", "#C6B0F7"]
    private let gradients = [
        ["#68D9BA", "#DFE9A7"], ["#D6F5BE", "#FFC5D3"], ["#E1ECF5", "#768992"],
        ["#E3AF98", "#B2DEDB"], ["#9B91F1", "#FAC4D5"], ["#E7CDA3", "#F5D4A7"],
        ["#E6C5BD", "#7267B4"], ["#AEF4D3", "#F0AB9C"], ["#CDBFE5", "#FABAC7"],
        ["#606C9B", "#B0C5CB"], ["#FFE28B", "#F9B493"], ["#349BCB", "#DAEDF4"]
    ]

    private var currentMatch: SavedDocumentStyle? {
        try? environment.documentStyles.matchingStyle(definition, in: styles)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch panel {
            case .overview:
                ScrollView {
                    overview.frame(height: 3 * 116 + 2 * 8)
                }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
            case .font: fontOptions
            case .cover: imageOptions
            case .backdrop: backdropOptions
            case .styles: styleGallery
            }
        }
        .padding(16)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(VellixSurface.controlInk)
        .pennedSheet(title: panel == .font ? nil : panel.title, close: { dismiss() }) {
            if panel != .overview {
                Button("Back") { panel = .overview }
                if panel != .styles { Button("Reset") { resetPanel() } }
            } else if currentMatch == nil {
                Button("Save") { styleName = ""; saving = true }.disabled(importing)
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .onChange(of: definition) { _, value in onChange(value) }
        .onAppear { reloadStyles() }
        .onDisappear { cancelImport(); photoRequest = UUID() }
        .task(id: panel) {
            if panel == .cover || (panel == .backdrop && definition.appearance.editorBackground.kind == .image) {
                if photos.isEmpty { await loadPhotos() }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            let isCover = panel == .cover
            startImport(isCover: isCover) { try await item.loadTransferable(type: Data.self) }
            photoItem = nil
        }
        .sheet(item: $colorTarget) { target in
            CardThreeModeColorPicker(selection: colorBinding(target), title: target.title)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showPhotoSearch) {
            let isCover = panel == .cover
            CardPhotoSearchSheet { photo in selectPhoto(photo, isCover: isCover) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
            let isCover = panel == .cover
            switch result {
            case .success(let url):
                startImport(isCover: isCover) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        #if os(iOS)
        .background {
            StyleNameAlert(title: "Save Style", isPresented: $saving, name: $styleName) { name in
                styleName = name
                saveStyle()
            }.frame(width: 0, height: 0)
            StyleNameAlert(title: "Rename Style", isPresented: Binding(
                get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }
            ), name: $styleName) { [target = renameTarget] name in
                guard let target else { return }
                perform { try environment.documentStyles.rename(target, title: name); reloadStyles() }
            }.frame(width: 0, height: 0)
        }
        #else
        .macAlert("Save Style", isPresented: $saving) {
            TextField("Style name", text: $styleName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveStyle() }
                .disabled(styleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .macAlert("Rename Style", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Style name", text: $styleName)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                guard let target = renameTarget else { return }
                perform { try environment.documentStyles.rename(target, title: styleName); reloadStyles() }
                renameTarget = nil
            }.disabled(styleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        #endif
        .macConfirmationDialog("Delete Style?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete Style", role: .destructive) {
                guard let target = deleteTarget else { return }
                perform {
                    defer { reloadStyles() }
                    try environment.documentStyles.delete(target)
                }
                deleteTarget = nil
            }
        } message: { Text("Documents using this style will not change.") }
        .macAlert("Page Style", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var detents: Set<PresentationDetent> {
        switch panel {
        case .overview: return [.height(480)]
        case .font: return [.height(170)]
        case .cover: return [.height(480), .large]
        case .backdrop:
            switch definition.appearance.editorBackground.kind {
            case .none: return [.height(240)]
            case .solid: return [.height(390)]
            case .gradient: return [.height(550)]
            case .image: return [.height(640), .large]
            }
        case .styles: return [.fraction(0.75), .large]
        }
    }

    private var overview: some View {
        GeometryReader { geometry in
            let unit = max(70, (geometry.size.width - 16) / 3)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    styleTile(title: "Text Color", width: unit) {
                        VStack {
                            Text("Text Color").font(.system(size: 19, weight: .bold, design: .rounded))
                            LibraryIcon(name: "paintdrop", size: 46)
                        }.foregroundStyle(Color(vellixHex: definition.appearance.resolved(for: colorScheme).textColorHex))
                    } action: { colorTarget = .text }
                    styleTile(title: "Font", width: unit * 2 + 8) {
                        VStack(spacing: 4) {
                            Text(definition.appearance.fontStyle.title)
                                .font(definition.appearance.fontStyle.font(size: 32, weight: .black))
                            Text("Font").foregroundStyle(.secondary)
                        }
                    } action: { panel = .font }
                }
                HStack(spacing: 8) {
                    styleTile(title: "Cover", width: unit) {
                        VStack(spacing: 4) {
                            coverArtwork.frame(height: 70).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                            Text("Cover").font(.subheadline)
                        }.padding(8)
                    } action: { panel = .cover }
                    styleTile(title: "Backdrop", width: unit) {
                        backdropTilePreview
                    } action: { panel = .backdrop }
                    styleTile(title: "Paper", width: unit) {
                        ZStack(alignment: .topLeading) {
                            DocumentStyleSurface(style: definition.appearance.resolved(for: colorScheme).innerPageBackground, store: environment.attachmentStore)
                            Text("Paper").foregroundStyle(Color(vellixHex: definition.appearance.resolved(for: colorScheme).textColorHex))
                                .font(.subheadline.weight(.semibold)).padding(10)
                        }
                    } action: { colorTarget = .paper }
                }
                styleTile(title: "Styles", width: geometry.size.width) {
                    HStack {
                        Text("Styles").font(.headline).padding(.leading, 12)
                        Spacer()
                        ZStack {
                            ForEach(Array(styles.prefix(3).enumerated()), id: \.element.id) { index, style in
                                if let value = try? style.definition() {
                                    DocumentStyleThumbnail(title: style.title, definition: value, store: environment.attachmentStore)
                                        .frame(width: 74, height: 95)
                                        .rotationEffect(.degrees(Double(index - 1) * 9))
                                        .offset(x: CGFloat(index - 1) * 26, y: 10)
                                }
                            }
                        }.frame(width: 175, height: 110)
                    }
                } action: { panel = .styles }
            }
        }
    }

    private func styleTile<Content: View>(title: String, width: CGFloat,
        @ViewBuilder content: () -> Content, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content().frame(width: width, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .pennedSheetField()
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private var fontOptions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DocumentFontStyle.allCases) { font in
                    let selected = definition.appearance.fontStyle == font
                    Button { definition.appearance.fontStyle = font } label: {
                        HStack(spacing: 8) {
                            Text(font.sample).font(font.font(size: 21, weight: .medium))
                            if selected { Text(font.title).font(.system(size: 18, weight: .medium, design: .rounded)) }
                        }
                        .padding(.horizontal, selected ? 12 : 0)
                        .frame(minWidth: 48, minHeight: 48)
                        .foregroundStyle(selected ? accent : VellixSurface.controlInk.opacity(0.8))
                        .background(selected ? accent.opacity(0.09) : .clear, in: Capsule())
                        .pennedSheetField(cornerRadius: 24)
                    }.buttonStyle(.plain).accessibilityLabel(font.title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var backdropOptions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backdropModes
                switch definition.appearance.editorBackground.kind {
                case .none: EmptyView()
                case .solid: solidPalette
                case .gradient:
                    gradientPalette
                    Text("GRADIENT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    colorRow("Start Color", target: .start, hex: definition.appearance.editorBackground.colorHex)
                    colorRow("End Color", target: .end, hex: definition.appearance.editorBackground.secondaryColorHex)
                    HStack {
                        Text("Direction")
                        Spacer()
                        MacGradientDirectionControl(selection: Binding(
                            get: { definition.appearance.editorBackground.gradientDirection ?? .diagonal },
                            set: { customizeBackdrop(); definition.appearance.editorBackground.gradientDirection = $0 }
                        ), start: Color(vellixHex: definition.appearance.editorBackground.colorHex), end: Color(vellixHex: definition.appearance.editorBackground.secondaryColorHex))
                    }.padding(12).pennedSheetField()
                case .image:
                    photoGrid
                    imageCommands
                    if let photo = definition.appearance.editorBackground.remotePhoto { CardPhotoCredit(photo: photo, compact: false) }
                    Text("EFFECTS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Toggle("Blur Image", isOn: Binding(
                        get: { definition.appearance.editorBackground.blurImage ?? false },
                        set: { customizeBackdrop(); definition.appearance.editorBackground.blurImage = $0 }
                    )).tint(accent).padding(12).pennedSheetField()
                }
                if definition.appearance.editorBackground.kind != .none {
                    if definition.appearance.editorBackground.kind != .image {
                        Text("EFFECT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        ForEach(DocumentBackdropEffect.allCases) { effect in
                            let selected = (definition.appearance.editorBackground.effect ?? .immersive) == effect
                            Button { customizeBackdrop(); definition.appearance.editorBackground.effect = effect } label: {
                                Text(effect.title).font(.headline).frame(maxWidth: .infinity).frame(height: 44)
                                    .foregroundStyle(selected ? accent : VellixSurface.controlInk.opacity(0.7))
                                    .background(selected ? accent.opacity(0.10) : .clear, in: Capsule())
                                    .pennedSheetField(cornerRadius: 22)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(.bottom, 8)
        }.scrollIndicators(.hidden)
    }

    private var backdropModes: some View {
        HStack(spacing: 0) {
            ForEach(DocumentBackgroundKind.allCases) { kind in
                let selected = definition.appearance.editorBackground.kind == kind
                Button {
                    cancelImport()
                    customizeBackdrop()
                    definition.appearance.editorBackground.kind = kind
                    if kind == .image && photos.isEmpty { Task { await loadPhotos() } }
                } label: {
                    LibraryIcon(name: modeIcon(kind), size: 23)
                        .foregroundStyle(Color(vellixHex: definition.appearance.textColorHex))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(selected ? VellixSurface.activeTab : .clear, in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel(kind.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(3).pennedSheetField(cornerRadius: 24)
    }

    private func modeIcon(_ kind: DocumentBackgroundKind) -> String {
        switch kind {
        case .none: return "eyeslash"
        case .solid: return "paintdrop"
        case .gradient: return "colorpicker"
        case .image: return "imagesign"
        }
    }

    private var solidPalette: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
            ForEach(solids, id: \.self) { hex in
                Button { customizeBackdrop(); definition.appearance.editorBackground.colorHex = hex } label: {
                    swatch(selected: definition.appearance.editorBackground.colorHex.uppercased() == hex) {
                        Color(vellixHex: hex)
                    }
                }.buttonStyle(.plain).accessibilityLabel("Backdrop \(hex)")
            }
            Button { colorTarget = .start } label: {
                ZStack {
                    AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)
                    Circle().fill(Color(vellixHex: definition.appearance.editorBackground.colorHex)).padding(4)
                    LibraryIcon(name: "chevdown", size: 16).foregroundStyle(.black.opacity(0.6))
                }.aspectRatio(1, contentMode: .fit).clipShape(Circle())
            }.buttonStyle(.plain).accessibilityLabel("Custom Backdrop Color")
        }
    }

    private var gradientPalette: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
            ForEach(gradients, id: \.self) { pair in
                let selected = definition.appearance.editorBackground.colorHex == pair[0]
                    && definition.appearance.editorBackground.secondaryColorHex == pair[1]
                Button {
                    customizeBackdrop()
                    definition.appearance.editorBackground.colorHex = pair[0]
                    definition.appearance.editorBackground.secondaryColorHex = pair[1]
                    definition.appearance.editorBackground.gradientDirection = .topToBottom
                } label: {
                    swatch(selected: selected) {
                        LinearGradient(colors: pair.map { Color(vellixHex: $0) }, startPoint: .leading, endPoint: .trailing)
                    }
                }.buttonStyle(.plain).accessibilityLabel("Gradient \(pair.joined(separator: " to "))")
            }
        }
    }

    private func swatch<Content: View>(selected: Bool, @ViewBuilder content: () -> Content) -> some View {
        content().aspectRatio(1, contentMode: .fit).clipShape(Circle())
            .overlay(Circle().strokeBorder(selected ? accent : VellixSurface.controlInk.opacity(0.08), lineWidth: selected ? 3 : 1))
            .padding(3)
            .overlay(Circle().stroke(selected ? accent.opacity(0.7) : .clear, lineWidth: 2))
    }

    private func colorRow(_ title: String, target: DocumentStyleColor, hex: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { colorTarget = target } label: {
                RoundedRectangle(cornerRadius: 8).fill(Color(vellixHex: hex)).frame(width: 50, height: 42)
            }.buttonStyle(.plain).accessibilityLabel(title)
        }.padding(.horizontal, 12).pennedSheetField()
    }

    private var imageOptions: some View {
        ScrollView {
            VStack(spacing: 12) {
                imageCommands
                photoGrid
                if let photo = definition.appearance.coverPhoto { CardPhotoCredit(photo: photo, compact: false) }
                Button {
                    cancelImport()
                    definition.cover = nil
                    definition.appearance.coverPhoto = nil
                    definition.appearance.showsCover = false
                } label: {
                    HStack(spacing: 12) {
                        LibraryIcon(name: "xmarkwavy")
                        Text("Remove")
                        Spacer()
                    }.padding(12).pennedSheetField()
                }.buttonStyle(.plain).disabled(!definition.appearance.displaysCover)
            }
        }.scrollIndicators(.hidden)
    }

    private var imageCommands: some View {
        HStack(spacing: 6) {
            imageCommand("Shuffle", icon: "repeat") { Task { await loadPhotos(shuffle: true) } }
            imageCommand("Unsplash", icon: "imagesign") { showPhotoSearch = true }
            VStack(spacing: 6) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    VStack(spacing: 8) {
                        LibraryIcon(name: "imagesign", size: 25)
                        Text("Photo Library").font(.caption)
                    }.frame(maxWidth: .infinity).frame(height: 65)
                }.buttonStyle(.plain)
                Button("Files") { showFileImporter = true }.font(.caption).buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity).frame(height: 88)
            .pennedSheetField()
        }.disabled(importing)
    }

    private func imageCommand(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                LibraryIcon(name: icon, size: 26)
                Text(title).font(.subheadline)
            }.frame(maxWidth: .infinity).frame(height: 88)
                .pennedSheetField()
        }.buttonStyle(.plain)
    }

    private var photoGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 8) {
            if currentImagePath != nil || (panel == .cover && definition.appearance.displaysCover) {
                VStack(spacing: 3) {
                    Group {
                        if panel == .cover { coverArtwork }
                        else { backdropSurface }
                    }.frame(height: 78).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent, lineWidth: 2))
                    Text("Current").font(.caption2).foregroundStyle(accent)
                }
            }
            ForEach(photos.prefix(6)) { photo in
                VStack(spacing: 3) {
                    Button { selectPhoto(photo, isCover: panel == .cover) } label: {
                        GeometryReader { geometry in
                            AsyncImage(url: URL(string: photo.thumbURL)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: { VellixSurface.controlInk.opacity(0.04) }
                            .frame(width: geometry.size.width, height: 78).clipped()
                        }.frame(height: 78).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(importing)
                        .accessibilityLabel("Select image by \(photo.photographer)")
                    CardPhotoCredit(photo: photo, compact: true).lineLimit(1)
                }
            }
        }
    }

    private var currentImagePath: String? {
        panel == .cover ? definition.cover : definition.appearance.editorBackground.imagePath
    }

    @ViewBuilder private var coverArtwork: some View {
        if let image = CardImageLoader.image(path: definition.cover, store: environment.attachmentStore), definition.appearance.displaysCover {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else if definition.appearance.displaysCover {
            ThemeCoverArt(theme: definition.appearance.resolvedCoverTheme)
        } else {
            Color.black.overlay { LibraryIcon(name: "imagesign", size: 28).foregroundStyle(.secondary) }
        }
    }

    private var backdropSurface: some View {
        DocumentStyleSurface(style: definition.appearance.resolved(for: colorScheme).editorBackground, store: environment.attachmentStore,
            theme: definition.appearance.themeID)
    }

    private var backdropTilePreview: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if definition.appearance.editorBackground.kind == .none {
                    VellixSurface.previewPlaceholder
                    LibraryIcon(name: modeIcon(.none), size: 30).foregroundStyle(VellixSurface.controlInk.opacity(0.5))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    backdropSurface.frame(width: geometry.size.width, height: geometry.size.height)
                }
                Text("Backdrop").font(.subheadline.weight(.semibold)).padding(10)
                    .foregroundStyle(definition.appearance.editorBackground.kind == .none ? VellixSurface.controlInk
                        : Color(vellixHex: definition.appearance.resolved(for: colorScheme).textColorHex))
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(VellixSurface.previewPlaceholder)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VellixSurface.controlInk.opacity(0.08), lineWidth: 1))
        }
    }

    private var styleGallery: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LibraryIcon(name: "searchwavy").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }.padding(12).pennedSheetField()
                .padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        cancelImport()
                        definition = DocumentStyleDefinition(appearance: .plain)
                    } label: {
                        HStack {
                            Text("Default Appearance")
                            Spacer()
                            if definition.appearance == .plain { LibraryIcon(name: "checkwavy", size: 20) }
                        }.padding(14).pennedSheetField()
                    }.buttonStyle(.plain).foregroundStyle(accent)
                        .accessibilityLabel("Use default application appearance")
                    Text("YOUR STYLES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                        ForEach(styles.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { style in
                            if let value = try? style.definition() {
                                galleryItem(style, definition: value)
                            }
                        }
                    }
                }.padding(.bottom, 12)
            }.scrollIndicators(.hidden)
        }
    }

    private func galleryItem(_ style: SavedDocumentStyle, definition value: DocumentStyleDefinition) -> some View {
        let selected = currentMatch?.id == style.id
        return Button {
            guard !selected else { return }
            cancelImport()
            perform {
                // One state assignment applies cover, font, paper, text and backdrop together.
                definition = try environment.documentStyles.apply(style, to: documentID)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                DocumentStyleThumbnail(title: style.title, definition: value, store: environment.attachmentStore)
                    .aspectRatio(0.9, contentMode: .fit)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? accent : .clear, lineWidth: 2))
                Text(style.title).font(.subheadline).foregroundStyle(selected ? accent : VellixSurface.controlInk.opacity(0.65))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                if !style.isBuiltIn {
                    Button("Rename") { styleName = style.title; renameTarget = style }
                    Button("Delete", role: .destructive) { deleteTarget = style }
                }
            }
    }

    private func colorBinding(_ target: DocumentStyleColor) -> Binding<Color> {
        Binding(get: {
            let appearance = definition.appearance
            switch target {
            case .text: return Color(vellixHex: appearance.textColorHex)
            case .paper: return Color(vellixHex: appearance.innerPageBackground.colorHex)
            case .start: return Color(vellixHex: appearance.editorBackground.colorHex)
            case .end: return Color(vellixHex: appearance.editorBackground.secondaryColorHex)
            }
        }, set: { color in
            let hex = color.vellixHexString(fallback: "#FFFFFF")
            switch target {
            case .text:
                definition.appearance.markCustomized(.text)
                definition.appearance.textColorHex = hex
            case .paper:
                definition.appearance.enableCustomLayout()
                definition.appearance.innerPageBackground = .solid(hex)
            case .start:
                customizeBackdrop()
                definition.appearance.editorBackground.colorHex = hex
            case .end:
                customizeBackdrop()
                definition.appearance.editorBackground.secondaryColorHex = hex
            }
        })
    }

    private func resetPanel() {
        cancelImport()
        switch panel {
        case .font: definition.appearance.fontStyle = initial.appearance.fontStyle
        case .cover:
            definition.cover = initial.cover
            definition.appearance.showsCover = initial.appearance.showsCover
            definition.appearance.coverPhoto = initial.appearance.coverPhoto
            definition.appearance.coverThemeID = initial.appearance.coverThemeID
        case .backdrop:
            definition.appearance.editorBackground = initial.appearance.editorBackground
            let needsCustomPaper = definition.appearance.innerPageBackground != initial.appearance.innerPageBackground
            let needsCustomCover = definition.appearance.displaysCover && !initial.appearance.displaysCover
            definition.appearance.themeID = initial.appearance.themeID
                ?? (needsCustomPaper || needsCustomCover ? .custom : nil)
        case .overview, .styles: break
        }
    }

    private func reloadStyles() { perform { styles = try environment.documentStyles.all() } }
    private func customizeBackdrop() {
        definition.appearance.customizeBackdrop()
    }
    private func saveStyle() {
        perform {
            try environment.documentStyles.save(title: styleName, definition: definition)
            reloadStyles()
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    private func loadPhotos(shuffle: Bool = false) async {
        let token = UUID()
        photoRequest = token
        do {
            let result = try await CardPhotoService().search(shuffle: shuffle)
            guard !Task.isCancelled, photoRequest == token else { return }
            photos = result.photos
        } catch {
            if !Task.isCancelled && photoRequest == token { errorMessage = error.localizedDescription }
        }
    }

    private func selectPhoto(_ photo: CardRemotePhoto, isCover: Bool) {
        guard let url = photo.validImageURL else { return }
        startImport(isCover: isCover, photo: photo) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw VellixError.attachmentImport("This photo could not be downloaded.")
            }
            try await CardPhotoService().trackSelection(photo)
            return data
        }
    }

    private func cancelImport() {
        importTask?.cancel()
        importToken = UUID()
        importing = false
    }

    private func startImport(isCover: Bool, photo: CardRemotePhoto? = nil,
                             load: @escaping () async throws -> Data?) {
        cancelImport()
        let token = UUID()
        importToken = token
        importing = true
        importTask = Task { @MainActor in
            defer { if importToken == token { importing = false } }
            do {
                guard let data = try await load(), !Task.isCancelled, importToken == token else { return }
                let file = try environment.documentStyles.importImage(data, documentID: documentID)
                definition.appearance.enableCustomLayout()
                if isCover {
                    definition.cover = file.relativePath
                    definition.appearance.showsCover = true
                    definition.appearance.coverPhoto = photo
                } else {
                    customizeBackdrop()
                    var background = definition.appearance.editorBackground
                    background.kind = .image
                    background.imagePath = file.relativePath
                    background.remotePhoto = photo
                    definition.appearance.editorBackground = background
                }
            } catch {
                if !Task.isCancelled && importToken == token { errorMessage = error.localizedDescription }
            }
        }
    }
}

struct DocumentStyleThumbnail: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let definition: DocumentStyleDefinition
    let store: AttachmentStore

    var body: some View {
        let appearance = definition.appearance.resolved(for: colorScheme)
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let pageWidth = width * 0.46
            let pageHeight = height * 0.60
            let inset = max(5, width * 0.045)
            let contentWidth = max(1, pageWidth - inset * 2)
            ZStack {
                DocumentStyleSurface(style: appearance.editorBackground, store: store,
                    theme: appearance.themeID)
                VStack(alignment: .leading, spacing: 7) {
                    if definition.appearance.displaysCover {
                        Group {
                            if let image = CardImageLoader.image(path: definition.cover, store: store) {
                                Image(decorative: image, scale: 1).resizable().scaledToFill()
                            } else { ThemeCoverArt(theme: definition.appearance.resolvedCoverTheme) }
                        }.frame(width: contentWidth, height: height * 0.15)
                            .clipped().clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text(title).font(appearance.fontStyle.font(size: width > 120 ? 14 : 8, weight: .black))
                        .foregroundStyle(Color(vellixHex: appearance.textColorHex))
                        .lineLimit(4).minimumScaleFactor(0.75)
                        .frame(width: contentWidth, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .padding(inset)
                .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
                .background {
                    DocumentStyleSurface(style: appearance.innerPageBackground, store: store)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(VellixSurface.controlInk.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 2)
            }.frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
