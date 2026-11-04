import SwiftUI

/// Lets the user choose one of the Spaces published by Penned.
struct SpacePickerView: View {
    let spaces: [ClipperDestination]
    let selectedSpaceID: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredSpaces: [ClipperDestination] {
        guard !searchText.isEmpty else { return spaces }
        return spaces.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filteredSpaces, id: \.id) { space in
                Button {
                    onSelect(space.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                        Text(space.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if space.id == selectedSpaceID {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .accessibilityLabel("Selected")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if filteredSpaces.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: "Search Spaces")
        .navigationTitle("Choose Space")
        .navigationBarTitleDisplayMode(.inline)
    }
}
