#if os(iOS)
import SwiftUI

struct SelectionStyleSheet: View {
    @ObservedObject var session: TipTapEditorSession
    let documentFont: DocumentFontStyle
    let selectionTarget: String
    let dismiss: () -> Void
    @State private var panel = Panel.main
    @GestureState private var pull: CGFloat = 0

    private enum Panel { case main, textStyles, formatting }

    private enum TextStyle: String {
        case heading1, heading2, heading3, heading4, paragraph, caption

        var level: Int? {
            switch self {
            case .heading1: 1
            case .heading2: 2
            case .heading3: 3
            case .heading4: 4
            case .paragraph, .caption: nil
            }
        }

        var title: String {
            if let level { return DocumentTextStyleNames.heading(level) }
            return self == .caption ? "Caption" : "Paragraph"
        }

        var font: Font {
            switch self {
            case .heading1: .system(size: 19, weight: .bold, design: .rounded)
            case .heading2: .system(size: 17, weight: .semibold, design: .rounded)
            case .heading3: .system(size: 16, weight: .bold, design: .rounded)
            case .heading4: .system(size: 15, weight: .semibold, design: .rounded)
            case .paragraph: .system(size: 15, design: .rounded)
            case .caption: .system(size: 13, design: .rounded)
            }
        }
    }

    private var style: TipTapSelectedBlocksStyle? { session.formattingState.selectedBlocksStyle }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(VellixSurface.controlInk.opacity(0.24))
                .frame(width: 32, height: 4)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(grabberDrag)
                .accessibilityHidden(true)
            Group {
                switch panel {
                case .main: mainPanel
                case .textStyles: textStylesPanel
                case .formatting: formattingPanel
                }
            }
            .disabled(style?.target != selectionTarget || !session.isReady || session.isLoadingDocument)
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: 480)
        .foregroundStyle(VellixSurface.controlInk)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).strokeBorder(VellixSurface.controlInk.opacity(0.14), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: VellixSurface.elevationShadow(opacity: 0.35), radius: 16, y: 4)
        .offset(y: pull * 0.75)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panel == .main ? "Style" : panel == .textStyles ? "Heading and paragraph styles" : "Additional formatting")
        .accessibilityAction(.escape, stepDown)
    }

    private var grabberDrag: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($pull) { drag, value, _ in
                if drag.translation.height > abs(drag.translation.width) { value = drag.translation.height }
            }
            .onEnded { drag in
                let distance = drag.translation.height
                guard distance > max(22, abs(drag.translation.width)),
                      distance > 46 || drag.predictedEndTranslation.height > 86 else { return }
                stepDown()
            }
    }

    private func show(_ next: Panel) {
        withAnimation(.easeInOut(duration: 0.18)) { panel = next }
    }

    private func stepDown() {
        if panel == .main { dismiss() }
        else { show(.main) }
    }

    private var mainPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                textStyle(.heading3)
                textStyle(.paragraph)
                Button {
                    show(.textStyles)
                } label: {
                    Text("More\u{2026}").font(.system(size: 16, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(selectionTile(selected: false, filled: true)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(VellixSurface.secondaryControlInk(opacity: 0.75))
                .accessibilityHint("Shows all heading and paragraph styles")
            }
            HStack(spacing: 5) {
                list("Checklist", asset: "checklist", type: "taskList", command: "checkListItem")
                list("Bullet List", asset: "bulletlist", type: "bulletList", command: "bulletListItem")
                list("Numbered List", asset: "numberlist", type: "orderedList", command: "numberedListItem")
                icon("Outdent", asset: "outdent", filled: true) { format("outdent") }
                icon("Indent", asset: "indent", filled: true) { format("indent") }
            }
            HStack(spacing: 6) {
                conversionControl
                if style?.canColorDivider == true {
                    ColorPicker("Divider Color", selection: Binding(get: {
                        style?.dividerColor.map { Color(vellixHex: $0) } ?? VellixSurface.controlInk
                    }, set: { color in
                        format("dividerColor", value: color.vellixHexString(fallback: "#FFFFFF"))
                    }), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 50, height: 50)
                    .background(selectionTile(selected: false, filled: true))
                }
                Button {
                    show(.formatting)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold))
                        .frame(width: 52, height: 50)
                        .background(selectionTile(selected: false, filled: true)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Additional formatting")
            }
        }
    }

    private var textStylesPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                textStyle(.heading1, height: 54)
                textStyle(.heading2, height: 54)
                textStyle(.heading3, height: 54)
            }
            Divider()
            HStack(spacing: 5) {
                textStyle(.heading4, height: 54)
                textStyle(.paragraph, height: 54)
                textStyle(.caption, height: 54)
            }
            if style?.canLabel == true {
                HStack(spacing: 6) {
                    Button("Text") { format("headingPresentation", value: "text") }
                    Button("Label") { format("headingPresentation", value: "label") }
                }.buttonStyle(.bordered)
            }
            conversionControl
        }
    }

    private var formattingPanel: some View {
        VStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        markButtons(filled: false)
                        Divider().frame(height: 24).padding(.horizontal, 2)
                        alignmentButtons(filled: false)
                    }.fixedSize(horizontal: true, vertical: false)
                    fontButtons
                    conversionControl
                }
                VStack(spacing: 6) {
                    markButtons(filled: true)
                    fontButtons
                    alignmentButtons(filled: true)
                }
            }
        }
    }

    private var conversionControl: some View {
        EditorTextConversionMenu(session: session, showsTitle: true, blockSelection: true, selectionTarget: selectionTarget)
            .padding(.horizontal, 12)
            .frame(height: 50)
            .background(selectionTile(selected: false, filled: true))
    }

    private var fontButtons: some View {
        HStack(spacing: 6) {
            font(.system, label: "System")
            font(.serif, label: "Serif")
            font(.mono, label: "Mono")
            font(.rounded, label: "Round")
        }
    }

    private func font(_ choice: DocumentFontStyle, label: String) -> some View {
        let selected = style?.font == "inherit" ? documentFont == choice : style?.font == choice.rawValue
        return Button {
            format("font", value: choice.rawValue)
        } label: {
            VStack(spacing: 5) {
                Text(choice.sample).font(choice.font(size: 21, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(VellixSurface.secondaryControlInk(opacity: 0.75))
            }
            .frame(maxWidth: .infinity).frame(height: 70)
            .background(selectionTile(selected: selected, filled: true)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func markButtons(filled: Bool) -> some View {
        HStack(spacing: filled ? 6 : 0) {
            mark("Bold", asset: "boldtext", action: "bold", filled: filled)
            mark("Italic", asset: "italics", action: "italic", filled: filled)
            mark("Underline", asset: "underline", action: "underline", filled: filled)
            mark("Strikethrough", asset: "strikethrough", action: "strike", filled: filled)
            mark("Inline Code", asset: "codewindow", action: "code", filled: filled)
        }
    }

    private func alignmentButtons(filled: Bool) -> some View {
        HStack(spacing: filled ? 6 : 0) {
            align("Align Left", asset: "leftalign", value: "left", filled: filled)
            align("Align Center", asset: "centeralign", value: "center", filled: filled)
            align("Align Right", asset: "rightalign", value: "right", filled: filled)
            align("Justify", asset: "text.alignjustify", value: "justify", filled: filled, system: true)
        }
    }

    private func textStyle(_ choice: TextStyle, height: CGFloat = 48) -> some View {
        let selected = style?.type == choice.rawValue
        return Button {
            if !selected {
                session.setSelectedBlockType(choice.level == nil ? choice.rawValue : "heading", level: choice.level,
                                             selectionTarget: selectionTarget)
            }
        } label: {
            Text(choice.title).font(choice.font).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity).frame(height: height)
                .background(selectionTile(selected: selected))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func list(_ label: String, asset: String, type: String, command: String) -> some View {
        let selected = style?.list == type
        return icon(label, asset: asset, selected: selected, filled: true) {
            if !selected { session.setSelectedBlockType(command, selectionTarget: selectionTarget) }
        }
    }

    private func mark(_ label: String, asset: String, action: String, filled: Bool) -> some View {
        icon(label, asset: asset, selected: style?.marks.contains(action) == true, filled: filled) {
            format(action)
        }
    }

    private func align(_ label: String, asset: String, value: String, filled: Bool, system: Bool = false) -> some View {
        icon(label, asset: asset, selected: style?.alignment == value, filled: filled, system: system) {
            format("align", value: value)
        }
    }

    private func format(_ action: String, value: String? = nil) {
        session.formatSelectedBlocks(action: action, value: value, selectionTarget: selectionTarget)
    }

    private func icon(_ label: String, asset: String, selected: Bool = false, filled: Bool = false, system: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            (system ? Image(systemName: asset) : Image(asset)).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 19, height: 19)
                .frame(minWidth: 38, maxWidth: filled ? .infinity : 38, minHeight: filled ? 50 : 44)
                .background(selectionTile(selected: selected, filled: filled))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(label)
    }

    private func selectionTile(selected: Bool, filled: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return shape.fill(selected ? PennedSheetStyle.accent.opacity(0.12) : filled ? VellixSurface.subtleFill : .clear)
            .overlay { shape.strokeBorder(selected ? PennedSheetStyle.accent : .clear, lineWidth: 1.5).allowsHitTesting(false) }
    }
}
#endif
