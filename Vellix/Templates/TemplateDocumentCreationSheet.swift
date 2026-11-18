import SwiftUI

/// Library creation is separate from the document editor's caret-insertion gallery.
struct TemplateDocumentCreationSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var categories: [GalleryCategory] = []
    @State private var templates: [GalleryTemplate] = []
    @State private var creating = false
    @State private var errorMessage: String?

    var body: some View {
        TemplateGalleryView(
            categories: categories, publicTemplates: templates, publicDocuments: [:],
            usePersonalTemplate: { template in
                guard !creating else { return }
                if environment.createDocument(title: template.title, from: template) != nil {
                    dismiss()
                } else {
                    errorMessage = environment.errorMessage ?? "The document could not be created."
                    environment.errorMessage = nil
                }
            },
            usePublicTemplate: { template in
                guard !creating else { return }
                creating = true
                Task {
                    defer { creating = false }
                    do {
                        _ = try await environment.createDocument(fromGallery: template)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
            },
            loadPublicPackage: { try await environment.templateGalleryCloud.fetchPackage(templateID: $0.id, expectedRevision: $0.revision) },
            close: { if !creating { dismiss() } },
            allowsManagement: false, isPublisher: environment.canPublishTemplates,
            // Management callbacks are unreachable in this document-creation context.
            publish: { _ in }, update: { _, _, _, _ in }, replaceTemplate: { _ in },
            removeTemplate: { _ in }, createCategory: { _ in },
            renameCategory: { _, _ in }, removeCategory: { _ in })
        .disabled(creating)
        .overlay {
            if creating {
                ProgressView("Creating Document")
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .interactiveDismissDisabled(creating)
        .alert("Could Not Create Document", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .task {
            categories = (try? environment.templateGallery.categories()) ?? []
            templates = (try? environment.templateGallery.templates()) ?? []
            do {
                async let freshCategories = environment.templateGalleryCloud.fetchCategories()
                async let freshTemplates = environment.templateGalleryCloud.fetchTemplates()
                let fresh = try await (freshCategories, freshTemplates)
                try Task.checkCancellation()
                categories = fresh.0
                templates = fresh.1
                try? environment.templateGallery.replaceCatalog(categories: categories, templates: templates)
            } catch { /* Personal templates and the cached catalogue remain available offline. */ }
        }
    }
}
