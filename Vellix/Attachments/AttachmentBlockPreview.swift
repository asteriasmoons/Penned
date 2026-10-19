import SwiftUI
import ImageIO

struct AttachmentBlockPreview: View {
    let file: EditorAttachment
    let attrs: [String: Any]
    let store: AttachmentStore

    private var mode: String { attrs["displayMode"] as? String ?? "auto" }
    private var image: CGImage? {
        guard let url = try? store.validatedFileURL(relativePath: file.record.relativePath) else { return nil }
        if file.media.kind == .pdf, let data = try? store.previewPNG(relativePath: file.record.relativePath, pdf: true),
           let source = CGImageSourceCreateWithData(data as CFData, nil) { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        if let image = CardImageLoader.image(path: url.lastPathComponent, store: store) { return image }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
             kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) { return image }
        return CardImageLoader.image(path: file.record.thumbnailRelativePath, store: store)
    }

    var body: some View {
        if mode != "card", file.media.kind == .image, let image {
            AttachmentImagePreviewLayout(natural: CGSize(width: file.media.width ?? image.width, height: file.media.height ?? image.height),
                widthPercent: attrs["widthPercent"] as? Double, full: mode == "fullWidth", alignment: attrs["textAlign"] as? String ?? "left") {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            }
        } else if mode != "card", file.media.kind == .audio {
            audioPill
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if mode != "card", (file.media.kind == .pdf || file.media.kind == .video), let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxHeight: 180)
                }
                HStack(spacing: 8) {
                    if mode != "card", file.media.kind == .audio || file.media.kind == .video {
                        LibraryIcon(name: "play", size: 14)
                    } else { Text(file.media.typeLabel(fileName: file.record.originalFileName)).font(.system(size: 10, weight: .bold)) }
                    Text(file.record.originalFileName).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.18), lineWidth: 1))
            }
        }
    }

    private var audioPill: some View {
        HStack(spacing: 8) {
            LibraryIcon(name: "play", size: 22)
                .foregroundStyle(Color(vellixHex: "#24162e"))
                .frame(width: 44, height: 44)
                .background(Color(vellixHex: "#e7b9ef"), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text((file.record.originalFileName as NSString).deletingPathExtension)
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text("0:00 / --:--").font(.system(size: 11)).monospacedDigit().opacity(0.8).fixedSize()
                    Capsule().fill(Color(vellixHex: "#b59ad9").opacity(0.3)).frame(height: 5)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            LibraryIcon(name: "sf:speaker.wave.2.fill", size: 20).frame(width: 32, height: 44)
            LibraryIcon(name: "ellipsis", size: 20).frame(width: 32, height: 32)
                .background(Color(vellixHex: "#b59ad9").opacity(0.12), in: Circle())
        }
        .padding(12)
        .frame(minHeight: 76)
        .background(LinearGradient(colors: [Color(vellixHex: "#efabd9").opacity(0.11), Color(vellixHex: "#b59ad9").opacity(0.12)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color(vellixHex: "#b59ad9").opacity(0.45), lineWidth: 1))
    }
}

private struct AttachmentImagePreviewLayout: Layout {
    let natural: CGSize
    let widthPercent: Double?
    let full: Bool
    let alignment: String

    private func imageSize(_ width: CGFloat) -> CGSize {
        let fraction = widthPercent.map { min(100, max(10, $0)) / 100 }
        let fitted = full ? width : fraction.map { width * $0 } ?? min(width, natural.width)
        return CGSize(width: fitted, height: fitted * natural.height / max(1, natural.width))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? natural.width)
        return CGSize(width: width, height: imageSize(width).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let image = subviews.first else { return }
        let size = imageSize(bounds.width)
        let x = alignment == "right" ? bounds.maxX - size.width : alignment == "center" ? bounds.midX - size.width / 2 : bounds.minX
        image.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
    }
}
