import SwiftUI

struct CollectionValueInput: View {
    var field: CollectionField
    @Binding var value: CollectionValue

    var body: some View {
        switch field.kind {
        case .text, .number, .url, .email:
            HStack {
                if field.kind == .number && !field.configuration.prefix.isEmpty { Text(field.configuration.prefix).foregroundStyle(.secondary) }
                TextField(field.name, text: $value.text, axis: field.kind == .text ? .vertical : .horizontal)
                    .collectionKeyboard(field.kind)
                if field.kind == .number && !field.configuration.suffix.isEmpty { Text(field.configuration.suffix).foregroundStyle(.secondary) }
            }
        case .checkbox:
            Toggle("Checked", isOn: Binding(get: { value.checked ?? false }, set: { value.checked = $0 }))
        case .date:
            Toggle("Set Date", isOn: Binding(get: { !value.text.isEmpty }, set: { enabled in
                if enabled { setDate(Date()) } else { value.text = "" }
            })).collectionFormRows(showsSeparator: !value.text.isEmpty)
            if !value.text.isEmpty {
                DatePicker(field.name, selection: Binding(get: { value.applying(to: field.configuration).civilDate ?? Date() }, set: setDate),
                    displayedComponents: field.configuration.includeTime ? [.date, .hourAndMinute] : [.date])
            }
        case .select, .multiSelect:
            ForEach(field.configuration.options) { option in
                Button {
                    if value.optionIDs.contains(option.id) { value.optionIDs.removeAll { $0 == option.id } }
                    else if field.kind == .select { value.optionIDs = [option.id] }
                    else { value.optionIDs.append(option.id) }
                } label: {
                    HStack {
                        CollectionOptionChip(option: option)
                        Spacer()
                        if value.optionIDs.contains(option.id) { LibraryIcon(name: "checkwavy", size: 20) }
                    }
                }.foregroundStyle(VellixSurface.violet)
                    .collectionFormRows(showsSeparator: option.id != field.configuration.options.last?.id)
            }
        }
    }
    private func setDate(_ date: Date) {
        var configuration = field.configuration
        configuration.setDate(date)
        value.text = configuration.value
    }
}

struct CollectionValueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CollectionStore
    let collectionID: String
    let documentID: String
    let field: CollectionField
    @State private var value: CollectionValue
    @State private var error: String?

    init(store: CollectionStore, collectionID: String, documentID: String, field: CollectionField, value: CollectionValue) {
        self.store = store; self.collectionID = collectionID; self.documentID = documentID; self.field = field
        var initial = value
        if field.kind == .checkbox && initial.checked == nil { initial.checked = false }
        _value = State(initialValue: initial)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(field.name) { CollectionValueInput(field: field, value: $value) }.collectionFormRows()
                Section { Button("Clear Value") { value = CollectionValue() } }.collectionFormRows()
                if let error { Text(error).foregroundStyle(.red).collectionFormRows() }
            }
            .collectionForm()
            .navigationTitle(field.name)
            .pennedSheet(title: field.name, close: { dismiss() }) {
                Button("Save") {
                    do {
                        try store.repository.saveValue(collectionID: collectionID, documentID: documentID, fieldID: field.id, value: value)
                        store.refresh(); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }.tint(VellixSurface.violet).presentationDetents([.medium, .large])
    }
}

struct CollectionFieldEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CollectionStore
    @State private var field: CollectionField
    @State private var configuration: InlinePropertyDefinition
    @State private var optionID: String?
    @State private var error: String?
    @State private var confirmClear = false
    @State private var confirmDelete = false
    @State private var showIconPicker = false
    @FocusState private var focused: Bool
    private let existing: Bool

    init(store: CollectionStore, field: CollectionField) {
        self.store = store
        self.existing = store.snapshots[field.collectionID]?.fields.contains(where: { $0.id == field.id }) == true
        _field = State(initialValue: field); _configuration = State(initialValue: field.configuration)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Field") {
                    HStack(spacing: 12) {
                        Button { focused = false; showIconPicker = true } label: { LibraryIcon(name: field.resolvedIcon, size: 26).frame(width: 44, height: 44) }
                            .buttonStyle(.plain).accessibilityLabel("Choose field icon")
                        TextField("Field name", text: $field.name).focused($focused)
                    }.collectionFormRows(showsSeparator: true)
                    Picker("Type", selection: $field.kind) {
                        ForEach(CollectionFieldKind.allCases) { Text($0.title).tag($0) }
                    }
                }.collectionFormRows()
                if field.kind == .select || field.kind == .multiSelect {
                    Section("Options") {
                        ForEach(configuration.options) { option in
                            Button { optionID = option.id } label: {
                                HStack { CollectionOptionChip(option: option); Spacer(); LibraryIcon(name: "chevright", size: 16) }
                            }.collectionFormRows(showsSeparator: true)
                        }
                        .onMove { configuration.options.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { configuration.options.remove(atOffsets: $0) }
                        Button {
                            var option = InlinePropertyOption(); option.name = ""
                            configuration.options.append(option); optionID = option.id
                        } label: { Label { Text("Add Option") } icon: { LibraryIcon(name: "addwavy", size: 18) } }
                    }.collectionFormRows()
                }
                if field.kind == .number {
                    Section("Number Format") {
                        TextField("Prefix", text: $configuration.prefix).collectionFormRows(showsSeparator: true)
                        TextField("Suffix", text: $configuration.suffix).collectionFormRows(showsSeparator: true)
                        TextField("Minimum", text: $configuration.minimum).collectionKeyboard(.number).collectionFormRows(showsSeparator: true)
                        TextField("Maximum", text: $configuration.maximum).collectionKeyboard(.number).collectionFormRows(showsSeparator: true)
                        TextField("Step", text: $configuration.step).collectionKeyboard(.number)
                    }.collectionFormRows()
                }
                if field.kind == .date { Section { Toggle("Include Time", isOn: $configuration.includeTime) }.collectionFormRows() }
                Section { TextField("Placeholder", text: $configuration.placeholder) }.collectionFormRows()
                if let error { Text(error).foregroundStyle(.red).collectionFormRows() }
                if existing { Section { Button("Delete Field", role: .destructive) { confirmDelete = true } }.collectionFormRows() }
            }
            .collectionForm()
            .navigationTitle(existing ? "Edit Field" : "Add Field")
            .sheet(isPresented: $showIconPicker) {
                VellixIconLibraryPicker(title: "Field Icon", selectedIcon: field.resolvedIcon) { icon in field.icon = icon.name; showIconPicker = false }
            }
            .pennedSheet(title: existing ? "Edit Field" : "Add Field", close: { dismiss() }) {
                EditButton()
                Button("Save") { save() }.disabled(field.name.trimmedNonEmpty == nil)
            }
            .navigationDestination(item: $optionID) { id in
                if let option = configuration.options.first(where: { $0.id == id }) {
                    InlinePropertyOptionEditor(option: Binding(get: { configuration.options.first { $0.id == id } ?? option }, set: { new in
                        if let i = configuration.options.firstIndex(where: { $0.id == id }) { configuration.options[i] = new }
                    })) {
                        optionID = nil; configuration.options.removeAll { $0.id == id }
                    }
                }
            }
            .confirmationDialog("Clear affected values?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Save and Clear Affected Values", role: .destructive) { save(allowClear: true) }
            } message: { Text("This clears incompatible values and removes filters that use deleted options or an incompatible field type. Other fields and documents stay intact.") }
            .confirmationDialog("Delete this shared field?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Field", role: .destructive) {
                    do { try store.repository.deleteField(field); store.refresh(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("This removes the field and its values from every view. Documents are not deleted.") }
            .onAppear { focused = field.name.isEmpty }
        }.environment(\.pennedSheetDismiss, { dismiss() })
            .tint(VellixSurface.violet).presentationDetents([.large])
    }
    private func save(allowClear: Bool = false) {
        var proposed = field
        proposed.configuration = configuration
        do { try store.repository.saveField(proposed, allowClearingValues: allowClear); store.refresh(); dismiss() }
        catch CollectionIntegrityError.confirmationRequired { confirmClear = true }
        catch { self.error = error.localizedDescription }
    }
}

struct CollectionOptionChip: View {
    var option: InlinePropertyOption
    var fontStyle: DocumentFontStyle? = nil
    var body: some View {
        let color = Color(vellixHex: option.color)
        Text(option.name.isEmpty ? "New Option" : option.name)
            .font(fontStyle == .hachiMaruPop ? DocumentFontStyle.hachiMaruPop.font(.subheadline, weight: .medium) : .subheadline.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CollectionValueDisplay: View {
    var field: CollectionField
    var value: CollectionValue
    var ink: Color = .primary
    var fontStyle: DocumentFontStyle? = nil
    @Environment(\.font) private var inheritedFont
    var body: some View {
        content.font(fontStyle == .hachiMaruPop ? DocumentFontStyle.hachiMaruPop.font(.subheadline) : inheritedFont)
    }
    @ViewBuilder private var content: some View {
        if field.kind == .select || field.kind == .multiSelect {
            let options = field.configuration.options.filter { value.optionIDs.contains($0.id) }
            if options.isEmpty { Text("Not set").foregroundStyle(.secondary) }
            else { CollectionChipLayout { ForEach(options) { CollectionOptionChip(option: $0, fontStyle: fontStyle) } } }
        } else {
            HStack(spacing: 6) {
                if !value.isEmpty && (field.kind == .date || field.kind == .checkbox) { LibraryIcon(name: field.resolvedIcon, size: 17) }
                Text(field.display(value)).foregroundStyle(value.isEmpty ? Color.secondary : ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct CollectionChipLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(width: proposal.width ?? 200, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = layout(width: bounds.width, subviews: subviews).points
        for (i, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + positions[i].x, y: bounds.minY + positions[i].y), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
    private func layout(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; row = max(row, size.height)
        }
        return (CGSize(width: width, height: y + row), points)
    }
}

extension View {
    @ViewBuilder func collectionForm(compact: Bool = false) -> some View {
        if compact {
            scrollContentBackground(.hidden)
                .environment(\.pennedSheetCompactRows, true)
                .environment(\.defaultMinListRowHeight, 0)
                .environment(\.defaultMinListHeaderHeight, 0)
                .listSectionSpacing(VellixSpacing.md)
                .contentMargins(.top, 0, for: .scrollContent)
                .buttonStyle(.borderless)
                .textFieldStyle(.plain)
                .fontDesign(.rounded).fontWeight(.black)
        } else {
            scrollContentBackground(.hidden)
        }
    }
    func collectionFormRows(showsSeparator: Bool = false) -> some View {
        pennedSheetRows(showsSeparator: showsSeparator)
    }
    @ViewBuilder func collectionKeyboard(_ kind: CollectionFieldKind) -> some View {
        #if os(iOS)
        switch kind {
        case .number: keyboardType(.numbersAndPunctuation)
        case .url: keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        case .email: keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
        default: self
        }
        #else
        self
        #endif
    }
}
