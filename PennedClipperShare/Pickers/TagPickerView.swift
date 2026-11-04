import SwiftUI

/// Multi-select picker for existing tags in the selected Penned Space.
struct TagPickerView: View {
    let tags: [ClipperDestination]
    @Binding var selectedTagIDs: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredTags: [ClipperDestination] {
        guard !searchText.isEmpty else { return tags }
        return tags.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filteredTags, id: \.id) { tag in
                Button {
                    if selectedTagIDs.contains(tag.id) {
                        selectedTagIDs.remove(tag.id)
                    } else if selectedTagIDs.count < 100 {
                        selectedTagIDs.insert(tag.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "number")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text(tag.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: selectedTagIDs.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedTagIDs.contains(tag.id) ? Color.accentColor : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTagIDs.contains(tag.id) ? .isSelected : [])
            }
        }
        .overlay {
            if filteredTags.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: "Search Tags")
        .navigationTitle("Choose Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("\(selectedTagIDs.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.regularMaterial)
        }
    }
}
