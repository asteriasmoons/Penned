import SwiftUI

struct MacFormatInspector: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var session: TipTapEditorSession
    @State private var calloutColor = Color.white
    private var blocks: Bool { session.selectedBlockCount > 0 }
    var body: some View {
        VStack(spacing: 14) {
            MacSegmentedControl("Selection", selection: Binding(get: { session.selectionMode }, set: { session.setSelectionMode($0) }), options: ["off", "multi"], label: { $0 == "off" ? "Text" : "Blocks" })
            if blocks { Text("\(session.selectedBlockCount) selected").font(.caption).foregroundStyle(.secondary) }
            MacInspectorSectionHeader(title: "Inline Formatting")
            HStack(spacing: 3) {
                if ["headingLabel", "plainCallout"].contains(session.formattingState.blockSettingsKind ?? ""),
                   let title = session.formattingState.blockSettingsTitle {
                    Button(action: session.requestBlockSettings) {
                        LibraryIcon(name: "settingswavy", size: 18)
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(VellixSurface.input, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).help(title).accessibilityLabel(title)
                }
                mark("Bold", icon: "boldtext", action: "bold", active: session.formattingState.bold)
                mark("Italic", icon: "italics", action: "italic", active: session.formattingState.italic)
                mark("Underline", icon: "underline", action: "underline", active: session.formattingState.underline)
                mark("Strikethrough", icon: "strikethrough", action: "strike", active: session.formattingState.strike)
                mark("Code", icon: "codewindow", action: "code", active: session.formattingState.code)
            }
            MacTextColorInspector(workspace: workspace, session: session)
            if blocks || session.textConversionState.token != nil {
                EditorTextConversionMenu(session: session, showsTitle: true, blockSelection: blocks, isCompact: false)
            }
            MacInspectorSectionHeader(title: "Lists")
            HStack(spacing: 4) {
                mark("Task List", icon: "checklist", action: "checkList", active: session.formattingState.checklist)
                mark("Bulleted List", icon: "bulletlist", action: "bulletList", active: session.formattingState.bulletList)
                mark("Numbered List", icon: "numberlist", action: "numberList", active: session.formattingState.numberList)
            }
            MacInspectorSectionHeader(title: "Alignment")
            HStack(spacing: 3) {
                ForEach(["left", "center", "right", "justify"], id: \.self) { value in
                    Button { format("align", value: value) } label: {
                        LibraryIcon(name: value == "justify" ? "text" : value + "align", size: 18)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(session.formattingState.alignment == value ? VellixSurface.selection : VellixSurface.input, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).help(value.capitalized + " Align").accessibilityLabel(value.capitalized + " Align")
                }
            }
            HStack {
                Button { format("outdent") } label: {
                    Label { Text("Outdent") } icon: { LibraryIcon(name: "outdent", size: 14) }
                }.frame(maxWidth: .infinity)
                Button { format("indent") } label: {
                    Label { Text("Indent") } icon: { LibraryIcon(name: "indent", size: 14) }
                }.frame(maxWidth: .infinity)
            }.controlSize(.small)
            MacInspectorSectionHeader(title: "Block Styles")
            if blocks && session.formattingState.selectedBlocksStyle?.canColorDivider == true {
                MacColorRow(title: "Divider Color", selection: Binding(get: {
                    session.formattingState.selectedBlocksStyle?.dividerColor.map { Color(vellixHex: $0) } ?? VellixSurface.ink
                }, set: { color in
                    format("dividerColor", value: color.vellixHexString(fallback: "#FFFFFF"))
                }))
            }
            if blocks && session.formattingState.selectedBlocksStyle?.canLabel == true {
                HStack {
                    Button("Text") { format("headingPresentation", value: "text") }
                    Button("Label") { format("headingPresentation", value: "label") }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(1...4, id: \.self) { level in Button(DocumentTextStyleNames.heading(level)) { session.setSelectedBlockType("heading", level: level) } }
                Button("Paragraph") { session.setSelectedBlockType("paragraph") }
                Button("Caption") { session.setSelectedBlockType("caption") }
                Button("Quote") { session.setSelectedBlockType("quote") }
                Button("Callout") { session.setSelectedBlockType("plainCallout") }
                Button("Code") { session.setSelectedBlockType("codeBlock") }
            }.disabled(!blocks)
            MacInspectorSectionHeader(title: "Callout Color")
            ColorPicker("Background", selection: $calloutColor, supportsOpacity: false)
                .onChange(of: calloutColor) { _, color in
                    session.setSelectedCalloutColor(color.vellixHexString(fallback: "#FFFFFF"))
                }.disabled(!blocks)
            if blocks {
                Button("Group as Page") { session.requestSelectedBlocksForSubpage() }.frame(maxWidth: .infinity)
                Button("Clear Selection") { session.clearBlockSelection() }.frame(maxWidth: .infinity)
            }
        }
    }
    private func mark(_ title: String, icon: String, action: String, active: Bool) -> some View {
        Button { format(action) } label: {
            LibraryIcon(name: icon, size: 18).frame(maxWidth: .infinity).frame(height: 32)
                .background(active ? VellixSurface.selection : VellixSurface.input, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title).accessibilityAddTraits(active ? .isSelected : [])
    }
    private func format(_ action: String, value: String? = nil) {
        if blocks { session.formatSelectedBlocks(action: action, value: value) }
        else { session.formatCurrentSelection(action: action, value: value) }
    }
}
