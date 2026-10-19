import SwiftUI

struct InlinePropertyEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var property: InlinePropertyDefinition
    @State private var showDeleteConfirmation = false
    @State private var editingOptionID: String?
    @FocusState private var isNameFocused: Bool
    var onSave: (InlinePropertyDefinition) -> Void
    var onDelete: () -> Void
    var editingGuidance: Bool

    init(property: InlinePropertyDefinition, editingGuidance: Bool = false, onSave: @escaping (InlinePropertyDefinition) -> Void, onDelete: @escaping () -> Void) {
        _property = State(initialValue: property)
        self.onSave = onSave
        self.onDelete = onDelete
        self.editingGuidance = editingGuidance
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PropertyConfigurationSection(title: "Property name") {
                        TextField("Property name", text: $property.name)
                            .font(.body.weight(.semibold))
                            .focused($isNameFocused)
                            .accessibilityLabel("Property name")
                            .propertyConfigurationSurface()
                    }
                    PropertyConfigurationSection(title: "Property type") {
                        Menu {
                            ForEach(InlinePropertyKind.allCases) { kind in
                                Button { property.kind = kind } label: {
                                    Label { Text(kind.title) } icon: { propertyIcon(kind.iconAsset) }
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                propertyIcon(property.kind.iconAsset).foregroundStyle(VellixSurface.violet)
                                Text(property.kind.title)
                                Spacer()
                                propertyIcon("chevdown", size: 14).foregroundStyle(.secondary)
                            }
                            .propertyConfigurationSurface()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Property type")
                        .accessibilityValue(property.kind.title)
                    }
                    if property.kind.isSelect { optionsSection }
                    if editingGuidance && property.kind != .checkbox {
                        PropertyConfigurationSection(title: "Placeholder guidance") {
                            TextField("Guidance", text: $property.placeholder, axis: .vertical)
                                .propertyConfigurationSurface()
                            if !property.value.isEmpty {
                                Button("Convert Value to Guidance") {
                                    property.placeholder = property.value
                                    property.value = ""
                                }
                            }
                        }
                    } else if !property.kind.isSelect || !property.options.isEmpty {
                        PropertyConfigurationSection(title: "Value") { valueEditor }
                    }
                    if !editingGuidance && (property.kind == .text || property.kind == .number || property.kind.isSelect) {
                        PropertyConfigurationSection(title: "Display") {
                            HStack(spacing: 12) {
                                TextField("Placeholder text", text: $property.placeholder)
                                propertyIcon("pencil", size: 16).foregroundStyle(.secondary)
                            }
                            .propertyConfigurationSurface()
                            if property.kind == .number {
                                TextField("Prefix", text: $property.prefix).propertyConfigurationSurface()
                                TextField("Suffix", text: $property.suffix).propertyConfigurationSurface()
                            }
                        }
                    }
                    if property.kind == .number {
                        PropertyConfigurationSection(title: "Limits") {
                            TextField("Minimum", text: $property.minimum).propertyNumericKeyboard().propertyConfigurationSurface()
                            TextField("Maximum", text: $property.maximum).propertyNumericKeyboard().propertyConfigurationSurface()
                            TextField("Step", text: $property.step).propertyNumericKeyboard().propertyConfigurationSurface()
                        }
                    }
                    if let error = property.validationMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Button("Delete Property", role: .destructive) { showDeleteConfirmation = true }
                        .foregroundStyle(.red)
                        .propertyConfigurationSurface()
                        .buttonStyle(.plain)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .pennedSheet(title: "Edit Property", close: { dismiss() }) {
                Button("Done") {
                    property.name = property.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(property)
                    dismiss()
                }.disabled(property.validationMessage != nil)
            }
            .onAppear { isNameFocused = property.name.isEmpty }
            .onChange(of: property.kind) { _, newKind in
                if newKind == .select { property.selectedOptionIDs = Array(property.selectedOptionIDs.prefix(1)) }
                if newKind == .date, property.civilDate == nil { property.value = "" }
            }
            .navigationDestination(item: $editingOptionID) { optionID in
                if let original = property.options.first(where: { $0.id == optionID }) {
                    InlinePropertyOptionEditor(option: Binding(
                        get: { property.options.first(where: { $0.id == optionID }) ?? original },
                        set: { updated in
                            guard let index = property.options.firstIndex(where: { $0.id == optionID }) else { return }
                            property.options[index] = updated
                        }
                    )) {
                        editingOptionID = nil
                        property.options.removeAll { $0.id == optionID }
                        property.selectedOptionIDs.removeAll { $0 == optionID }
                    }
                }
            }
            .confirmationDialog("Delete this property?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Property", role: .destructive) { onDelete(); dismiss() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .environment(\.pennedSheetDismiss, { dismiss() })
        .tint(VellixSurface.violet)
        .preferredColorScheme(.dark)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                propertySectionTitle("Options")
                Spacer()
                Button {
                    var option = InlinePropertyOption()
                    option.name = ""
                    property.options.append(option)
                    editingOptionID = option.id
                } label: {
                    HStack(spacing: 6) {
                        propertyIcon("addwavy", size: 14)
                        Text("Add Option").font(.subheadline.weight(.medium))
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(VellixSurface.violet)
            }
            if !property.options.isEmpty {
                VStack(spacing: 10) {
                    ForEach(property.options) { option in
                        Button { editingOptionID = option.id } label: {
                            HStack(spacing: 12) {
                                InlinePropertyOptionPill(option: option)
                                Spacer(minLength: 8)
                                PropertyOptionDragHandle()
                                    .draggable(option.id)
                                propertyIcon("chevright", size: 14).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .pennedSheetField(cornerRadius: 16)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit option \(option.name)")
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first else { return false }
                            return moveOption(id, to: option.id)
                        }
                        .contextMenu {
                            Button("Move Up") { moveOptionBy(option.id, offset: -1) }
                                .disabled(option.id == property.options.first?.id)
                            Button("Move Down") { moveOptionBy(option.id, offset: 1) }
                                .disabled(option.id == property.options.last?.id)
                        }
                        .accessibilityAction(named: "Move up") { moveOptionBy(option.id, offset: -1) }
                        .accessibilityAction(named: "Move down") { moveOptionBy(option.id, offset: 1) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch property.kind {
        case .text:
            TextField("Text", text: $property.value, axis: .vertical).propertyConfigurationSurface()
        case .number:
            TextField("Number", text: $property.value).propertyNumericKeyboard().propertyConfigurationSurface()
        case .checkbox:
            Toggle("Checked", isOn: $property.checked).propertyConfigurationSurface()
        case .url:
            TextField("URL", text: $property.value).propertyURLKeyboard().propertyConfigurationSurface()
            TextField("Button title", text: $property.urlLabel).propertyConfigurationSurface()
        case .date:
            Toggle("Set Date", isOn: Binding(
                get: { !property.value.isEmpty },
                set: { enabled in if enabled { property.setDate(Date()) } else { property.value = "" } }
            ))
            .propertyConfigurationSurface()
            if !property.value.isEmpty {
                DatePicker("Date", selection: Binding(
                    get: { property.civilDate ?? Date() },
                    set: { property.setDate($0) }
                ), displayedComponents: property.includeTime ? [.date, .hourAndMinute] : [.date])
                .propertyConfigurationSurface()
            }
            Toggle("Include Time", isOn: $property.includeTime)
                .onChange(of: property.includeTime) { _, _ in
                    if let date = property.civilDate { property.setDate(date) }
                }
                .propertyConfigurationSurface()
        case .select, .multiSelect:
            let names = property.options.filter { property.selectedOptionIDs.contains($0.id) }.map(\.name)
            Menu {
                ForEach(property.options) { option in
                    Button {
                        if property.selectedOptionIDs.contains(option.id) {
                            property.selectedOptionIDs.removeAll { $0 == option.id }
                        } else if property.kind == .select {
                            property.selectedOptionIDs = [option.id]
                        } else {
                            property.selectedOptionIDs.append(option.id)
                        }
                    } label: {
                        if property.selectedOptionIDs.contains(option.id) {
                            Label { Text(option.name) } icon: { propertyIcon("checkwavy") }
                        } else {
                            Text(option.name)
                        }
                    }
                }
                Divider()
                Button("Clear Value") { property.selectedOptionIDs = [] }
            } label: {
                HStack(spacing: 12) {
                    Text(names.isEmpty ? "Not set" : names.joined(separator: ", "))
                        .foregroundStyle(names.isEmpty ? Color.secondary : Color.primary)
                    Spacer()
                    propertyIcon("chevdown", size: 14).foregroundStyle(.secondary)
                }
                .propertyConfigurationSurface()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Property value")
        }
    }

    @discardableResult
    private func moveOption(_ id: String, to destinationID: String) -> Bool {
        guard id != destinationID,
              let source = property.options.firstIndex(where: { $0.id == id }),
              let destination = property.options.firstIndex(where: { $0.id == destinationID }) else { return false }
        withAnimation {
            property.options.move(fromOffsets: IndexSet(integer: source), toOffset: destination + (destination > source ? 1 : 0))
        }
        return true
    }

    private func moveOptionBy(_ id: String, offset: Int) {
        guard let source = property.options.firstIndex(where: { $0.id == id }),
              property.options.indices.contains(source + offset) else { return }
        moveOption(id, to: property.options[source + offset].id)
    }
}

struct InlinePropertyOptionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pennedSheetDismiss) private var closeSheet
    @Binding var option: InlinePropertyOption
    @FocusState private var isNameFocused: Bool
    var onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PropertyConfigurationSection(title: "Option name") {
                    TextField("Option name", text: $option.name)
                        .font(.body.weight(.medium))
                        .focused($isNameFocused)
                        .accessibilityLabel("Option name")
                        .propertyConfigurationSurface()
                }
                PropertyConfigurationSection(title: "Option color") {
                    VellixBlockColorControls(title: "Option Color", selection: Binding(
                        get: { Color(vellixHex: option.color) },
                        set: { option.color = $0.vellixHexString(fallback: "#2EC5F4") }
                    ), onColorChange: nil, layout: .optionEditor)
                }
                PropertyConfigurationSection(title: "Preview") {
                    HStack {
                        Spacer()
                        InlinePropertyOptionPill(option: option)
                        Spacer()
                    }
                    .frame(minHeight: 24)
                    .propertyConfigurationSurface()
                }
                Button("Delete Option", role: .destructive, action: onDelete)
                    .foregroundStyle(.red)
                    .propertyConfigurationSurface()
                    .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pennedSheet(title: "Edit Option", close: { if let closeSheet { closeSheet() } else { dismiss() } }) {
            Button("Back") { dismiss() }
            Button("Done") {
                option.name = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
                dismiss()
            }.disabled(option.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { isNameFocused = option.name.isEmpty }
    }
}

private struct InlinePropertyOptionPill: View {
    var option: InlinePropertyOption

    var body: some View {
        let color = Color(vellixHex: option.color)
        Text(option.name.isEmpty ? "New option" : option.name)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.opacity(0.16), in: Capsule())
    }
}

private struct PropertyOptionDragHandle: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3) { _ in
                HStack(spacing: 3) {
                    Circle().frame(width: 3, height: 3)
                    Circle().frame(width: 3, height: 3)
                }
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Reorder option")
    }
}

private struct PropertyConfigurationSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            propertySectionTitle(title)
            content
        }
    }
}

private func propertySectionTitle(_ title: String) -> some View {
    Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
}

private func propertyIcon(_ name: String, size: CGFloat = 20) -> some View {
    Image(name).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
}

private extension InlinePropertyKind {
    var iconAsset: String {
        switch self {
        case .text: return "linedpages"
        case .number, .date: return "numcal"
        case .select, .multiSelect: return "listcircle"
        case .checkbox: return "checkwavy"
        case .url: return "linkcircle"
        }
    }
}

private extension View {
    func propertyConfigurationSurface() -> some View {
        textFieldStyle(.plain)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .pennedSheetField(cornerRadius: 16)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
    }

    @ViewBuilder func propertyNumericKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }

    @ViewBuilder func propertyURLKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
}
