import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LibraryFolderIcon: View {
    let folder: FolderRecord
    var size: CGFloat = 24

    var body: some View {
        LibraryIcon(name: VellixAssetIconLibrary.names.contains(folder.icon ?? "") ? (folder.icon ?? "linesfolderfill") : "linesfolderfill", size: size)
            .foregroundStyle(Color(vellixHex: folder.iconColorHex ?? "#909090"))
    }
}

struct LibraryFolderTile: View {
    let folder: FolderRecord
    let itemCount: Int
    var isSelected = false

    var body: some View {
        VStack(spacing: 8) {
            LibraryFolderIcon(folder: folder, size: 27)
            Text(folder.title).font(.system(size: 17, weight: .semibold)).lineLimit(1).multilineTextAlignment(.center)
            Text("\(itemCount) \(itemCount == 1 ? "Item" : "Items")").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 16)
        .frame(maxWidth: .infinity).frame(height: 112)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if isSelected { RoundedRectangle(cornerRadius: 14).strokeBorder(VellixSurface.accent, lineWidth: 2) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct FolderContextMenu: View {
    @EnvironmentObject private var environment: AppEnvironment
    let folder: FolderRecord

    var body: some View {
        Button("Open") { environment.openFolder(folder.id) }
        Button("New Child Folder") { environment.requestFolderCreation(parentFolderID: folder.id) }
        Button("Edit Name and Icon") { environment.editFolder(folder) }
        Button("Move Folder") { environment.requestMove(folderIDs: [folder.id]) }
    }
}

struct FolderEditorSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let request: FolderEditorRequest
    @State private var name: String
    @State private var icon: String
    @State private var color: Color
    @State private var picker: PickerSheet?
    @State private var errorMessage: String?

    private enum PickerSheet: String, Identifiable {
        case icon, color
        var id: String { rawValue }
    }

    init(request: FolderEditorRequest) {
        self.request = request
        _name = State(initialValue: request.folder?.title ?? "New Folder")
        let asset = request.folder?.icon ?? "linesfolderfill"
        _icon = State(initialValue: VellixAssetIconLibrary.names.contains(asset) ? asset : "linesfolderfill")
        _color = State(initialValue: Color(vellixHex: request.folder?.iconColorHex ?? "#909090"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder name", text: $name)
                    Button { picker = .icon } label: {
                        HStack {
                            Text("Icon")
                            Spacer()
                            LibraryIcon(name: icon, size: 26).foregroundStyle(color)
                            LibraryIcon(name: "chevright", size: 12).foregroundStyle(.secondary)
                        }
                    }
                    Button { picker = .color } label: {
                        HStack {
                            Text("Icon Color")
                            Spacer()
                            Circle().fill(color).frame(width: 26, height: 26)
                            LibraryIcon(name: "chevright", size: 12).foregroundStyle(.secondary)
                        }
                    }
                }
                if let parent = environment.overview.folders.first(where: { $0.id == request.parentFolderID }) {
                    Section("Parent Folder") {
                        HStack(spacing: 10) {
                            LibraryFolderIcon(folder: parent, size: 20)
                            Text(parent.title)
                        }
                    }
                }
            }
            .navigationTitle(request.folder == nil ? "New Folder" : "Edit Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try environment.saveFolder(request, title: name, icon: icon,
                                colorHex: color.vellixHexString(fallback: "#909090"))
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .sheet(item: $picker) { selection in
            switch selection {
            case .icon:
                VellixIconLibraryPicker(title: "Folder Icon") { selected in
                    icon = selected.name
                    picker = nil
                }
                .presentationDetents([.medium, .large])
            case .color:
                #if os(iOS)
                FolderIconColorPicker(selection: $color) { picker = nil }
                #else
                NavigationStack {
                    Form { ColorPicker("Icon Color", selection: $color, supportsOpacity: false) }
                        .navigationTitle("Icon Color")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { picker = nil } } }
                }
                #endif
            }
        }
        .alert("Folder Could Not Be Saved", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }
}

struct FolderDestinationPicker: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let request: LibraryMoveRequest
    @State private var query = ""
    @State private var destinationID: String?
    @State private var errorMessage: String?

    private var hierarchy: FolderHierarchy { FolderHierarchy(folders: environment.overview.folders) }
    private var excludedIDs: Set<String> { hierarchy.descendants(including: request.folderIDs) }
    private var destinations: [FolderRecord] {
        environment.overview.folders.filter { folder in
            !excludedIDs.contains(folder.id) && (query.isEmpty || path(for: folder).localizedCaseInsensitiveContains(query))
        }.sorted { path(for: $0).localizedStandardCompare(path(for: $1)) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                destinationRow(title: request.folderIDs.isEmpty ? "Unsorted" : "Home", folder: nil)
                ForEach(destinations) { folder in destinationRow(title: path(for: folder), folder: folder) }
            }
            .searchable(text: $query, prompt: "Search folders")
            .navigationTitle("Move To")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        do {
                            try environment.moveLibraryItems(request, to: destinationID)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
        }
        .alert("Items Could Not Be Moved", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func path(for folder: FolderRecord) -> String {
        hierarchy.path(to: folder.id).map(\.title).joined(separator: " / ")
    }

    private func destinationRow(title: String, folder: FolderRecord?) -> some View {
        Button { destinationID = folder?.id } label: {
            HStack(spacing: 12) {
                if let folder { LibraryFolderIcon(folder: folder) }
                else { LibraryIcon(name: "openedfolder").foregroundStyle(.secondary) }
                Text(title).foregroundStyle(.primary)
                Spacer()
                if destinationID == folder?.id { LibraryIcon(name: "checkwavy").foregroundStyle(VellixSurface.accent) }
            }
            .frame(minHeight: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#if os(iOS)
private struct FolderIconColorPicker: UIViewControllerRepresentable {
    @Binding var selection: Color
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let controller = UIColorPickerViewController()
        controller.title = "Icon Color"
        controller.supportsAlpha = false
        controller.selectedColor = UIColor(selection)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
        let selected = UIColor(selection)
        if controller.selectedColor != selected { controller.selectedColor = selected }
    }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: FolderIconColorPicker
        init(parent: FolderIconColorPicker) { self.parent = parent }
        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            parent.selection = Color(uiColor: color)
        }
        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) { parent.onFinish() }
    }
}
#endif
