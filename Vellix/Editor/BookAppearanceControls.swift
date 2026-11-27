import SwiftUI

struct BookAppearanceControls: View {
    @Binding var style: PageCardStyle
    let appearance: DocumentAppearance
    let editSurface: (CardSurfaceTarget) -> Void
    let editColor: (BookColorPart) -> Void

    var body: some View {
        VStack(spacing: 10) {
            surface("Face", target: .face, mode: style.backdrop, start: style.startColor, end: style.endColor)
            surface("Spine", target: .spine, mode: style.spineBackdrop, start: style.spineStartColor, end: style.spineEndColor)
            ForEach(BookColorPart.allCases) { part in
                Button { editColor(part) } label: {
                    row(part.title) {
                        RoundedRectangle(cornerRadius: 8).fill(style.bookPaint(part, appearance: appearance).fill)
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    private func surface(_ title: String, target: CardSurfaceTarget, mode: PageCardBackdrop, start: String, end: String) -> some View {
        Button { editSurface(target) } label: {
            row(title) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Color(vellixHex: start), Color(vellixHex: mode == .gradient ? end : start)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay { if mode == .photo { LibraryIcon(name: "imagesign", size: 20) } }
            }
        }.buttonStyle(.plain)
    }

    private func row<Swatch: View>(_ title: String, @ViewBuilder swatch: () -> Swatch) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            swatch().frame(width: 48, height: 36)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(VellixSurface.controlInk.opacity(0.15)) }
        }.foregroundStyle(.primary).padding(.horizontal, 12).frame(minHeight: 52).pennedSheetField()
    }
}

struct BookColorEditorSheet: View {
    let part: BookColorPart
    @Binding var paint: BookPaint

    var body: some View {
        CardBackdropSheet(backdrop: $paint.mode, startColor: $paint.startColor, endColor: $paint.endColor,
            imagePath: .constant(nil), remotePhoto: .constant(nil), textColorHex: "#FFFFFF", title: part.title,
            allowedModes: [.solid, .gradient], opacity: $paint.opacity, showsKeyboardDismiss: true) { _ in }
    }
}
