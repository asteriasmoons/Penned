import SwiftUI
import CoreGraphics

struct DocumentBackgroundFill: View {
    let style: DocumentBackgroundStyle
    var photo: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                surface
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(style.effect == .faded ? 0.35 : 1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }

    @ViewBuilder private var surface: some View {
        switch style.kind {
        case .none: Color.black
        case .solid: Color(vellixHex: style.colorHex)
        case .gradient:
            let direction = style.gradientDirection ?? .diagonal
            LinearGradient(colors: [Color(vellixHex: style.colorHex), Color(vellixHex: style.secondaryColorHex)],
                startPoint: direction.startPoint, endPoint: direction.endPoint)
        case .image:
            if let photo {
                Image(decorative: photo, scale: 1).resizable().scaledToFill()
                    .blur(radius: style.blurImage == true ? 12 : 0)
            } else { Color(vellixHex: style.colorHex) }
        }
    }
}

struct DocumentStyleSurface: View {
    let style: DocumentBackgroundStyle
    let store: AttachmentStore
    var theme: DocumentThemeID?

    var body: some View {
        ZStack {
            DocumentBackgroundFill(style: style, photo: style.kind == .image ? CardImageLoader.image(path: style.imagePath, store: store) : nil)
            if let theme = style.patternTheme(for: theme) {
                ThemePatternOverlay(theme: theme).opacity(style.effect == .faded ? 0.35 : 1)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black).clipped()
    }
}
