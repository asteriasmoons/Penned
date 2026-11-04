import SwiftUI

/// Navigates folders within the selected Penned Space.
struct FolderPickerView: View {
    let folders: [ClipperDestination]
    let selectedFolderID: String?
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var parentID: String?
    @State private var searchText = ""

    private var visibleFolders: [ClipperDestination] {
        let scoped = folders.filter { $0.parentID == parentID }
        guard !searchText.isEmpty else { return scoped }
        return scoped.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var currentFolder: ClipperDestination? {
        folders.first { $0.id == parentID }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                if let currentFolder {
                    Button {
                        parentID = currentFolder.parentID
                    } label: {
                        Label("Back to Parent", systemImage: "chevron.left")
                    }
                }

                Button {
                    onSelect(parentID)
                    dismiss()
                } label: {
                    HStack {
                        Label(parentID == nil ? "Unsorted" : "Save in This Folder", systemImage: "folder")
                        Spacer()
                        if selectedFolderID == parentID {
                            Image(systemName: "checkmark")
                                .accessibilityLabel("Selected")
                        }
                    }
                }
            }

            ForEach(visibleFolders, id: \.id) { folder in
                HStack(spacing: 12) {
                    Button {
                        onSelect(folder.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(folder.title)
                            Spacer()
                            if selectedFolderID == folder.id {
                                Image(systemName: "checkmark")
                                    .accessibilityLabel("Selected")
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if folders.contains(where: { $0.parentID == folder.id }) {
                        Button {
                            parentID = folder.id
                            searchText = ""
                        } label: {
                            Image(systemName: "chevron.right")
                                .frame(minWidth: 32, minHeight: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(folder.title)")
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search Current Folder")
        .navigationTitle(currentFolder?.title ?? "Choose Folder")
        .navigationBarTitleDisplayMode(.inline)
    }
}
