// Mac-target platform adapter. Based on Vellix/Collections/CollectionDocumentIntegration.swift.
// iPhone/iPad implementations remain in their original target.
import SwiftUI

struct CollectionCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: DocumentEditorModel
    let blockID: String
    @State private var name = ""
    @State private var viewName = "Main"
    @State private var kind = CollectionViewKind.gallery
    @State private var saving = false
    @State private var saved = false
    @State private var created: CollectionSnapshot?
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            MacForm {
                Section("Collection") { TextField("Collection name", text: $name).focused($focused) }.collectionFormRows()
                Section("First View") {
                    TextField("View name", text: $viewName).collectionFormRows(showsSeparator: true)
                    MacSegmentedControl("Presentation", selection: $kind, options: CollectionViewKind.allCases, label: { $0.title })
                }.collectionFormRows()
                if let error { Text(error).foregroundStyle(.red).collectionFormRows() }
            }.collectionForm().navigationTitle("New Collection")
                .pennedSheet(title: "New Collection", closeDisabled: saving, close: { dismiss() }) {
                    Button(saving ? "Creating..." : "Create") { create() }
                        .disabled(saving || name.trimmedNonEmpty == nil || viewName.trimmedNonEmpty == nil)
                }.onAppear { focused = true }
        }.tint(VellixSurface.violet).presentationDetents([.medium, .large])
            .interactiveDismissDisabled(saving)
            .onDisappear { if !saved { model.session.cancelCollectionInsertion(blockID) } }
    }
    private func create() {
        saving = true
        let ownerID = model.documentID
        Task { @MainActor in
            let operation = model.beginPersistentOperation()
            defer { model.endPersistentOperation(operation) }
            defer { saving = false }
            do {
                try await model.captureAndSave()
                guard model.documentID == ownerID, environment.selectedDocumentID == ownerID else { throw VellixError.documentNotFound(ownerID) }
                let snapshot: CollectionSnapshot
                if let created { snapshot = created }
                else {
                    snapshot = try environment.collections.repository.create(ownerID: ownerID, name: name, viewName: viewName, kind: kind)
                    created = snapshot
                }
                try await model.session.resolveCollection(blockID: blockID, collectionID: snapshot.record.id, documentID: snapshot.record.documentID)
                try await model.captureAndSave()
                model.refreshLibraryContext()
                environment.collections.watchDocument(ownerID)
                saved = true; dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CollectionAddEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var store: CollectionStore
    let collectionID: String
    let onOpen: (String) -> Void
    @State private var title = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            MacForm {
                TextField("Page title", text: $title).focused($focused).collectionFormRows(showsSeparator: true)
                Button("Create and Open") { create(open: true) }.disabled(title.trimmedNonEmpty == nil).collectionFormRows()
                if let error { Text(error).foregroundStyle(.red).collectionFormRows() }
            }.collectionForm().navigationTitle("New Entry")
                .pennedSheet(title: "New Entry", close: { dismiss() }) {
                    Button("Create") { create(open: false) }.disabled(title.trimmedNonEmpty == nil)
                }.onAppear { focused = true }
        }.tint(VellixSurface.violet).presentationDetents([.medium])
    }
    private func create(open: Bool) {
        do {
            let document = try store.repository.addEntry(collectionID: collectionID, title: title)
            store.refresh(); dismiss()
            if open { onOpen(document.id) }
        } catch { self.error = error.localizedDescription }
    }
}

struct CollectionEntryActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var store: CollectionStore
    let collectionID: String
    let documentID: String
    let onOpen: (String) -> Void
    @State private var title: String
    @State private var error: String?
    @State private var confirmDelete = false
    init(store: CollectionStore, collectionID: String, entry: CollectionEntrySummary, onOpen: @escaping (String) -> Void) {
        self.store = store; self.collectionID = collectionID; documentID = entry.id; self.onOpen = onOpen
        _title = State(initialValue: entry.title)
    }
    var body: some View {
        NavigationStack {
            MacForm {
                TextField("Page title", text: $title).collectionFormRows(showsSeparator: true)
                Button("Open Page") { dismiss(); onOpen(documentID) }.collectionFormRows(showsSeparator: true)
                Button("Duplicate Entry") {
                    do {
                        _ = try environment.documents.duplicate(id: documentID, attachmentStore: environment.attachmentStore)
                        store.refresh(); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.collectionFormRows(showsSeparator: true)
                Button("Move Up") { move(-1) }.collectionFormRows(showsSeparator: true)
                Button("Move Down") { move(1) }.collectionFormRows(showsSeparator: true)
                Button("Delete Entry", role: .destructive) { confirmDelete = true }.collectionFormRows()
                if let error { Text(error).foregroundStyle(.red).collectionFormRows() }
            }.collectionForm().navigationTitle("Entry")
                .pennedSheet(title: "Entry", close: { dismiss() }) {
                    Button("Save") {
                        do { _ = try environment.documents.updateTitle(id: documentID, title: title); store.refresh(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(title.trimmedNonEmpty == nil)
                }
                .macConfirmationDialog("Move this entry to Trash?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete Entry", role: .destructive) {
                        do { _ = try environment.documents.trash(id: documentID); store.refresh(); environment.refresh(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                } message: { Text("The page disappears from every view. You can restore it from Trash.") }
        }.tint(VellixSurface.violet).presentationDetents([.medium, .large])
    }
    private func move(_ offset: Int) {
        guard let snapshot = store.snapshots[collectionID] else { return }
        var ids = snapshot.entries.map(\.id)
        guard let index = ids.firstIndex(of: documentID), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        do { try store.repository.reorder(collectionID: collectionID, table: "collectionEntries", ids: ids); store.refresh() }
        catch { self.error = error.localizedDescription }
    }
}

struct CollectionDocumentFields: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var store: CollectionStore
    let documentID: String
    let appearance: DocumentAppearance
    let onBeginEditing: () -> Void
    @State private var fieldTarget: CollectionField?
    @State private var valueTarget: CollectionField?

    var body: some View {
        if let (snapshot, entry) = store.entryContext(documentID) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(snapshot.fields) { field in
                    HStack(alignment: .top, spacing: 12) {
                        Button { onBeginEditing(); fieldTarget = field } label: {
                            Label { Text(field.name) } icon: { LibraryIcon(name: field.resolvedIcon, size: 18) }
                                .font(appearance.fontStyle == .hachiMaruPop ? appearance.fontStyle.font(.subheadline, weight: .semibold) : .subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: 140, alignment: .leading)
                        Button { onBeginEditing(); valueTarget = field } label: {
                            CollectionValueDisplay(field: field, value: entry.values[field.id] ?? CollectionValue(), ink: Color(vellixHex: appearance.textColorHex), fontStyle: appearance.fontStyle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(minHeight: 44).buttonStyle(.plain)
                }
                HStack(spacing: 16) {
                    Button { onBeginEditing(); fieldTarget = CollectionField(collectionID: snapshot.record.id, name: "", kind: .text) } label: {
                        Label { Text("Add Field") } icon: { LibraryIcon(name: "addwavy", size: 17) }
                    }
                }.font(.subheadline).foregroundStyle(VellixSurface.violet).padding(.top, 6).padding(.bottom, 12)
            }
            .foregroundStyle(Color(vellixHex: appearance.textColorHex))
            .sheet(item: $fieldTarget) { CollectionFieldEditorSheet(store: store, field: $0) }
            .sheet(item: $valueTarget) { field in
                CollectionValueSheet(store: store, collectionID: snapshot.record.id, documentID: documentID,
                    field: field, value: entry.values[field.id] ?? CollectionValue())
            }
        }
    }
}
