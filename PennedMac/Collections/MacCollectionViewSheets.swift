// Mac-target platform adapter. Based on Vellix/Collections/CollectionViewSheets.swift.
// iPhone/iPad implementations remain in their original target.
import SwiftUI

struct CollectionManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var store: CollectionStore
    let collectionID: String
    let closesOnSelection: Bool
    @State private var name: String
    @State private var fieldTarget: CollectionField?
    @State private var viewTarget: CollectionViewRecord?
    @State private var newViewKind: CollectionViewKind?
    @State private var deletingView: CollectionViewRecord?
    @State private var confirmingDeletion = false
    @State private var isDeleting = false
    @State private var error: String?

    init(store: CollectionStore, snapshot: CollectionSnapshot, closesOnSelection: Bool = false) {
        self.store = store; collectionID = snapshot.record.id
        self.closesOnSelection = closesOnSelection
        _name = State(initialValue: snapshot.name)
    }
    private var snapshot: CollectionSnapshot? { store.snapshots[collectionID] }
    var body: some View {
        NavigationStack {
            MacForm {
                if !closesOnSelection {
                    Section {
                        TextField("Collection name", text: $name)
                    } header: {
                        Text("Collection").pennedSheetSectionHeader()
                    }.collectionFormRows().pennedSheetSectionBackground("collection-name")
                }
                if let snapshot {
                    Section {
                        ForEach(snapshot.views) { view in
                            HStack(spacing: 12) {
                                Button {
                                    do {
                                        try store.repository.selectView(collectionID: collectionID, viewID: view.id)
                                        store.refresh()
                                        if closesOnSelection { dismiss() }
                                    } catch { self.error = error.localizedDescription }
                                } label: {
                                    HStack(spacing: 10) {
                                        LibraryIcon(name: view.kind.icon, size: 20)
                                        Text(view.name).foregroundStyle(.primary)
                                        if snapshot.record.activeViewID == view.id { LibraryIcon(name: "checkwavy", size: 18) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }
                                MacPopoverMenu {
                                    Button("Edit View") { viewTarget = view }
                                    Button("Duplicate View") {
                                        store.perform { _ = try store.repository.addView(collectionID: collectionID, name: view.name + " Copy", kind: view.kind, duplicateID: view.id) }
                                    }
                                    Button("Move Up") { moveView(view.id, offset: -1) }.disabled(view.id == snapshot.views.first?.id)
                                    Button("Move Down") { moveView(view.id, offset: 1) }.disabled(view.id == snapshot.views.last?.id)
                                    Button("Delete View", role: .destructive) { deletingView = view }.disabled(snapshot.views.count == 1)
                                } label: { LibraryIcon(name: "dotswavy", size: 22).frame(width: 44) }
                                .macIconMenuStyle()
                                .accessibilityLabel("Actions for \(view.name)")
                            }.collectionFormRows(showsSeparator: true)
                        }.onMove { offsets, destination in
                            var ids = snapshot.views.map(\.id); ids.move(fromOffsets: offsets, toOffset: destination)
                            store.perform { try store.repository.reorder(collectionID: collectionID, table: "collectionViews", ids: ids) }
                        }
                        MacPopoverMenu {
                            ForEach(CollectionViewKind.allCases) { kind in
                                Button { newViewKind = kind } label: {
                                    Label { Text(kind.title) } icon: { LibraryIcon(name: kind.icon, size: 18) }
                                }
                            }
                        } label: {
                            Label { Text("Add View") } icon: { LibraryIcon(name: "addwavy", size: 18) }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .macIconMenuStyle()
                    } header: {
                        Text("Views").pennedSheetSectionHeader()
                    }.collectionFormRows().pennedSheetSectionBackground("collection-views")
                    Section {
                        HStack { LibraryIcon(name: "linedpages", size: 18); Text("Title"); Spacer(); Text("Document title").foregroundStyle(.secondary) }
                            .collectionFormRows(showsSeparator: true)
                        ForEach(snapshot.fields) { field in
                            Button { fieldTarget = field } label: {
                                HStack { LibraryIcon(name: field.resolvedIcon, size: 18); Text(field.name).foregroundStyle(.primary); Spacer(); Text(field.kind.title).foregroundStyle(.secondary) }
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .contextMenu {
                                Button("Move Up") { moveField(field.id, offset: -1) }.disabled(field.id == snapshot.fields.first?.id)
                                Button("Move Down") { moveField(field.id, offset: 1) }.disabled(field.id == snapshot.fields.last?.id)
                            }
                            .collectionFormRows(showsSeparator: true)
                        }.onMove { offsets, destination in
                            var ids = snapshot.fields.map(\.id); ids.move(fromOffsets: offsets, toOffset: destination)
                            store.perform { try store.repository.reorder(collectionID: collectionID, table: "collectionFields", ids: ids) }
                        }
                        Button { fieldTarget = CollectionField(collectionID: collectionID, name: "", kind: .text) } label: {
                            Label { Text("Add Field") } icon: { LibraryIcon(name: "addwavy", size: 18) }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                    } header: {
                        Text("Shared Fields").pennedSheetSectionHeader()
                    }.collectionFormRows().pennedSheetSectionBackground("collection-fields")
                    if !closesOnSelection {
                        Section {
                            Button(role: .destructive) { confirmingDeletion = true } label: {
                                Label { Text("Delete Collection") } icon: { LibraryIcon(name: "trash", size: 18) }
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                        }.collectionFormRows().pennedSheetSectionBackground("collection-delete")
                    }
                }
                if let message = error ?? store.errorMessage { Text(message).foregroundStyle(.red).collectionFormRows() }
            }.collectionForm(compact: true).pennedSheetGroupedSections().disabled(isDeleting)
                .navigationTitle(closesOnSelection ? "Views" : "Collection")
                .pennedSheet(title: closesOnSelection ? "Views" : "Collection", closeDisabled: isDeleting, close: { dismiss() }) {
                    Button("Done") {
                        do { try store.repository.rename(collectionID: collectionID, name: name); store.refresh(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(isDeleting || name.trimmedNonEmpty == nil)
                }
                .sheet(item: $fieldTarget) { CollectionFieldEditorSheet(store: store, field: $0) }
                .sheet(item: $viewTarget) { view in
                    if let snapshot { CollectionViewEditorSheet(store: store, snapshot: snapshot, view: view) }
                }
                .sheet(item: $newViewKind) { CollectionAddViewSheet(store: store, collectionID: collectionID, kind: $0) }
                .macConfirmationDialog("Delete this view?", isPresented: Binding(get: { deletingView != nil }, set: { if !$0 { deletingView = nil } })) {
                    Button("Delete View", role: .destructive) {
                        guard let view = deletingView else { return }
                        store.perform { try store.repository.deleteView(collectionID: collectionID, viewID: view.id) }
                        deletingView = nil
                    }
                } message: { Text("Entries and shared fields will not be deleted.") }
                .macConfirmationDialog("Delete this collection?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
                    Button("Delete Collection", role: .destructive) {
                        isDeleting = true
                        Task { @MainActor in
                            defer { isDeleting = false }
                            do {
                                try await CollectionDeletion.delete(collectionID, in: environment)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                } message: {
                    Text("The collection, its views, fields, and field values will be deleted. Entry documents will be kept as ordinary pages. This cannot be undone.")
                }
        }.tint(VellixSurface.violet).presentationDetents([.large]).interactiveDismissDisabled(isDeleting)
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
            MacForm {
                TextField("View name", text: $name).focused($focused).collectionFormRows()
                if let error { Text(error).foregroundStyle(.red).collectionFormRows() }
            }.collectionForm().navigationTitle("Add \(kind.title) View")
                .pennedSheet(title: "Add \(kind.title) View", close: { dismiss() }) {
                    Button("Add") {
                        do { _ = try store.repository.addView(collectionID: collectionID, name: name, kind: kind); store.refresh(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(name.trimmedNonEmpty == nil)
                }.onAppear { focused = true }
        }.tint(VellixSurface.violet).presentationDetents([.medium])
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
    private var hiddenFields: [CollectionField] { snapshot.fields.filter { !configuration.visibleFieldIDs.contains($0.id) } }
    var body: some View {
        NavigationStack {
            MacForm {
                Section("View") {
                    TextField("View name", text: $view.name).collectionFormRows(showsSeparator: true)
                    MacSegmentedControl("Presentation", selection: $view.kind, options: CollectionViewKind.allCases, label: { $0.title })
                }.collectionFormRows()
                Section(view.kind == .table ? "Columns" : "Card Properties") {
                    Text("Title").foregroundStyle(.secondary).collectionFormRows(showsSeparator: !snapshot.fields.isEmpty)
                    ForEach(orderedFields) { field in
                        Toggle(field.name, isOn: visibility(field.id))
                            .contextMenu {
                                Button("Move Up") { moveVisible(field.id, -1) }.disabled(field.id == configuration.visibleFieldIDs.first)
                                Button("Move Down") { moveVisible(field.id, 1) }.disabled(field.id == configuration.visibleFieldIDs.last)
                            }
                            .collectionFormRows(showsSeparator: field.id != orderedFields.last?.id || !hiddenFields.isEmpty)
                    }.onMove { configuration.visibleFieldIDs.move(fromOffsets: $0, toOffset: $1) }
                    ForEach(hiddenFields) { field in
                        Toggle(field.name, isOn: visibility(field.id)).collectionFormRows(showsSeparator: field.id != hiddenFields.last?.id)
                    }
                }.collectionFormRows()
                if view.kind == .gallery {
                    Section("Gallery") {
                        MacSegmentedControl("Columns", selection: $configuration.galleryColumns, options: Array(1...3), label: { String($0) }).collectionFormRows(showsSeparator: true)
                        Toggle("Show Covers", isOn: $configuration.showsCover).collectionFormRows(showsSeparator: true)
                        Toggle("Compact Cards", isOn: $configuration.compactCards)
                    }.collectionFormRows()
                }
                Section("Filters") {
                    MacSegmentedControl("Match", selection: $configuration.matchAll, options: [true, false], label: { $0 ? "All Conditions" : "Any Condition" }).collectionFormRows(showsSeparator: true)
                    ForEach(configuration.filters) { filter in
                        Button { filterTarget = filter } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snapshot.field(filter.fieldID)?.name ?? "Title").fontWeight(.semibold)
                                Text(filter.operation.title + (filter.operation.needsValue ? " " + filterCaption(filter) : "")).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.collectionFormRows(showsSeparator: true)
                    }.onDelete { configuration.filters.remove(atOffsets: $0) }
                    Button { filterTarget = CollectionFilter() } label: { Label { Text("Add Filter") } icon: { LibraryIcon(name: "addwavy", size: 18) } }
                }.collectionFormRows()
                Section("Sort Priority") {
                    ForEach($configuration.sorts) { $sort in
                        VStack(alignment: .leading, spacing: 8) {
                            MacOptionPicker("Field", selection: $sort.fieldID, options: [CollectionViewConfiguration.titleFieldID] + snapshot.fields.map(\.id), label: { snapshot.field($0)?.name ?? "Title" })
                            MacSegmentedControl("Order", selection: $sort.ascending, options: [true, false], label: { $0 ? "Ascending" : "Descending" })
                        }
                        .contextMenu {
                            Button("Move Up") { moveSort(sort.id, -1) }.disabled(sort.id == configuration.sorts.first?.id)
                            Button("Move Down") { moveSort(sort.id, 1) }.disabled(sort.id == configuration.sorts.last?.id)
                        }
                        .collectionFormRows(showsSeparator: true)
                    }.onMove { configuration.sorts.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { configuration.sorts.remove(atOffsets: $0) }
                    Button { configuration.sorts.append(CollectionSort()) } label: { Label { Text("Add Sort") } icon: { LibraryIcon(name: "addwavy", size: 18) } }
                }.collectionFormRows()
                if let error { Text(error).foregroundStyle(.red).collectionFormRows() }
            }.collectionForm().navigationTitle("Edit View")
                .pennedSheet(title: "Edit View", close: { dismiss() }) {
                    Button("Save") {
                        var saved = view; saved.configuration = configuration
                        do { try store.repository.saveView(saved); store.refresh(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(view.name.trimmedNonEmpty == nil)
                }
                .sheet(item: $filterTarget) { filter in
                    CollectionFilterSheet(snapshot: snapshot, filter: filter) { saved in
                        if let i = configuration.filters.firstIndex(where: { $0.id == saved.id }) { configuration.filters[i] = saved }
                        else { configuration.filters.append(saved) }
                    } onDelete: {
                        configuration.filters.removeAll { $0.id == filter.id }
                    }
                }
        }.tint(VellixSurface.violet).presentationDetents([.large])
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
            MacForm {
                MacOptionPicker("Field", selection: $filter.fieldID, options: [CollectionViewConfiguration.titleFieldID] + snapshot.fields.map(\.id), label: { snapshot.field($0)?.name ?? "Title" }).onChange(of: filter.fieldID) { _, _ in
                    filter.operation = field.kind.operators.first!
                    filter.value = field.kind == .checkbox ? CollectionValue(checked: false) : CollectionValue()
                }.collectionFormRows(showsSeparator: true)
                MacOptionPicker("Condition", selection: $filter.operation, options: field.kind.operators, label: { $0.title }).collectionFormRows()
                if filter.operation.needsValue { Section("Value") { CollectionValueInput(field: field, value: $filter.value) }.collectionFormRows() }
                if let message = field.filterValidation(filter) { Text(message).font(.footnote).foregroundStyle(.secondary).collectionFormRows(showsSeparator: true) }
                Button("Remove Filter", role: .destructive) { onDelete(); dismiss() }.collectionFormRows()
            }.collectionForm().navigationTitle("Filter")
                .pennedSheet(title: "Filter", close: { dismiss() }) {
                    Button("Done") { onSave(filter); dismiss() }.disabled(field.filterValidation(filter) != nil)
                }
        }.tint(VellixSurface.violet).presentationDetents([.medium, .large])
    }
}
