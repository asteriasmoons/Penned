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
                mark("Bold", icon: "boldtext", action: "bold", active: session.formattingState.bold)
                mark("Italic", icon: "italics", action: "italic", active: session.formattingState.italic)
                mark("Underline", icon: "underline", action: "underline", active: session.formattingState.underline)
                mark("Strikethrough", icon: "strikethrough", action: "strike", active: session.formattingState.strike)
                mark("Code", icon: "codewindow", action: "code", active: session.formattingState.code)
            }
            MacTextColorInspector(workspace: workspace, session: session)
            if session.textConversionState.token != nil {
                EditorTextConversionMenu(session: session, showsTitle: true)
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
                Button("Outdent") { format("outdent") }.frame(maxWidth: .infinity)
                Button("Indent") { format("indent") }.frame(maxWidth: .infinity)
            }.controlSize(.small)
            MacInspectorSectionHeader(title: "Block Styles")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(1...4, id: \.self) { level in Button(DocumentTextStyleNames.heading(level)) { session.setSelectedBlockType("heading", level: level) } }
                Button("Paragraph") { session.setSelectedBlockType("paragraph") }
                Button("Caption") { session.setSelectedBlockType("caption") }
                Button("Quote") { session.setSelectedBlockType("quote") }
                Button("Callout") { session.setSelectedBlockType("callout") }
                Button("Code") { session.setSelectedBlockType("codeBlock") }
            }.disabled(!blocks)
            MacInspectorSectionHeader(title: "Callout Color")
            VellixBlockColorControls(title: "", selection: $calloutColor, onColorChange: { session.setSelectedCalloutColor($0.vellixHexString(fallback: "#FFFFFF")) }).disabled(!blocks)
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
