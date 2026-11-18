import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WebKit

nonisolated enum WashiTapeSize: String, CaseIterable, Sendable {
    case thick, thin

    init(_ value: Any?) {
        self = Self(rawValue: value as? String ?? "") ?? .thick
    }

    var heightScale: CGFloat { self == .thin ? 0.75 : 1 }
}

nonisolated struct WashiTapeRequest: Equatable, Identifiable, Sendable {
    let id: String
    let imagePath: String?
    let remotePhoto: CardRemotePhoto?
    let color: String?
    let tapeSize: WashiTapeSize

    init?(payload: [String: Any]) {
        guard let id = payload["blockID"] as? String, !id.isEmpty else { return nil }
        self.id = id
        imagePath = (payload["imagePath"] as? String).flatMap { AttachmentStore.validRelativePath($0) ? $0 : nil }
        remotePhoto = Self.photo(payload["remotePhoto"])
        color = payload["color"] as? String
        tapeSize = WashiTapeSize(payload["tapeSize"])
    }

    static func photo(_ value: Any?) -> CardRemotePhoto? {
        guard let object = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object),
              let photo = try? JSONDecoder().decode(CardRemotePhoto.self, from: data), photo.validImageURL != nil else { return nil }
        return photo
    }

    @MainActor
    func commit(imagePath: String?, photo: CardRemotePhoto?, tapeSize: WashiTapeSize, in webView: WKWebView) async throws -> Any? {
        var args: [String: Any] = ["blockID": id]
        args["originalPath"] = self.imagePath
        args["originalPhotoID"] = remotePhoto?.id
        args["imagePath"] = imagePath
        args["originalTapeSize"] = self.tapeSize.rawValue
        args["tapeSize"] = tapeSize.rawValue
        if let photo { args["remotePhoto"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(photo)) }
        return try await webView.callAsyncJavaScript("return await window.tiptapCommand('washiTapeUpdate', args);",
            arguments: ["args": args], in: nil, contentWorld: .page)
    }
}

// Encode a browser-compatible, orientation-correct image without storing a full-resolution original.
nonisolated enum WashiTapeImage {
    static func prepare(_ data: Data) throws -> Data {
        guard data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800
              ] as CFDictionary) else {
            throw VellixError.attachmentImport("Choose a supported image up to 20 MB.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw VellixError.attachmentImport("The tape image could not be prepared.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VellixError.attachmentImport("The tape image could not be prepared.")
        }
        return output as Data
    }
}

struct WashiTapeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let notch = min(6, rect.height / 5, rect.width / 4)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for step in 0...10 {
            path.addLine(to: CGPoint(x: rect.maxX - (step.isMultiple(of: 2) ? 0 : notch),
                                     y: rect.minY + CGFloat(step) * rect.height / 10))
        }
        for step in (0...10).reversed() {
            path.addLine(to: CGPoint(x: rect.minX + (step.isMultiple(of: 2) ? 0 : notch),
                                     y: rect.minY + CGFloat(step) * rect.height / 10))
        }
        path.closeSubpath()
        return path
    }
}

struct WashiTapePreview: View {
    let color: Color?
    var image: CGImage?
    var photo: CardRemotePhoto?
    var tapeSize: WashiTapeSize = .thick

    static func documentImage(path: Any?, attachments: AttachmentRepository, store: AttachmentStore) -> CGImage? {
        guard let path = path as? String, let file = try? attachments.editorAttachment(relativePath: path),
              file.media.kind == .image else { return nil }
        return CardImageLoader.image(path: file.record.relativePath, store: store)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            GeometryReader { proxy in
                ZStack {
                    color ?? VellixSurface.subtleFill
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else if let url = photo?.validImageURL {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                    }
                    if image != nil || photo != nil { color?.opacity(0.38) }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(WashiTapeShape())
            }
            .frame(height: 60 * tapeSize.heightScale)
            .accessibilityLabel("Washi Tape")
            if let photo { CardPhotoCredit(photo: photo) }
        }
    }
}

struct DividerDotsPreview: View {
    let color: Color
    let customColor: Bool

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            for x in stride(from: CGFloat.zero, to: max(0, size.width - 2), by: 5) {
                dots.addEllipse(in: CGRect(x: x, y: size.height / 2 - 1, width: 2, height: 2))
            }
            context.fill(dots, with: .color(color.opacity(customColor ? 1 : 0.55)))
        }.frame(height: 20).accessibilityHidden(true)
    }
}

struct WashiTapeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    let request: WashiTapeRequest
    let store: AttachmentStore
    let onSave: (String?, CardRemotePhoto?, Data?, WashiTapeSize) async throws -> Void
    @State private var imagePath: String?
    @State private var photo: CardRemotePhoto?
    @State private var tapeSize: WashiTapeSize
    @State private var data: Data?
    @State private var image: CGImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var search = false
    @State private var busy = false
    @State private var error: String?

    init(request: WashiTapeRequest, store: AttachmentStore,
         onSave: @escaping (String?, CardRemotePhoto?, Data?, WashiTapeSize) async throws -> Void) {
        self.request = request
        self.store = store
        self.onSave = onSave
        _imagePath = State(initialValue: request.imagePath)
        _photo = State(initialValue: request.remotePhoto)
        _tapeSize = State(initialValue: request.tapeSize)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                WashiTapePreview(color: request.color.map { Color(vellixHex: $0) },
                    image: image ?? WashiTapePreview.documentImage(path: imagePath, attachments: environment.attachments, store: store),
                    photo: photo, tapeSize: tapeSize)
                HStack(spacing: 12) {
                    Text("Size").accessibilityHidden(true)
                    Picker("Size", selection: $tapeSize) {
                        Text("Thick").tag(WashiTapeSize.thick)
                        Text("Thin").tag(WashiTapeSize.thin)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                Button { search = true } label: { source("Search Unsplash", icon: "searchwavy") }
                    .buttonStyle(.plain)
                PhotosPicker(selection: $photoItem, matching: .images) { source("Photo Library", icon: "imagesign") }
                    .buttonStyle(.plain)
                Button { showFiles = true } label: { source("Choose File", icon: "folderhand") }
                    .buttonStyle(.plain)
                if imagePath != nil || photo != nil || data != nil {
                    Button("Remove Image", role: .destructive) { imagePath = nil; photo = nil; data = nil; image = nil }
                }
                if busy { ProgressView() }
            }.padding(18)
        }
        .disabled(busy)
        .pennedSheet(title: "Washi Tape", closeDisabled: busy, close: { dismiss() }) {
            #if os(iOS)
            PennedSheetKeyboardDismissButton {}.disabled(busy)
            #endif
            Button("Done", action: save).disabled(busy)
        }
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $search) {
            CardPhotoSearchSheet { selected in
                photo = selected; imagePath = nil; data = nil; image = nil
            }
            #if os(macOS)
            .frame(width: 520, height: 560)
            #endif
        }
        .task(id: photoItem) {
            guard let photoItem else { return }
            await load {
                guard let bytes = try await photoItem.loadTransferable(type: Data.self) else {
                    throw VellixError.attachmentImport("The photo could not be loaded.")
                }
                return bytes
            }
            self.photoItem = nil
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            Task {
                await load {
                    guard let url = try result.get().first else { throw CancellationError() }
                    return try await Task.detached(priority: .userInitiated) {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        return try Data(contentsOf: url, options: .mappedIfSafe)
                    }.value
                }
            }
        }
        .alert("Washi Tape", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func source(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            LibraryIcon(name: icon, size: 18)
            Text(title)
            Spacer()
        }.foregroundStyle(.primary).padding(12).pennedSheetField()
    }

    private func load(_ bytes: () async throws -> Data) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let input = try await bytes()
            let prepared = try await Task.detached(priority: .userInitiated) { try WashiTapeImage.prepare(input) }.value
            try Task.checkCancellation()
            image = CardImageLoader.image(data: prepared)
            data = prepared
            imagePath = nil
            photo = nil
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await onSave(imagePath, photo, data, tapeSize)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
