import SwiftUI

/// Publisher-only form. The caller is responsible for authenticated submission.
struct TemplateGalleryEditorSheet: View {
    enum Mode {
        case publish
        case edit(GalleryTemplate)
    }

    let mode: Mode
    let categories: [GalleryCategory]
    let submit: (_ title: String, _ description: String, _ categoryID: String) -> Void
    let cancel: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var categoryID: String

    init(mode: Mode, categories: [GalleryCategory],
         submit: @escaping (String, String, String) -> Void,
         cancel: @escaping () -> Void) {
        self.mode = mode
        self.categories = categories
        self.submit = submit
        self.cancel = cancel
        switch mode {
        case .publish:
            _title = State(initialValue: "")
            _description = State(initialValue: "")
            _categoryID = State(initialValue: categories.first?.id ?? "")
        case .edit(let template):
            _title = State(initialValue: template.title)
            _description = State(initialValue: template.templateDescription)
            _categoryID = State(initialValue: template.categoryID)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Template Details") {
                TextField("Template Name", text: $title)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...5)
            }
            Section("Category") {
                Picker("Category", selection: $categoryID) {
                    ForEach(categories) { category in
                        Text(category.title).tag(category.id)
                    }
                }
            }
            Section {
                Button(isEditing ? "Save Changes" : "Publish Template") {
                    submit(title.trimmingCharacters(in: .whitespacesAndNewlines),
                           description.trimmingCharacters(in: .whitespacesAndNewlines),
                           categoryID)
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !categories.contains(where: { $0.id == categoryID }))
            }
        }
        .navigationTitle(isEditing ? "Edit Template" : "Publish Template")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel)
            }
        }
    }
}
