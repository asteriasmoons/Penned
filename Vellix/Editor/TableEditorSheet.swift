import SwiftUI

private enum TableSheetPanel: String {
    case create, overview, edit, format, actions, sort, header, font, cellFormat, content, formula, rename
    var title: String {
        switch self {
        case .create: return "Create Table"
        case .overview: return "Table"
        case .edit: return "Edit Table"
        case .format: return "Format"
        case .actions: return "Actions"
        case .sort: return "Sort"
        case .header: return "Header"
        case .font: return "Font"
        case .cellFormat: return "Cell Format"
        case .content: return "Add Content"
        case .formula: return "Insert Formula"
        case .rename: return "Table Name"
        }
    }
}

private enum TableColorTarget: String, Identifiable {
    case stripe, fill, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stripe: return "Alternating Row Color"
        case .fill: return "Cell Fill Color"
        case .text: return "Text Color"
        }
    }
}

struct TableEditorSheet: View {
    @ObservedObject var model: DocumentEditorModel
    let request: TableEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var panel: TableSheetPanel
    @State private var rows = 3
    @State private var columns = 2
    @State private var headerRow = true
    @State private var value = ""
    @State private var functionQuery = ""
    @State private var colorTarget: TableColorTarget?
    @State private var selectedDetent: PresentationDetent = .fraction(0.45)
    private let accent = PennedSheetStyle.accent

    init(model: DocumentEditorModel, request: TableEditorRequest) {
        self.model = model
        self.request = request
        self._panel = State(initialValue: { if case .create = request.mode { return .create }; return .overview }())
    }

    private var context: TipTapTableContext? {
        if let current = model.tableContext { return current }
        if case .edit(let original) = request.mode { return original }
        return nil
    }

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch panel {
                    case .create: creation
                    case .overview: overview
                    case .edit: editOptions
                    case .format: formatOptions
                    case .actions: actionOptions
                    case .sort: sortOptions
                    case .header: headerOptions
                    case .font: fontOptions
                    case .cellFormat: cellFormats
                    case .content: contentEditor
                    case .formula: formulaEditor
                    case .rename: renameEditor
                    }
                }.padding(.bottom, 8)
            }.scrollIndicators(.hidden)
        }
        .padding(18)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .top)
        .font(.system(.body, design: .rounded))
        .foregroundStyle(VellixSurface.controlInk)
        .pennedSheet(title: panel.title, close: { dismiss() }) {
            if panel != .overview && panel != .create {
                Button("Back") { panel = .overview }
            }
            switch panel {
            case .create:
                Button("Insert Table") {
                    model.session.tableAction("insert", values: ["rows": rows, "columns": columns, "header": headerRow])
                    dismiss()
                }.disabled(rows == 0 && columns == 0)
            case .content:
                Button("Add Content") { action("content", values: ["value": value]); dismiss() }
            case .formula:
                Button("Insert Formula") { action("formula", values: ["value": value]); dismiss() }
                    .disabled(!value.hasPrefix("=") || value.count < 2)
            case .rename:
                Button("Save") { action("rename", values: ["value": value]); panel = .overview }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            default: EmptyView()
            }
        }
        .presentationDetents(detents, selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .sheet(item: $colorTarget) { target in
            CardThreeModeColorPicker(selection: colorBinding(target), title: target.title)
                .presentationDetents([.large])
        }
        .onChange(of: panel) { _, _ in selectedDetent = .fraction(0.45) }
        .onChange(of: value) { _, value in
            if panel == .formula { action("formulaPreview", values: ["value": value]) }
        }
        .onChange(of: model.tableContext) { _, current in
            if case .edit = request.mode, current == nil { dismiss() }
        }
        .alert("Table", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var detents: Set<PresentationDetent> {
        // Open short so the table stays visible above the sheet; content scrolls inside.
        // Drag up to .large when you need every control at once.
        [.fraction(0.45), .large]
    }

    private var creation: some View {
        VStack(spacing: 18) {
            Stepper("Rows: \(rows)", value: $rows, in: 0...200).padding(12).pennedSheetField()
            Stepper("Columns: \(columns)", value: $columns, in: 0...32).padding(12).pennedSheetField()
            Toggle("Header Row", isOn: $headerRow).tint(accent).padding(12).pennedSheetField()
            if rows == 0 && columns == 0 {
                Text("Pick at least one row or column \u{2014} a 0 \u{00D7} 0 table isn\u{2019}t allowed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var overview: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                tile("Edit Table", icon: "blackcal") { panel = .edit }
                tile("Select Cells", icon: "selectsparkle") { action("selectCells"); dismiss() }
                    .disabled(context?.selectedCount == 0)
                Button { panel = .format } label: {
                    VStack(spacing: 12) { Text("Aa").font(.system(size: 24)); Text("Format").font(.subheadline) }
                        .frame(maxWidth: .infinity).frame(height: 86)
                        .pennedSheetField()
                }.buttonStyle(.plain).disabled(context?.selectedCount == 0)
            }.padding(.bottom, 3)
            prominent("Add Content", icon: "arrowin") { value = context?.contents ?? ""; panel = .content }
                .disabled(context?.selectedCount == 0)
            prominent("Insert Formula", formula: true) {
                value = context?.formula.isEmpty == false ? context!.formula : "="
                panel = .formula
                action("formulaPreview", values: ["value": value])
            }
            .disabled(context?.selectedCount == 0)
            Divider().padding(.vertical, 8)
            row("Actions", icon: "repeatarrows", chevron: true) { panel = .actions }
            Divider()
            row("Sort", icon: "numcal", chevron: true, enabled: context?.canSort == true) { panel = .sort }
            Divider()
            row("Header", icon: "blackcal", chevron: true) { panel = .header }
            Divider().padding(.vertical, 6)
            row("Reset Column Size") { action("resetWidth") }
                .disabled(context?.selectedCount == 0)
            row("Clear Cell Style") { action("clearStyle") }
                .disabled(context?.selectedCount == 0)
            row("Clear Cell Contents", destructive: true) { action("clearContents") }
                .disabled(context?.selectedCount == 0)
            Divider().padding(.vertical, 6)
            row("Delete Table", icon: "xmarkwavy", destructive: true) { action("deleteTable"); dismiss() }
        }
    }

    private var editOptions: some View {
        VStack(spacing: 0) {
            row("Insert Row", icon: "addwavy") { action("insertRow") }
            row("Insert Column", icon: "addwavy") { action("insertColumn") }
            Divider().padding(.vertical, 8)
            row("Move Row(s) Up", icon: "chevup", enabled: (context?.fromRow ?? 0) > 0) { action("moveRowUp") }
            row("Move Row(s) Down", icon: "chevdown", enabled: (context?.toRow ?? 0) < (context?.rowCount ?? 0)) { action("moveRowDown") }
            row("Move Column(s) Left", icon: "chevleft", enabled: (context?.fromColumn ?? 0) > 0) { action("moveColumnLeft") }
            row("Move Column(s) Right", icon: "chevright", enabled: (context?.toColumn ?? 0) < (context?.columnCount ?? 0)) { action("moveColumnRight") }
            Divider().padding(.vertical, 8)
            row("Delete Row(s)", icon: "xmarkwavy", destructive: true, enabled: context?.canDeleteRows == true) { action("deleteRows") }
            row("Delete Column(s)", icon: "xmarkwavy", destructive: true, enabled: context?.canDeleteColumns == true) { action("deleteColumns") }
        }
    }

    private var formatOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                mark("bold", icon: "bold", active: context?.bold == true)
                mark("italic", icon: "italics", active: context?.italic == true)
                mark("strike", icon: "strikethrough", active: context?.strike == true)
                mark("code", icon: "codewindow", active: context?.code == true)
            }.pennedSheetField()
            HStack(spacing: 0) {
                alignment("left", icon: "leftalign")
                alignment("center", icon: "centeralign")
                alignment("right", icon: "rightalign")
                alignment("justify", icon: "linedpages")
            }.pennedSheetField()
            row(context?.font == "default" ? "Default Font" : DocumentFontStyle(rawValue: context?.font ?? "")?.title ?? "Default Font",
                icon: "linedpages", chevron: true) { panel = .font }
            section("CELL FORMAT")
            row(formatTitle(context?.format ?? "text"), chevron: true) { panel = .cellFormat }
            section("CELL STYLE")
            colorRow("Alternating Row Color", target: .stripe)
            colorRow("Cell Fill Color", target: .fill)
            colorRow("Text Color", target: .text)
        }
    }

    private var actionOptions: some View {
        VStack(spacing: 0) {
            row("Copy Cells", icon: "copy") { action("copy") }
            row("Cut Cells", icon: "copy") { action("cut") }
            row("Merge Cells", icon: "threeboxes", enabled: context?.canMerge == true) { action("merge") }
            row("Split Cell", icon: "threeboxes", enabled: context?.canSplit == true) { action("split") }
            row("Rename Table", icon: "writepen") { value = context?.name ?? ""; panel = .rename }
            Divider()
            row("Delete Table", icon: "xmarkwavy", destructive: true) { action("deleteTable"); dismiss() }
        }
    }

    private var sortOptions: some View {
        VStack {
            row("Ascending", icon: "chevup") { action("sortAscending") }
            row("Descending", icon: "chevdown") { action("sortDescending") }
        }
    }

    private var headerOptions: some View {
        VStack(spacing: 20) {
            Toggle("Header Row", isOn: Binding(get: { context?.headerRow ?? false }, set: { _ in action("headerRow") })).tint(accent).padding(12).pennedSheetField()
            Toggle("Header Column", isOn: Binding(get: { context?.headerColumn ?? false }, set: { _ in action("headerColumn") })).tint(accent)
                .padding(12).pennedSheetField()
                .disabled(context?.selectedCount == 0)
        }
    }

    private var fontOptions: some View {
        VStack(spacing: 16) {
            row("Default Font", icon: "linedpages") { style(["font": "default"]) }
            HStack(spacing: 8) {
                ForEach(DocumentFontStyle.allCases) { font in
                    let selected = context?.font == font.rawValue
                    Button { style(["font": font.rawValue]) } label: {
                        Text(font.sample).font(.system(size: 23, design: font.design))
                            .frame(maxWidth: .infinity).frame(height: 54)
                            .foregroundStyle(selected ? accent : VellixSurface.controlInk)
                            .background(selected ? accent.opacity(0.15) : .clear, in: Capsule())
                            .pennedSheetField(cornerRadius: 27)
                    }.buttonStyle(.plain).accessibilityLabel(font.title)
                }
            }
        }
    }

    private var cellFormats: some View {
        VStack(spacing: 0) {
            ForEach(["text", "number", "currency", "percent", "date"], id: \.self) { format in
                row(formatTitle(format), icon: context?.format == format ? "checkwavy" : nil) { style(["format": format]) }
            }
            if context?.format == "number" || context?.format == "currency" || context?.format == "percent" {
                Stepper("Decimals: \(context?.decimals ?? 2)", value: Binding(
                    get: { context?.decimals ?? 2 }, set: { style(["decimals": $0]) }
                ), in: 0...10).padding(12).pennedSheetField().padding(.top, 12)
            }
            if context?.format == "currency" {
                Picker("Currency", selection: Binding(get: { context?.currency ?? "USD" }, set: { style(["currency": $0]) })) {
                    ForEach(["USD", "EUR", "GBP", "CAD", "AUD", "JPY", "INR"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).tint(VellixSurface.controlInk).padding(12).pennedSheetField()
            }
        }
    }

    private var contentEditor: some View {
        VStack(spacing: 16) {
            TextEditor(text: $value).scrollContentBackground(.hidden).frame(minHeight: 130)
                .padding(8).pennedSheetField()
        }
    }

    private var formulaEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("=", text: $value, axis: .vertical).font(.system(.body, design: .monospaced))
                .textFieldStyle(.plain).autocorrectionDisabled().lineLimit(2...4)
                .padding(12).pennedSheetField()
            Text(model.tableFormulaPreview).font(.system(.body, design: .monospaced)).foregroundStyle(accent)
                .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 28)
            HStack { LibraryIcon(name: "searchwavy", size: 18); TextField("Search Functions", text: $functionQuery).textFieldStyle(.plain) }
                .padding(10).pennedSheetField()
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach((context?.functions ?? []).filter { functionQuery.isEmpty || $0.localizedCaseInsensitiveContains(functionQuery) }, id: \.self) { name in
                    Button {
                        if value == "=" { value += name + "(" }
                        else { value += name + "(" }
                    } label: {
                        Text(name).font(.system(.subheadline, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var renameEditor: some View {
        VStack(spacing: 18) {
            TextField("Table Name", text: $value).textFieldStyle(.plain).padding(12)
                .pennedSheetField()
        }
    }

    private func action(_ action: String, values: [String: Any] = [:]) {
        model.session.tableAction(action, tableID: context?.tableID, values: values)
    }
    private func style(_ values: [String: Any]) { action("setCellStyle", values: values) }
    private func formatTitle(_ value: String) -> String {
        switch value { case "text": return "Plain Text"; case "percent": return "Percentage"; default: return value.capitalized }
    }
    private func section(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 12)
    }
    private func tile(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) { LibraryIcon(name: icon, size: 26); Text(title).font(.subheadline) }
                .frame(maxWidth: .infinity).frame(height: 86)
                .pennedSheetField()
        }.buttonStyle(.plain)
    }
    private func prominent(_ title: String, icon: String = "", formula: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) { if formula { Text("f(x)").italic() } else { LibraryIcon(name: icon) }; Text(title) }
                .frame(maxWidth: .infinity).frame(height: 44)
                .pennedSheetField()
        }.buttonStyle(.plain)
    }
    private func row(_ title: String, icon: String? = nil, chevron: Bool = false, destructive: Bool = false,
                     enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let icon { LibraryIcon(name: icon, size: 21) }
                Text(title).multilineTextAlignment(.leading)
                Spacer()
                if chevron { LibraryIcon(name: "chevright", size: 14).foregroundStyle(.secondary) }
            }.frame(minHeight: 40).contentShape(Rectangle())
                .foregroundStyle(destructive ? VellixSurface.destructiveAction : VellixSurface.controlInk)
                .opacity(enabled ? 1 : 0.3)
        }.buttonStyle(.plain).pennedSheetField().disabled(!enabled)
    }
    private func mark(_ key: String, icon: String, active: Bool) -> some View {
        Button { style([key: !active]) } label: {
            LibraryIcon(name: icon, size: 23).frame(maxWidth: .infinity).frame(height: 42)
                .background(active ? accent.opacity(0.15) : .clear)
        }.buttonStyle(.plain).accessibilityLabel(key.capitalized)
    }
    private func alignment(_ value: String, icon: String) -> some View {
        Button { style(["align": value]) } label: {
            LibraryIcon(name: icon, size: 23).frame(maxWidth: .infinity).frame(height: 42)
                .background(context?.align == value ? accent.opacity(0.15) : .clear)
        }.buttonStyle(.plain).accessibilityLabel("Align \(value)")
    }
    private func colorRow(_ title: String, target: TableColorTarget) -> some View {
        Button { colorTarget = target } label: {
            HStack {
                Text(title)
                Spacer()
                RoundedRectangle(cornerRadius: 6).fill(colorBinding(target).wrappedValue)
                    .frame(width: 24, height: 24).overlay(RoundedRectangle(cornerRadius: 6).stroke(accent.opacity(0.5), lineWidth: 2))
                    .overlay(LibraryIcon(name: "chevdown", size: 10).foregroundStyle(VellixSurface.controlInk.opacity(0.7)))
            }.frame(minHeight: 38).contentShape(Rectangle())
        }.buttonStyle(.plain).pennedSheetField()
    }
    private func colorBinding(_ target: TableColorTarget) -> Binding<Color> {
        Binding(get: {
            let hex: String
            switch target {
            case .stripe: hex = context?.stripeColor.isEmpty == false ? context!.stripeColor : "#242424"
            case .fill: hex = context?.fillColor.isEmpty == false ? context!.fillColor : "#066DB0"
            case .text: hex = context?.textColor.isEmpty == false ? context!.textColor : model.appearance.textColorHex
            }
            return Color(vellixHex: hex)
        }, set: { color in
            let hex = color.vellixHexString(fallback: "#FFFFFF")
            switch target {
            case .stripe: action("stripeColor", values: ["value": hex])
            case .fill: style(["fillColor": hex])
            case .text: style(["textColor": hex])
            }
        })
    }
}

