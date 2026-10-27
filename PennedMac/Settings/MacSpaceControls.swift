// Mac-target platform adapter. Based on Vellix/Spaces/SpaceViews.swift.
// iPhone/iPad implementations remain in their original target.
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct SpaceManagementView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var showArchived = false
    @State private var deleteTarget: SpaceRecord?
    private var spaces: [SpaceRecord] { environment.allSpaces.filter { showArchived || !$0.isArchived } }
    var body: some View {
        List {
            Section {
                ForEach(spaces) { space in
                    HStack(spacing: 12) {
                        Button {
                            guard !space.isArchived else { environment.spaceSheet = .edit(space); return }
                            perform { try await environment.switchSpace(to: space.id) }
                        } label: {
                            HStack(spacing: 12) {
                                SpaceImage(space: space, size: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(space.title).foregroundStyle(.primary)
                                    if let description = space.spaceDescription, !description.isEmpty { Text(description).font(.caption).foregroundStyle(.secondary) }
                                    if space.isArchived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if space.id == environment.selectedSpaceID { LibraryIcon(name: "checkwavy", size: 18) }
                            }.frame(minHeight: 48).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        MacPopoverMenu { actions(space) } label: { LibraryIcon(name: "dotswavy", size: 21).frame(width: 40, height: 44) }
                            .macIconMenuStyle()
                            .accessibilityLabel("Actions for \(space.title)")
                    }.contextMenu { actions(space) }
                }.onMove { indices, destination in
                    var reordered = spaces
                    reordered.move(fromOffsets: indices, toOffset: destination)
                    do {
                        for (position, var space) in reordered.enumerated() { space.sortOrder = Double(position); try environment.spaces.save(space) }
                        environment.refresh()
                    } catch { environment.report(error) }
                }
                Button(action: environment.createSpace) { Label { Text("New Space") } icon: { LibraryIcon(name: "addwavy", size: 19) } }
            }
            Section { Toggle("Show Archived Spaces", isOn: $showArchived) }
        }
        .navigationTitle("Spaces").tint(VellixSurface.accent)
        #if os(iOS)
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        #endif
        .disabled(environment.isSwitchingSpace)
        .macConfirmationDialog("Permanently delete \(deleteTarget?.title ?? "this Space")?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("Delete Space and All Contents", role: .destructive) {
                guard let space = deleteTarget else { return }
                deleteTarget = nil; perform { try await environment.deleteSpace(space.id) }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { Text("All documents, nested pages, folders, collections, templates, event notes, reminders, attachments, history, and Trash in this Space will be permanently deleted. Other Spaces and global saved styles will not be deleted.") }
    }
    @ViewBuilder private func actions(_ space: SpaceRecord) -> some View {
        Button("Edit Name, Icon and Description") { environment.spaceSheet = .edit(space) }
        Button(space.isArchived ? "Restore Space" : "Archive Space") { perform { try await environment.archiveSpace(space.id, archived: !space.isArchived) } }
        Button("Delete Space", role: .destructive) { deleteTarget = space }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { environment.report(error) } }
    }
}

struct SpaceEditorSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let original: SpaceRecord?
    @State private var name: String
    @State private var description: String
    @State private var iconImageData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var importingFile = false
    @State private var importing = false
    @State private var importTask: Task<Void, Never>?
    @State private var importID = UUID()
    @State private var saving = false
    @State private var error: String?
    init(space: SpaceRecord?) {
        original = space
        _name = State(initialValue: space?.title ?? "")
        _description = State(initialValue: space?.spaceDescription ?? "")
        _iconImageData = State(initialValue: space?.iconImageData)
    }
    var body: some View {
        NavigationStack {
            MacForm {
                TextField("Space name", text: $name).pennedSheetRows(showsSeparator: true)
                TextField("Description", text: $description, axis: .vertical).pennedSheetRows()
                Section("Space Image") {
                    SpaceImage(data: iconImageData, title: name, size: 88)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .pennedSheetRows(showsSeparator: true)
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label { Text("Choose Photo") } icon: { LibraryIcon(name: "imagesign", size: 20) }
                    }.disabled(importing || saving).pennedSheetRows(showsSeparator: true)
                    Button { importingFile = true } label: {
                        Label { Text("Upload Image from Files") } icon: { LibraryIcon(name: "openedfolder", size: 20) }
                    }.disabled(importing || saving).pennedSheetRows(showsSeparator: iconImageData != nil)
                    if iconImageData != nil {
                        Button("Remove Image", role: .destructive) { iconImageData = nil }.disabled(importing || saving)
                    }
                }.pennedSheetRows()
                if let error { Text(error).foregroundStyle(.red).pennedSheetRows() }
            }.navigationTitle(original == nil ? "New Space" : "Edit Space")
                .pennedSheet(title: original == nil ? "New Space" : "Edit Space", closeDisabled: saving, close: { dismiss() }) {
                    Button("Save") {
                        saving = true
                        var space = original ?? SpaceRecord(title: name)
                        space.title = name; space.spaceDescription = description.trimmedNonEmpty
                        space.icon = nil; space.iconImageData = iconImageData
                        Task {
                            defer { saving = false }
                            do { try await environment.saveSpace(space, isNew: original == nil); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(saving || importing || name.trimmedNonEmpty == nil)
                }
        }.tint(VellixSurface.accent).interactiveDismissDisabled(saving)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                startImport { try await item.loadTransferable(type: Data.self) }
                photoItem = nil
            }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url):
                    startImport {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try await Task.detached {
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size <= SpaceIconImage.maximumInputBytes else {
                                throw VellixError.attachmentImport("Choose an image smaller than 20 MB.")
                            }
                            return try Data(contentsOf: url, options: .mappedIfSafe)
                        }.value
                    }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            .onDisappear { importID = UUID(); importTask?.cancel() }
    }

    private func startImport(_ load: @escaping @MainActor () async throws -> Data?) {
        importTask?.cancel()
        let request = UUID(); importID = request; importing = true; error = nil
        importTask = Task {
            defer { if importID == request { importing = false } }
            do {
                guard let data = try await load() else { throw VellixError.attachmentImport("The image could not be loaded.") }
                let prepared = try await Task.detached { try SpaceIconImage.prepare(data) }.value
                guard !Task.isCancelled, importID == request else { return }
                iconImageData = prepared
            } catch {
                if !Task.isCancelled, importID == request { self.error = error.localizedDescription }
            }
        }
    }
}

struct SpaceTransferSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let item: SpaceContent
    let copy: Bool
    @State private var destination: String?
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            MacForm {
                Section("Destination Space") {
                    if environment.allSpaces.filter({ !$0.isArchived && $0.id != environment.selectedSpaceID }).isEmpty {
                        Text("No other active Spaces").foregroundStyle(.secondary)
                    }
                    ForEach(environment.allSpaces.filter { !$0.isArchived && $0.id != environment.selectedSpaceID }) { space in
                        Button { destination = space.id } label: {
                            HStack {
                                SpaceImage(space: space, size: 28)
                                Text(space.title).frame(maxWidth: .infinity, alignment: .leading)
                                if destination == space.id { LibraryIcon(name: "checkwavy", size: 18) }
                            }.frame(minHeight: 40)
                        }.pennedSheetRows(showsSeparator: space.id != environment.allSpaces.last(where: { !$0.isArchived && $0.id != environment.selectedSpaceID })?.id)
                    }
                }.pennedSheetRows()
                if let error { Text(error).foregroundStyle(.red).pennedSheetRows() }
            }.navigationTitle(copy ? "Copy to Space" : "Move to Space")
                .pennedSheet(title: copy ? "Copy to Space" : "Move to Space", closeDisabled: saving, close: { dismiss() }) {
                    Button(copy ? "Copy" : "Move") {
                        guard let destination else { return }
                        saving = true
                        Task {
                            defer { saving = false }
                            do { try await environment.transferSpaceContent(item, to: destination, copy: copy); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(saving || destination == nil)
                }
        }.tint(VellixSurface.accent).interactiveDismissDisabled(saving)
    }
}

struct SpaceTransferActions: View {
    @EnvironmentObject private var environment: AppEnvironment
    let item: SpaceContent
    var body: some View {
        Button("Move to Space") { environment.spaceSheet = .transfer(item, false) }
        Button("Copy to Space") { environment.spaceSheet = .transfer(item, true) }
    }
}
