import SwiftUI

/// Publisher-only category management, styled with the Penned sheet design system.
/// Mutations are delegated to the authenticated publishing layer.
struct TemplateCategoryEditorSheet: View {
    let categories: [GalleryCategory]
    let create: (String) -> Void
    let rename: (GalleryCategory, String) -> Void
    let delete: (GalleryCategory) -> Void
    let close: () -> Void

    @State private var newCategoryName = ""
    @State private var editingCategory: GalleryCategory?
    @State private var editedName = ""
    @State private var deletingCategory: GalleryCategory?

    private var trimmedNew: String {
        newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                newCategorySection
                categoriesSection
            }
            .padding(16)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(VellixSurface.controlInk)
        .pennedSheet(title: "Manage Categories", close: close)
        .alert("Rename Category", isPresented: Binding(
            get: { editingCategory != nil },
            set: { if !$0 { editingCategory = nil } }
        )) {
            TextField("Category Name", text: $editedName)
            Button("Cancel", role: .cancel) { editingCategory = nil }
            Button("Save") {
                if let category = editingCategory {
                    let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { rename(category, name) }
                }
                editingCategory = nil
            }
        }
        .confirmationDialog("Delete this category?", isPresented: Binding(
            get: { deletingCategory != nil },
            set: { if !$0 { deletingCategory = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Category", role: .destructive) {
                if let category = deletingCategory { delete(category) }
                deletingCategory = nil
            }
            Button("Cancel", role: .cancel) { deletingCategory = nil }
        } message: {
            Text("Templates stay in your gallery; they move to Unsorted.")
        }
    }

    private var newCategorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEW CATEGORY")
                .font(.system(.caption, design: .rounded).weight(.black))
                .foregroundStyle(VellixSurface.secondaryInk)
            HStack(spacing: 10) {
                TextField("Category Name", text: $newCategoryName)
                    .submitLabel(.done)
                    .onSubmit(addCategory)
                    .font(.system(.body, design: .rounded).weight(.black))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .pennedSheetField()
                Button(action: addCategory) {
                    Text("Add")
                        .font(.system(.body, design: .rounded).weight(.black))
                        .foregroundStyle(VellixSurface.inverseInk)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)
                        .background(trimmedNew.isEmpty ? VellixSurface.disabledInk : VellixSurface.controlInk,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(trimmedNew.isEmpty)
            }
        }
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CATEGORIES")
                .font(.system(.caption, design: .rounded).weight(.black))
                .foregroundStyle(VellixSurface.secondaryInk)
            if categories.isEmpty {
                Text("No categories yet. Add one above.")
                    .font(.system(.subheadline, design: .rounded).weight(.black))
                    .foregroundStyle(VellixSurface.tertiaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                VStack(spacing: 10) {
                    ForEach(categories) { category in
                        categoryRow(category)
                    }
                }
            }
        }
    }

    private func categoryRow(_ category: GalleryCategory) -> some View {
        HStack(spacing: 12) {
            Text(category.title)
                .font(.system(.body, design: .rounded).weight(.black))
                .foregroundStyle(VellixSurface.controlInk)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                editedName = category.title
                editingCategory = category
            } label: {
                Text("Rename")
                    .font(.system(.subheadline, design: .rounded).weight(.black))
                    .foregroundStyle(PennedSheetStyle.accent)
            }
            .buttonStyle(.plain)
            Button(role: .destructive) {
                deletingCategory = category
            } label: {
                Text("Delete")
                    .font(.system(.subheadline, design: .rounded).weight(.black))
                    .foregroundStyle(VellixSurface.destructiveLabel)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .pennedSheetField()
    }

    private func addCategory() {
        guard !trimmedNew.isEmpty else { return }
        create(trimmedNew)
        newCategoryName = ""
    }
}
