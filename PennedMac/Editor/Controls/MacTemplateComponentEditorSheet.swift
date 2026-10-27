// Mac-target platform adapter. Based on Vellix/DailyNotes/TemplateComponentEditorSheet.swift.
// iPhone/iPad implementations remain in their original target.
import SwiftUI

struct TemplateComponentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: TemplateComponentRequest
    let session: TipTapEditorSession
    @State private var definition: TemplateComponentDefinition
    @State private var error: String?

    init(request: TemplateComponentRequest, session: TipTapEditorSession) {
        self.request = request; self.session = session
        _definition = State(initialValue: request.definition)
    }

    var body: some View {
        NavigationStack {
            MacForm {
                Section("Question") { TextField("Optional label", text: $definition.label, axis: .vertical) }.pennedSheetRows()
                if definition.kind == .rating || definition.kind == .slider {
                    Section("Range") {
                        number("Minimum", value: $definition.minimum).pennedSheetRows(showsSeparator: true)
                        number("Maximum", value: $definition.maximum).pennedSheetRows(showsSeparator: definition.kind == .slider)
                        if definition.kind == .slider { number("Step", value: $definition.step) }
                    }.pennedSheetRows()
                }
                if definition.kind == .singleSelect || definition.kind == .multiSelect {
                    Section("Choices") {
                        ForEach($definition.choices) { $choice in
                            HStack {
                                TextField("Choice", text: $choice.label)
                                Button { move(choice.id, by: -1) } label: { LibraryIcon(name: "chevup", size: 12) }
                                    .disabled(definition.choices.first?.id == choice.id).accessibilityLabel("Move choice up")
                                Button { move(choice.id, by: 1) } label: { LibraryIcon(name: "chevdown", size: 12) }
                                    .disabled(definition.choices.last?.id == choice.id).accessibilityLabel("Move choice down")
                                Button(role: .destructive) { definition.choices.removeAll { $0.id == choice.id } } label: { LibraryIcon(name: "trash", size: 16) }
                                    .accessibilityLabel("Delete choice")
                            }.buttonStyle(.borderless).pennedSheetRows(showsSeparator: true)
                        }
                        .onDelete { definition.choices.remove(atOffsets: $0) }
                        .onMove { definition.choices.move(fromOffsets: $0, toOffset: $1) }
                        Button("Add Choice") { definition.choices.append(TemplateComponentChoice(label: "")) }
                    }.pennedSheetRows()
                }
                if definition.kind == .slider {
                    Section("Endpoint Labels") {
                        TextField("Minimum label", text: $definition.minimumLabel).pennedSheetRows(showsSeparator: true)
                        TextField("Maximum label", text: $definition.maximumLabel)
                    }.pennedSheetRows()
                }
                if let blockID = request.blockID {
                    Section {
                        Button("Move Up") { session.templateComponentAction("Move", blockID: blockID, direction: -1); dismiss() }.pennedSheetRows(showsSeparator: true)
                        Button("Move Down") { session.templateComponentAction("Move", blockID: blockID, direction: 1); dismiss() }.pennedSheetRows(showsSeparator: true)
                        Button("Delete Component", role: .destructive) { session.templateComponentAction("Delete", blockID: blockID); dismiss() }
                    }.pennedSheetRows()
                }
                if let error { Section { Text(error).foregroundStyle(.red) }.pennedSheetRows() }
            }
            .navigationTitle(definition.kind.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .pennedSheet(title: definition.kind.title, close: { dismiss() }) {
                Button(request.blockID == nil ? "Add" : "Save") {
                    do { session.saveTemplateComponent(try definition.validated(), blockID: request.blockID); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            .tint(VellixSurface.accent)
        }
    }

    private func number(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number).multilineTextAlignment(.trailing).frame(maxWidth: 150)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        }
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = definition.choices.firstIndex(where: { $0.id == id }), definition.choices.indices.contains(index + offset) else { return }
        definition.choices.swapAt(index, index + offset)
    }
}
