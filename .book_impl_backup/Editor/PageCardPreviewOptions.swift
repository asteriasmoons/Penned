import SwiftUI

struct PageCardPreviewOptions: View {
    @Binding var style: PageCardStyle
    var appearance: DocumentAppearance

    var body: some View {
        HStack(spacing: 8) {
            option(.pages)
            option(.stickyNote)
            option(.openPage)
            option(nil)
        }
    }

    private func option(_ preview: PageCardPreviewStyle?) -> some View {
        let selected = preview.map { style.showsPages && style.previewStyle == $0 } ?? !style.showsPages
        let title = preview?.title ?? "None"
        return Button {
            style.showsPages = preview != nil
            if let preview { style.previewStyle = preview }
        } label: {
            VStack(spacing: 5) {
                Group {
                    switch preview {
                    case .some(.pages):
                        NestedPageThumbnail(json: TipTapContentAnalyzer.emptyDocumentJSON, title: "Card Title", appearance: appearance,
                            size: style.size == .compact ? CGSize(width: 23, height: 30) : CGSize(width: 29, height: 38), isCardSheet: true, isStylePreview: true)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
                            .frame(width: 38, height: 38)
                            .background { if style.size == .compact { Circle().fill(VellixSurface.controlInk.opacity(0.08)) } }
                            .overlay { if style.size == .compact { Circle().stroke(VellixSurface.controlInk.opacity(0.7), lineWidth: 1) } }
                    case .some(.stickyNote):
                        StickyNotePagePreview(snapshot: nil, size: CGSize(width: 31, height: 35)).rotationEffect(.degrees(-4))
                    case .some(.openPage):
                        OpenPagePreview(snapshots: nil, size: CGSize(width: 44, height: 31),
                            paperColor: appearance.innerPageBackground.colorHex)
                    case .none:
                        Image("eyeslash").renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 24, height: 24).foregroundStyle(.secondary)
                    }
                }.frame(height: 40)
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 76)
            .pennedSheetField()
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color(vellixHex: "#2EC5F4") : VellixSurface.controlInk.opacity(0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("card-preview-" + (preview?.rawValue ?? "none"))
    }
}
