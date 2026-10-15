import SwiftUI

struct CollectionManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CollectionStore
    let collectionID: String
    let closesOnSelection: Bool
    @State private var name: String
    @State private var fieldTarget: CollectionField?
    @State private var viewTarget: CollectionViewRecord?
    @State private var newViewKind: CollectionViewKind?
    @State private var deletingView: CollectionViewRecord?
    @State private var error: String?

    init(store: CollectionStore, snapshot: CollectionSnapshot, closesOnSelection: Bool = false) {
        self.store = store; collectionID = snapshot.record.id
        self.closesOnSelection = closesOnSelection
        _name = State(initialValue: snapshot.name)
    }
    private var snapshot: CollectionSnapshot? { store.snapshots[collectionID] }
    var body: some View {
        NavigationStack {
            Form {
                if !closesOnSelection { Section("Collection") { TextField("Collection name", text: $name) } }
                if let snapshot {
                    Section("Views") {
                        ForEach(snapshot.views) { view in
                            HStack {
                                Button {
                                    do {
                                        try store.repository.selectView(collectionID: collectionID, viewID: view.id)
                                        store.refresh()
                                        if closesOnSelection { dismiss() }
                                    } catch { self.error = error.localizedDescription }
                                } label: {
                                    HStack {
                                        LibraryIcon(name: view.kind.icon, size: 20)
                                        Text(view.name).foregroundStyle(.primary)
                                        if snapshot.record.activeViewID == view.id { LibraryIcon(name: "checkwavy", size: 18) }
                                    }
                                }
                                Spacer()
                                Menu {
                                    Button("Edit View") { viewTarget = view }
                                    Button("Duplicate View") {
                                        store.perform { _ = try store.repository.addView(collectionID: collectionID, name: view.name + " Copy", kind: view.kind, duplicateID: view.id) }
                                    }
                                    Button("Move Up") { moveView(view.id, offset: -1) }.disabled(view.id == snapshot.views.first?.id)
                                    Button("Move Down") { moveView(view.id, offset: 1) }.disabled(view.id == snapshot.views.last?.id)
                                    Button("Delete View", role: .destructive) { deletingView = view }.disabled(snapshot.views.count == 1)
                                } label: { LibraryIcon(name: "dotswavy", size: 22).frame(width: 44, height: 44) }
                                .accessibilityLabel("Actions for \(view.name)")
                            }
                        }.onMove { offsets, destination in
                            var ids = snapshot.views.map(\.id); ids.move(fromOffsets: offsets, toOffset: destination)
                            store.perform { try store.repository.reorder(collectionID: collectionID, table: "collectionViews", ids: ids) }
                        }
                        Menu {
                            ForEach(CollectionViewKind.allCases) { kind in
                                Button { newViewKind = kind } label: { Label(kind.title, systemImage: kind.systemIcon) }
                            }
                        } label: { Label { Text("Add View") } icon: { LibraryIcon(name: "addwavy", size: 18) } }
                    }
                    Section("Shared Fields") {
                        HStack { LibraryIcon(name: "linedpages", size: 18); Text("Title"); Spacer(); Text("Document title").foregroundStyle(.secondary) }
                        ForEach(snapshot.fields) { field in
                            Button { fieldTarget = field } label: {
                                HStack { LibraryIcon(name: field.resolvedIcon, size: 18); Text(field.name).foregroundStyle(.primary); Spacer(); Text(field.kind.title).foregroundStyle(.secondary) }
                            }
                            .contextMenu {
                                Button("Move Up") { moveField(field.id, offset: -1) }.disabled(field.id == snapshot.fields.first?.id)
                                Button("Move Down") { moveField(field.id, offset: 1) }.disabled(field.id == snapshot.fields.last?.id)
                            }
                        }.onMove { offsets, destination in
                            var ids = snapshot.fields.map(\.id); ids.move(fromOffsets: offsets, toOffset: destination)
                            store.perform { try store.repository.reorder(collectionID: collectionID, table: "collectionFields", ids: ids) }
                        }
                        Button { fieldTarget = CollectionField(collectionID: collectionID, name: "", kind: .text) } label: {
                            Label { Text("Add Field") } icon: { LibraryIcon(name: "addwavy", size: 18) }
                        }
                    }
                }
                if let message = error ?? store.errorMessage { Text(message).foregroundStyle(.red) }
            }.collectionForm().navigationTitle(closesOnSelection ? "Views" : "Collection")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            do { try store.repository.rename(collectionID: collectionID, name: name); store.refresh(); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }.disabled(name.trimmedNonEmpty == nil)
                    }
                    ToolbarItem(placement: .automatic) { EditButton() }
                }
                .sheet(item: $fieldTarget) { CollectionFieldEditorSheet(store: store, field: $0) }
                .sheet(item: $viewTarget) { view in
                    if let snapshot { CollectionViewEditorSheet(store: store, snapshot: snapshot, view: view) }
                }
                .sheet(item: $newViewKind) { CollectionAddViewSheet(store: store, collectionID: collectionID, kind: $0) }
                .confirmationDialog("Delete this view?", isPresented: Binding(get: { deletingView != nil }, set: { if !$0 { deletingView = nil } })) {
                    Button("Delete View", role: .destructive) {
                        guard let view = deletingView else { return }
                        store.perform { try store.repository.deleteView(collectionID: collectionID, viewID: view.id) }
                        deletingView = nil
                    }
                } message: { Text("Entries and shared fields will not be deleted.") }
        }.tint(VellixSurface.violet).preferredColorScheme(.dark).presentationDetents([.large])
    }
    private func moveView(_ id: String, offset: Int) {
        guard var ids = snapshot?.views.map(\.id), let i = ids.firstIndex(of: id), ids.indices.contains(i + offset) else { return }
        ids.swapAt(i, i + offset)
        store.perform { try store.repository.reorder(collectionID: collectionID, table: "collectionViews", ids: ids) }
    }
    private func moveField(_ id: String, offset: Int) {
        guard var ids = snapshot?.fields.map(\.id), let i = ids.firstIndex(of: id), ids.indices.contains(i + offset) else { return }
        ids.swapAt(i, i + offset)
        store.perform { try store.repository.reorder(collectionID: collectionID, table: "collectionFields", ids: ids) }
    }
}

struct CollectionAddViewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CollectionStore
    let collectionID: String
    let kind: CollectionViewKind
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                TextField("View name", text: $name).focused($focused)
                if let error { Text(error).foregroundStyle(.red) }
            }.collectionForm().navigationTitle("Add \(kind.title) View")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            do { _ = try store.repository.addView(collectionID: collectionID, name: name, kind: kind); store.refresh(); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }.disabled(name.trimmedNonEmpty == nil)
                    }
                }.onAppear { focused = true }
        }.tint(VellixSurface.violet).preferredColorScheme(.dark).presentationDetents([.medium])
    }
}

struct CollectionViewEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CollectionStore
    let snapshot: CollectionSnapshot
    @State private var view: CollectionViewRecord
    @State private var configuration: CollectionViewConfiguration
    @State private var filterTarget: CollectionFilter?
    @State private var error: String?

    init(store: CollectionStore, snapshot: CollectionSnapshot, view: CollectionViewRecord) {
        self.store = store; self.snapshot = snapshot
        _view = State(initialValue: view); _configuration = State(initialValue: view.configuration)
    }
    private var orderedFields: [CollectionField] { configuration.visibleFieldIDs.compactMap(snapshot.field) }
    var body: some View {
        NavigationStack {
            Form {
                Section("View") {
                    TextField("View name", text: $view.name)
                    Picker("Presentation", selection: $view.kind) { ForEach(CollectionViewKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                }
                Section(view.kind == .table ? "Columns" : "Card Properties") {
                    Text("Title").foregroundStyle(.secondary)
                    ForEach(orderedFields) { field in
                        Toggle(field.name, isOn: visibility(field.id))
                            .contextMenu {
                                Button("Move Up") { moveVisible(field.id, -1) }.disabled(field.id == configuration.visibleFieldIDs.first)
                                Button("Move Down") { moveVisible(field.id, 1) }.disabled(field.id == configuration.visibleFieldIDs.last)
                            }
                    }.onMove { configuration.visibleFieldIDs.move(fromOffsets: $0, toOffset: $1) }
                    ForEach(snapshot.fields.filter { !configuration.visibleFieldIDs.contains($0.id) }) { field in Toggle(field.name, isOn: visibility(field.id)) }
                }
                if view.kind == .gallery {
                    Section("Gallery") {
                        Picker("Columns", selection: $configuration.galleryColumns) { ForEach(1...3, id: \.self) { Text("\($0)").tag($0) } }.pickerStyle(.segmented)
                        Toggle("Show Covers", isOn: $configuration.showsCover)
                        Toggle("Compact Cards", isOn: $configuration.compactCards)
                    }
                }
                Section("Filters") {
                    Picker("Match", selection: $configuration.matchAll) { Text("All Conditions").tag(true); Text("Any Condition").tag(false) }.pickerStyle(.segmented)
                    ForEach(configuration.filters) { filter in
                        Button { filterTarget = filter } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snapshot.field(filter.fieldID)?.name ?? "Title").fontWeight(.semibold)
                                Text(filter.operation.title + (filter.operation.needsValue ? " " + filterCaption(filter) : "")).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }.onDelete { configuration.filters.remove(atOffsets: $0) }
                    Button { filterTarget = CollectionFilter() } label: { Label { Text("Add Filter") } icon: { LibraryIcon(name: "addwavy", size: 18) } }
                }
                Section("Sort Priority") {
                    ForEach($configuration.sorts) { $sort in
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Field", selection: $sort.fieldID) {
                                Text("Title").tag(CollectionViewConfiguration.titleFieldID)
                                ForEach(snapshot.fields) { Text($0.name).tag($0.id) }
                            }
                            Picker("Order", selection: $sort.ascending) { Text("Ascending").tag(true); Text("Descending").tag(false) }.pickerStyle(.segmented)
                        }
                        .contextMenu {
                            Button("Move Up") { moveSort(sort.id, -1) }.disabled(sort.id == configuration.sorts.first?.id)
                            Button("Move Down") { moveSort(sort.id, 1) }.disabled(sort.id == configuration.sorts.last?.id)
                        }
                    }.onMove { configuration.sorts.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { configuration.sorts.remove(atOffsets: $0) }
                    Button { configuration.sorts.append(CollectionSort()) } label: { Label { Text("Add Sort") } icon: { LibraryIcon(name: "addwavy", size: 18) } }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.collectionForm().navigationTitle("Edit View")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            var saved = view; saved.configuration = configuration
                            do { try store.repository.saveView(saved); store.refresh(); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }.disabled(view.name.trimmedNonEmpty == nil)
                    }
                    ToolbarItem(placement: .automatic) { EditButton() }
                }
                .sheet(item: $filterTarget) { filter in
                    CollectionFilterSheet(snapshot: snapshot, filter: filter) { saved in
                        if let i = configuration.filters.firstIndex(where: { $0.id == saved.id }) { configuration.filters[i] = saved }
                        else { configuration.filters.append(saved) }
                    } onDelete: {
                        configuration.filters.removeAll { $0.id == filter.id }
                    }
                }
        }.tint(VellixSurface.violet).preferredColorScheme(.dark).presentationDetents([.large])
    }
    private func visibility(_ id: String) -> Binding<Bool> {
        Binding(get: { configuration.visibleFieldIDs.contains(id) }, set: { enabled in
            if enabled { configuration.visibleFieldIDs.append(id) } else { configuration.visibleFieldIDs.removeAll { $0 == id } }
        })
    }
    private func moveVisible(_ id: String, _ offset: Int) {
        guard let i = configuration.visibleFieldIDs.firstIndex(of: id), configuration.visibleFieldIDs.indices.contains(i + offset) else { return }
        configuration.visibleFieldIDs.swapAt(i, i + offset)
    }
    private func moveSort(_ id: String, _ offset: Int) {
        guard let i = configuration.sorts.firstIndex(where: { $0.id == id }), configuration.sorts.indices.contains(i + offset) else { return }
        configuration.sorts.swapAt(i, i + offset)
    }
    private func filterCaption(_ filter: CollectionFilter) -> String {
        snapshot.field(filter.fieldID)?.display(filter.value) ?? filter.value.text
    }
}

struct CollectionFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    var snapshot: CollectionSnapshot
    @State private var filter: CollectionFilter
    let onSave: (CollectionFilter) -> Void
    let onDelete: () -> Void
    init(snapshot: CollectionSnapshot, filter: CollectionFilter, onSave: @escaping (CollectionFilter) -> Void, onDelete: @escaping () -> Void) {
        self.snapshot = snapshot; _filter = State(initialValue: filter); self.onSave = onSave; self.onDelete = onDelete
    }
    private var field: CollectionField {
        snapshot.field(filter.fieldID) ?? CollectionField(id: CollectionViewConfiguration.titleFieldID, collectionID: snapshot.record.id, name: "Title", kind: .text)
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Field", selection: $filter.fieldID) {
                    Text("Title").tag(CollectionViewConfiguration.titleFieldID)
                    ForEach(snapshot.fields) { Text($0.name).tag($0.id) }
                }.onChange(of: filter.fieldID) { _, _ in
                    filter.operation = field.kind.operators.first!
                    filter.value = field.kind == .checkbox ? CollectionValue(checked: false) : CollectionValue()
                }
                Picker("Condition", selection: $filter.operation) { ForEach(field.kind.operators) { Text($0.title).tag($0) } }
                if filter.operation.needsValue { Section("Value") { CollectionValueInput(field: field, value: $filter.value) } }
                if let message = field.filterValidation(filter) { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Button("Remove Filter", role: .destructive) { onDelete(); dismiss() }
            }.collectionForm().navigationTitle("Filter")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onSave(filter); dismiss() }.disabled(field.filterValidation(filter) != nil)
                    }
                }
        }.tint(VellixSurface.violet).preferredColorScheme(.dark).presentationDetents([.medium, .large])
    }
}
