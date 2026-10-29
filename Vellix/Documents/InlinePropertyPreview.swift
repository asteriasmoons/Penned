import SwiftUI

// Mirrors the inline-property node's presentation without mounting an editor.
struct InlinePropertyPreview: View {
    let property: InlinePropertyDefinition
    let appearance: DocumentAppearance
    private var secondary: Color { Color(vellixHex: appearance.presentationColors.secondary) }
    private var accent: Color { Color(vellixHex: appearance.presentationColors.accent) }

    var body: some View {
        InlinePropertyPreviewRowLayout {
            Text(property.name.isEmpty ? "Property name" : property.name)
                .fontWeight(.bold).foregroundStyle(Color(vellixHex: appearance.textColorHex))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            value.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .font(appearance.fontStyle.font(size: 13))
        .dynamicTypeSize(.medium)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var value: some View {
        if !property.hasDisplayValue {
            Text(property.emptyCaption).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            switch property.kind {
            case .select, .multiSelect:
                CollectionChipLayout(spacing: 6) {
                    ForEach(property.selectedOptions) { option in
                        let color = Color(vellixHex: option.color)
                        Text(option.name).fontWeight(.medium).foregroundStyle(color)
                            .frame(minHeight: 18.2)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(color.opacity(0.16), in: Capsule())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .date:
                HStack(spacing: 8) {
                    LibraryIcon(name: "numcal", size: 14)
                    Text(property.displayValue()).fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(secondary)
            case .checkbox:
                let fill = Color(vellixHex: "#2ECBFF")
                Circle().fill(property.checked ? fill : .clear)
                    .overlay(Circle().strokeBorder(property.checked ? fill : Color(vellixHex: appearance.textColorHex).opacity(0.45), lineWidth: 2))
                    .overlay {
                        if property.checked { LibraryIcon(name: "checkwavy", size: 16).foregroundStyle(.white) }
                    }
                    .frame(width: 22, height: 22).accessibilityLabel(property.displayValue())
            case .number:
                Text(property.displayValue()).fontWeight(.medium).monospacedDigit().foregroundStyle(accent)
                    .frame(minHeight: 19.5)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .fixedSize(horizontal: false, vertical: true)
            case .url:
                HStack(spacing: 8) {
                    Text(property.displayValue()).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                    if InlinePropertyDefinition.safeURL(property.value) != nil { LibraryIcon(name: "link", size: 11) }
                }.frame(minHeight: 18.2).foregroundStyle(accent).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            case .text:
                Text(property.value).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
            }
        }
    }
}

private struct InlinePropertyPreviewRowLayout: Layout {
    private func widths(_ width: CGFloat) -> (CGFloat, CGFloat) {
        let available = max(0, width - 14)
        return (available * 0.43, available * 0.57)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320, columns = widths(width)
        guard subviews.count == 2 else { return .zero }
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: columns.0, height: nil))
        let value = subviews[1].sizeThatFits(ProposedViewSize(width: columns.1, height: nil))
        return CGSize(width: width, height: max(44, label.height, value.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let columns = widths(bounds.width)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: columns.0, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX + columns.0 + 14, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: columns.1, height: nil))
    }
}
