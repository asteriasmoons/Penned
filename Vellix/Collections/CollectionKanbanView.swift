import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

nonisolated private struct CollectionKanbanDragItem: Codable, Transferable {
    var collectionID: String
    var viewID: String
    var documentID: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "im.lystaria.Penned.collection-entry"))
    }
}

struct CollectionKanbanView: View {
    static let embeddedHeight = CGFloat(CollectionViewConfiguration.kanbanMaxHeight)
    @ObservedObject var store: CollectionStore
    let collectionID: String
    let blockID: String
    var editable: Bool
    var appearance = DocumentAppearance.plain
    var savedSnapshot: CollectionSnapshot?
    var onRequest: (CollectionEditorRequest) -> Void
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @State private var sheet: BoardSheet?
    @State private var addingColumnID: String?
    @State private var newTitle = ""
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    private struct BoardSheet: Identifiable {
        enum Kind { case columns, column(CollectionKanbanColumn?), viewSettings, addView(CollectionViewKind) }
        var id = UUID().uuidString
        var kind: Kind
    }
    private var snapshot: CollectionSnapshot? { store.snapshots[collectionID] ?? savedSnapshot }
    private let ink = Color(vellixHex: "#E4E6F1")

    var body: some View {
        if let snapshot, let view = snapshot.activeView, view.kind == .kanban {
            VStack(spacing: 10) {
                header(snapshot, view: view)
                    .background(sectionMeasurement("header"))
                ScrollView(.vertical) {
                    LazyVStack(spacing: 12) {
                        ForEach(snapshot.kanbanGroups(in: view), id: \.column.id) { group in
                            column(group.column, entries: group.entries, snapshot: snapshot, view: view)
                        }
                    }.padding(.bottom, 4).background(sectionMeasurement("content"))
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .accessibilityLabel("Kanban columns")
                if editable {
                    HStack {
                        Button { sheet = BoardSheet(kind: .column(nil)) } label: {
                            Label { Text("Add Column") } icon: { LibraryIcon(name: "addwavy", size: 16) }
                        }
                        Spacer()
                        Button { sheet = BoardSheet(kind: .columns) } label: { LibraryIcon(name: "dotswavy", size: 22).frame(width: 36, height: 30) }
                            .accessibilityLabel("Manage columns")
                    }.font(.subheadline).foregroundStyle(VellixSurface.violet)
                        .padding(.horizontal, 8).background(sectionMeasurement("footer"))
                }
            }
            .foregroundStyle(ink)
            .buttonStyle(.plain)
            .onPreferenceChange(KanbanSectionHeights.self) { sizes in
                guard let header = sizes["header"], let content = sizes["content"] else { return }
                let desired = min(Self.embeddedHeight, ceil(header + content + (sizes["footer"] ?? 0) + (editable ? 20 : 10)))
                onHeightChange(max(120, desired))
            }
            .sheet(item: $sheet) { target in
                switch target.kind {
                case .columns: CollectionKanbanColumnsSheet(store: store, collectionID: collectionID, viewID: view.id)
                case .column(let column): CollectionKanbanColumnEditor(store: store, collectionID: collectionID, viewID: view.id, column: column)
                case .viewSettings: CollectionViewEditorSheet(store: store, snapshot: snapshot, view: view)
                case .addView(let kind): CollectionAddViewSheet(store: store, collectionID: collectionID, kind: kind)
                }
            }
            .alert("Unable to Update Board", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .onChange(of: editable) { _, value in if !value { cancelAdding() } }
        }
    }

    private func request(_ action: String, documentID: String = "", fieldID: String = "") {
        onRequest(CollectionEditorRequest(action: action, blockID: blockID, collectionID: collectionID, documentID: documentID, fieldID: fieldID))
    }
    private func sectionMeasurement(_ name: String) -> some View {
        GeometryReader { proxy in Color.clear.preference(key: KanbanSectionHeights.self, value: [name: proxy.size.height]) }
    }
    private func perform(_ operation: () throws -> Void) {
        guard editable else { return }
        do { try operation(); store.refresh() } catch { self.error = error.localizedDescription }
    }
    private func header(_ snapshot: CollectionSnapshot, view: CollectionViewRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { request("configure") } label: {
                Text(snapshot.name).font(.system(size: 18, weight: .bold, design: appearance.fontStyle.design))
                    .foregroundStyle(Color(vellixHex: appearance.textColorHex))
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
            }.disabled(!editable)
            Spacer(minLength: 4)
            Menu {
                ForEach(snapshot.views) { candidate in
                    Button {
                        cancelAdding()
                        perform { try store.repository.selectView(collectionID: collectionID, viewID: candidate.id) }
                    } label: {
                        Label { Text(candidate.name) } icon: {
                            LibraryIcon(name: candidate.id == view.id ? "checkwavy" : candidate.kind.icon, size: 18)
                        }
                    }
                }
                Divider()
                Menu {
                    ForEach(CollectionViewKind.allCases) { kind in
                        Button { sheet = BoardSheet(kind: .addView(kind)) } label: {
                            Label { Text(kind.title) } icon: { LibraryIcon(name: kind.icon, size: 18) }
                        }
                    }
                } label: { Label("Add View", systemImage: "plus.square.on.square") }
                Button("Edit View", systemImage: "slider.horizontal.3") { sheet = BoardSheet(kind: .viewSettings) }
                Button("Manage Columns", systemImage: "list.bullet") { sheet = BoardSheet(kind: .columns) }
                Button("Configure Collection", systemImage: "gearshape") { request("configure") }
            } label: {
                HStack(spacing: 4) {
                    Text(view.name).font(.subheadline).lineLimit(1)
                    LibraryIcon(name: "chevdown", size: 12)
                }.font(.system(size: 15, design: appearance.fontStyle.design))
                    .foregroundStyle(Color(vellixHex: "#B59AD9"))
                    .padding(.vertical, 8).padding(.horizontal, 8)
            }.disabled(!editable).accessibilityLabel("Collection views")
            Button { request("configure") } label: {
                LibraryIcon(name: "dotswavy", size: 18).frame(width: 32, height: 40)
            }.disabled(!editable).accessibilityLabel("Configure collection")
        }.frame(minHeight: 40).padding(.horizontal, 8)
    }

    private func column(_ column: CollectionKanbanColumn, entries: [CollectionEntrySummary], snapshot: CollectionSnapshot, view: CollectionViewRecord) -> some View {
        let color = Color(vellixHex: column.color)
        let headerInk = columnInk(column.color)
        return VStack(spacing: 9) {
            HStack(spacing: 5) {
                Button {
                    perform {
                        try store.repository.updateKanbanColumn(collectionID: collectionID, viewID: view.id, columnID: column.id, collapsed: !column.collapsed)
                        if !column.collapsed && addingColumnID == column.id { cancelAdding() }
                    }
                } label: {
                    Image(systemName: column.collapsed ? "chevron.right" : "chevron.down").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 36)
                }.disabled(!editable).accessibilityLabel(column.collapsed ? "Expand \(column.name)" : "Collapse \(column.name)")
                Text(column.name).font(.system(.subheadline, design: .rounded).weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text("\(entries.count)").font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.black.opacity(0.24), in: Capsule()).foregroundStyle(.white)
                Spacer(minLength: 0)
                Button { beginAdding(column.id) } label: { Image(systemName: "plus").font(.system(size: 17)).frame(width: 36, height: 36) }
                    .disabled(!editable).accessibilityLabel("Add entry to \(column.name)")
            }.foregroundStyle(headerInk)
                .contextMenu {
                    if editable {
                        Button("Edit Column", systemImage: "pencil") { sheet = BoardSheet(kind: .column(column)) }
                        Button("Manage Columns", systemImage: "list.bullet") { sheet = BoardSheet(kind: .columns) }
                    }
                }
            if !column.collapsed {
                ForEach(entries) { entry in
                    card(entry, columnID: column.id, entries: entries, snapshot: snapshot, view: view)
                }
                if entries.isEmpty && !view.configuration.filters.isEmpty && addingColumnID != column.id {
                    Text("No matching entries").font(.caption).foregroundStyle(headerInk.opacity(0.75)).frame(maxWidth: .infinity, alignment: .leading)
                }
                if addingColumnID != column.id && !entries.isEmpty && editable {
                    Button { beginAdding(column.id) } label: {
                        Image(systemName: "plus").font(.system(size: 18)).frame(maxWidth: .infinity).frame(height: 34)
                            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(headerInk.opacity(0.3), lineWidth: 1))
                    }.foregroundStyle(headerInk).accessibilityLabel("New entry in \(column.name)")
                }
            }
            if addingColumnID == column.id { entryComposer(column, view: view, ink: headerInk) }
        }
        .padding(10)
        .background(color, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(headerInk.opacity(0.25), lineWidth: 1))
        .dropDestination(for: CollectionKanbanDragItem.self) { items, _ in _ = drop(items, view: view, columnID: column.id) }
    }

    private func card(_ entry: CollectionEntrySummary, columnID: String, entries: [CollectionEntrySummary], snapshot: CollectionSnapshot, view: CollectionViewRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { request("openEntry", documentID: entry.id) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.title).font(.system(.subheadline, design: .rounded).weight(.medium)).lineLimit(3).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.top, 3)
                }.contentShape(Rectangle())
            }.accessibilityLabel("Open \(entry.title)")
            CollectionChipLayout {
                ForEach(snapshot.visibleFields(in: view)) { field in
                    let value = entry.values[field.id] ?? CollectionValue()
                    if !value.isEmpty {
                        let options = field.configuration.options.filter { value.optionIDs.contains($0.id) }
                        if options.isEmpty {
                            propertyTag(field.display(value), color: "#87B9D5", field: field, entry: entry)
                        } else {
                            ForEach(options) { option in propertyTag(option.name, color: option.color, field: field, entry: entry) }
                        }
                    }
                }
            }
        }
        .padding(11)
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(vellixHex: "#2C2C2E"), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.1), lineWidth: 1))
        .contextMenu {
            Button("Open", systemImage: "doc.text") { request("openEntry", documentID: entry.id) }
            if editable {
                Button("Edit Entry", systemImage: "pencil") { request("entry", documentID: entry.id) }
                Menu("Edit Properties") {
                    ForEach(snapshot.fields) { field in
                        Button { request("value", documentID: entry.id, fieldID: field.id) } label: {
                            Label { Text(field.name) } icon: { LibraryIcon(name: field.resolvedIcon, size: 18) }
                        }
                    }
                }
                Menu("Move to Column") {
                    ForEach(view.configuration.kanbanColumns) { column in
                        Button(column.name) { move(entry.id, to: column.id, view: view) }.disabled(column.id == columnID)
                    }
                }
                Button("Move Up", systemImage: "arrow.up") { reorder(entry, entries: entries, columnID: columnID, view: view, offset: -1) }
                    .disabled(entries.first?.id == entry.id || !view.configuration.sorts.isEmpty)
                Button("Move Down", systemImage: "arrow.down") { reorder(entry, entries: entries, columnID: columnID, view: view, offset: 1) }
                    .disabled(entries.last?.id == entry.id || !view.configuration.sorts.isEmpty)
            }
        }
        .collectionKanbanDrag(CollectionKanbanDragItem(collectionID: collectionID, viewID: view.id, documentID: entry.id), enabled: editable)
        .dropDestination(for: CollectionKanbanDragItem.self) { items, _ in _ = drop(items, view: view, columnID: columnID, beforeID: entry.id) }
    }
    private func propertyTag(_ text: String, color hex: String, field: CollectionField, entry: CollectionEntrySummary) -> some View {
        let color = Color(vellixHex: hex)
        return Button { request("value", documentID: entry.id, fieldID: field.id) } label: {
            Text(text).font(.caption2.weight(.medium)).lineLimit(2).padding(.horizontal, 5).padding(.vertical, 2)
                .foregroundStyle(color).background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.35), lineWidth: 0.75))
        }.disabled(!editable).accessibilityLabel("\(field.name): \(text). Edit value")
    }
    private func beginAdding(_ columnID: String) {
        guard let view = snapshot?.activeView else { return }
        perform {
            if view.configuration.kanbanColumns.first(where: { $0.id == columnID })?.collapsed == true {
                try store.repository.updateKanbanColumn(collectionID: collectionID, viewID: view.id, columnID: columnID, collapsed: false)
            }
            newTitle = ""; addingColumnID = columnID; titleFocused = true
        }
    }
    private func cancelAdding() { titleFocused = false; addingColumnID = nil; newTitle = "" }
    private func entryComposer(_ column: CollectionKanbanColumn, view: CollectionViewRecord, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("New entry title", text: $newTitle, axis: .vertical)
                .focused($titleFocused).lineLimit(1...3).font(.subheadline)
                .padding(10).background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.opacity(0.25), lineWidth: 1))
                .onSubmit { createEntry(view: view, columnID: column.id) }
            HStack(spacing: 18) {
                Button("Add Entry") { createEntry(view: view, columnID: column.id) }.fontWeight(.semibold).disabled(newTitle.trimmedNonEmpty == nil)
                Button("Cancel") { cancelAdding() }
            }.font(.caption).foregroundStyle(ink).padding(.vertical, 4)
        }
    }
    private func createEntry(view: CollectionViewRecord, columnID: String) {
        perform {
            _ = try store.repository.addEntry(collectionID: collectionID, title: newTitle, kanbanViewID: view.id, columnID: columnID)
            cancelAdding()
        }
    }
    private func move(_ entryID: String, to columnID: String, view: CollectionViewRecord, beforeID: String? = nil) {
        perform { try store.repository.moveKanbanEntry(collectionID: collectionID, viewID: view.id, documentID: entryID, columnID: columnID, beforeID: beforeID) }
    }
    private func reorder(_ entry: CollectionEntrySummary, entries: [CollectionEntrySummary], columnID: String, view: CollectionViewRecord, offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), entries.indices.contains(index + offset) else { return }
        let beforeID = offset < 0 ? entries[index - 1].id : entries.indices.contains(index + 2) ? entries[index + 2].id : nil
        move(entry.id, to: columnID, view: view, beforeID: beforeID)
    }
    private func drop(_ items: [CollectionKanbanDragItem], view: CollectionViewRecord, columnID: String, beforeID: String? = nil) -> Bool {
        guard editable, items.count == 1, let item = items.first, item.collectionID == collectionID, item.viewID == view.id,
              snapshot?.entries.contains(where: { $0.id == item.documentID }) == true, item.documentID != beforeID else { return false }
        if !view.configuration.sorts.isEmpty && view.configuration.kanbanColumnID(for: item.documentID) == columnID { return false }
        move(item.documentID, to: columnID, view: view, beforeID: view.configuration.sorts.isEmpty ? beforeID : nil)
        return true
    }
    private func columnInk(_ hex: String) -> Color {
        let rgb = UInt64(hex.dropFirst(), radix: 16) ?? 0
        let luminance = 0.299 * Double((rgb >> 16) & 255) + 0.587 * Double((rgb >> 8) & 255) + 0.114 * Double(rgb & 255)
        return luminance > 165 ? Color(vellixHex: "#181821") : .white
    }
}

private extension View {
    @ViewBuilder func collectionKanbanDrag(_ item: CollectionKanbanDragItem, enabled: Bool) -> some View {
        if enabled { draggable(item) } else { self }
    }
}

private struct KanbanSectionHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, latest in latest }) }
}

struct CollectionKanbanColumnsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CollectionStore
    let collectionID: String
    let viewID: String
    @State private var target: ColumnTarget?
    @State private var error: String?
    private struct ColumnTarget: Identifiable { var id = UUID().uuidString; var column: CollectionKanbanColumn? }
    private var columns: [CollectionKanbanColumn] { store.snapshots[collectionID]?.views.first { $0.id == viewID }?.configuration.kanbanColumns ?? [] }
    var body: some View {
        NavigationStack {
            List {
                ForEach(columns) { column in
                    Button { target = ColumnTarget(column: column) } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 4).fill(Color(vellixHex: column.color)).frame(width: 24, height: 24)
                            Text(column.name)
                            Spacer()
                            Image(systemName: column.collapsed ? "chevron.right" : "chevron.down").foregroundStyle(.secondary)
                        }
                    }.collectionFormRows(showsSeparator: true)
                }.onMove { source, destination in
                    var ordered = columns.map(\.id); ordered.move(fromOffsets: source, toOffset: destination)
                    do { try store.repository.reorderKanbanColumns(collectionID: collectionID, viewID: viewID, ids: ordered); store.refresh() }
                    catch { self.error = error.localizedDescription }
                }.collectionFormRows()
                Button { target = ColumnTarget(column: nil) } label: { Label("Add Column", systemImage: "plus") }.collectionFormRows()
                if let error { Text(error).foregroundStyle(.red).collectionFormRows() }
            }.collectionForm().navigationTitle("Columns")
                .pennedSheet(title: "Columns", close: { dismiss() }) {
                    EditButton()
                    Button("Done") { dismiss() }
                }
                .sheet(item: $target) { target in
                    CollectionKanbanColumnEditor(store: store, collectionID: collectionID, viewID: viewID, column: target.column)
                }
        }.tint(VellixSurface.violet).preferredColorScheme(.dark).presentationDetents([.medium, .large])
    }
}

struct CollectionKanbanColumnEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CollectionStore
    let collectionID: String
    let viewID: String
    let columnID: String?
    @State private var name: String
    @State private var hex: String
    @State private var destinationID = ""
    @State private var showsColors = false
    @State private var confirmsDelete = false
    @State private var error: String?
    init(store: CollectionStore, collectionID: String, viewID: String, column: CollectionKanbanColumn?) {
        self.store = store; self.collectionID = collectionID; self.viewID = viewID; columnID = column?.id
        _name = State(initialValue: column?.name ?? ""); _hex = State(initialValue: column?.color ?? "#34363F")
    }
    private var alternatives: [CollectionKanbanColumn] {
        store.snapshots[collectionID]?.views.first { $0.id == viewID }?.configuration.kanbanColumns.filter { $0.id != columnID } ?? []
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Column") { TextField("Column name", text: $name) }.collectionFormRows()
                Section("Background Color") {
                    Button { showsColors = true } label: {
                        HStack {
                            Text("Choose Color")
                            Spacer()
                            RoundedRectangle(cornerRadius: 6).fill(Color(vellixHex: hex)).frame(width: 46, height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.25), lineWidth: 1))
                        }
                    }.collectionFormRows(showsSeparator: true)
                    TextField("#RRGGBB", text: $hex).autocorrectionDisabled()
                        .collectionKeyboard(.url)
                }.collectionFormRows()
                if columnID != nil && !alternatives.isEmpty {
                    Section("Delete Column") {
                        Picker("Move Entries To", selection: $destinationID) {
                            Text("Choose Column").tag("")
                            ForEach(alternatives) { Text($0.name).tag($0.id) }
                        }.collectionFormRows(showsSeparator: true)
                        Button("Delete Column", role: .destructive) { confirmsDelete = true }.disabled(destinationID.isEmpty)
                    }.collectionFormRows()
                }
                if let error { Text(error).foregroundStyle(.red).collectionFormRows() }
            }.collectionForm().navigationTitle(columnID == nil ? "New Column" : "Edit Column")
                .pennedSheet(title: columnID == nil ? "New Column" : "Edit Column", close: { dismiss() }) {
                    Button("Save") { save() }.disabled(name.trimmedNonEmpty == nil)
                }
                .sheet(isPresented: $showsColors) {
                    CardThreeModeColorPicker(selection: Binding(get: { Color(vellixHex: hex) }, set: { hex = $0.vellixHexString(fallback: hex) }), title: "Column Color")
                }
                .confirmationDialog("Delete this column? Its entries will move to the chosen column. No documents will be deleted.", isPresented: $confirmsDelete, titleVisibility: .visible) {
                    Button("Delete Column", role: .destructive) {
                        guard let columnID else { return }
                        do { try store.repository.deleteKanbanColumn(collectionID: collectionID, viewID: viewID, columnID: columnID, destinationID: destinationID); store.refresh(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
        }.tint(VellixSurface.violet).preferredColorScheme(.dark).presentationDetents([.medium, .large])
    }
    private func save() {
        do {
            let color = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let columnID { try store.repository.updateKanbanColumn(collectionID: collectionID, viewID: viewID, columnID: columnID, name: name, color: color) }
            else { _ = try store.repository.addKanbanColumn(collectionID: collectionID, viewID: viewID, name: name, color: color) }
            store.refresh(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
