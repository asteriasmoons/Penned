import SwiftUI

struct TemplateInsertionRequest: Identifiable {
    let documentID: String
    let token: String
    var id: String { documentID + ":" + token }
}

/// Uses the existing gallery and native snapshot importer without changing the source template.
struct TemplateInsertionSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: DocumentEditorModel
    let request: TemplateInsertionRequest
    @State private var categories: [GalleryCategory] = []
    @State private var templates: [GalleryTemplate] = []
    @State private var inserting = false
    @State private var errorMessage: String?

    var body: some View {
        TemplateGalleryView(categories: categories, publicTemplates: templates, publicDocuments: [:],
            usePersonalTemplate: { selected in insert {
                let root = try environment.documentForTemplateEditing(selected)
                return try TemplateGalleryNativeExporter(database: environment.database, attachmentStore: environment.attachmentStore)
                    .capture(documentID: root.id)
            } },
            usePublicTemplate: { selected in insert {
                let package = try await environment.templateGalleryCloud.fetchPackage(templateID: selected.id, expectedRevision: selected.revision)
                try package.validateForImport(expectedID: selected.id, expectedRevision: selected.revision)
                guard let snapshot = package.nativeSnapshot else { throw PublishingFailure.invalidContent("This template has no editable Penned content.") }
                return snapshot
            } },
            loadPublicPackage: { try await environment.templateGalleryCloud.fetchPackage(templateID: $0.id, expectedRevision: $0.revision) },
            close: { if !inserting { model.templateInsertionRequest = nil } },
            allowsManagement: model.document?.templateID != nil, isPublisher: environment.canPublishTemplates,
                publish: { template in
                    let catalog = try await environment.publishGalleryTemplate(template)
                    categories = catalog.categories
                    templates = catalog.templates
                },
                update: { template, title, description, categoryID in
                    Task {
                        do {
                            var package = try await environment.templateGalleryCloud.fetchPackage(templateID: template.id)
                            package.title = title
                            package.document.title = title
                            if let rootIndex = package.nativeSnapshot?.documents.firstIndex(where: {
                                $0.id == package.nativeSnapshot?.rootDocumentID
                            }) {
                                package.nativeSnapshot?.documents[rootIndex].title = title
                            }
                            package.categoryID = categoryID
                            package.revision = template.revision + 1
                            try await environment.templateGalleryCloud.saveTemplate(package,
                                description: description, sortOrder: template.sortOrder, updating: true)
                            templates = try await environment.templateGalleryCloud.fetchTemplates()
                        } catch { errorMessage = error.localizedDescription }
                    }
                },
                replaceTemplate: { template in
                    Task {
                        do {
                            guard let identity = try KeychainAccountSessionStore().currentIdentity() else {
                                throw PublishingFailure.authenticationRequired
                            }
                            let publisher = TemplateGalleryPublisher(
                                database: environment.database, attachmentStore: environment.attachmentStore)
                            let package = try publisher.prepare(documentID: model.documentID,
                                categoryID: template.categoryID, title: template.title, owner: identity,
                                galleryTemplateID: template.id, revision: template.revision + 1)
                            try await environment.templateGalleryCloud.saveTemplate(package,
                                description: template.templateDescription, sortOrder: template.sortOrder, updating: true)
                            templates = try await environment.templateGalleryCloud.fetchTemplates()
                        } catch { errorMessage = error.localizedDescription }
                    }
                },
                removeTemplate: { template in
                    Task {
                        do {
                            try await environment.templateGalleryCloud.deleteTemplate(id: template.id)
                            templates = try await environment.templateGalleryCloud.fetchTemplates()
                        } catch { errorMessage = error.localizedDescription }
                    }
                },
                createCategory: { title in
                    Task {
                        do {
                            try await environment.templateGalleryCloud.saveCategory(title: title)
                            let fresh = try await environment.templateGalleryCloud.fetchCategories()
                            try? environment.templateGallery.replaceCatalog(categories: fresh, templates: templates)
                            categories = fresh
                        } catch { errorMessage = error.localizedDescription }
                    }
                },
                renameCategory: { category, title in
                    Task {
                        do {
                            try await environment.templateGalleryCloud.saveCategory(
                                id: category.id, title: title, sortOrder: category.sortOrder)
                            let fresh = try await environment.templateGalleryCloud.fetchCategories()
                            try? environment.templateGallery.replaceCatalog(categories: fresh, templates: templates)
                            categories = fresh
                        } catch { errorMessage = error.localizedDescription }
                    }
                },
                removeCategory: { category in
                    Task {
                        do {
                            try await environment.templateGalleryCloud.deleteCategory(id: category.id)
                            let fresh = try await environment.templateGalleryCloud.fetchCategories()
                            try? environment.templateGallery.replaceCatalog(categories: fresh, templates: templates)
                            categories = fresh
                        } catch { errorMessage = error.localizedDescription }
                    }
                },
            useTemplateTitle: "Insert Template")
            .disabled(inserting)
            .overlay { if inserting { ProgressView("Inserting Template").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) } }
            .interactiveDismissDisabled(inserting)
            .alert("Could Not Insert Template", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .task {
                categories = (try? environment.templateGallery.categories()) ?? []
                templates = (try? environment.templateGallery.templates()) ?? []
                do {
                    async let freshCategories = environment.templateGalleryCloud.fetchCategories()
                    async let freshTemplates = environment.templateGalleryCloud.fetchTemplates()
                    let fresh = try await (freshCategories, freshTemplates)
                    categories = fresh.0; templates = fresh.1
                    try? environment.templateGallery.replaceCatalog(categories: categories, templates: templates)
                } catch { /* Personal templates and the cached public catalogue remain available offline. */ }
            }
            .onDisappear {
                guard model.templateInsertionRequest?.id != request.id else { return }
                Task { _ = try? await model.session.attachmentCommand("templateEndInsertion", args: ["token": request.token]) }
            }
    }

    private func insert(_ snapshot: @escaping () async throws -> TemplateGalleryNativeSnapshot) {
        guard !inserting else { return }
        inserting = true
        Task {
            let operation = model.beginPersistentOperation()
            defer { inserting = false; model.endPersistentOperation(operation) }
            let importer = TemplateGalleryImporter(database: environment.database, attachmentStore: environment.attachmentStore)
            var prepared: TemplateInsertionContent?
            var mayHaveApplied = false
            do {
                let value = try await snapshot()
                guard model.documentID == request.documentID, model.templateInsertionRequest?.id == request.id,
                      try await model.session.attachmentCommand("templateInsertionAvailable", args: ["token": request.token]) as? Bool == true else {
                    throw VellixError.editorBridge("The insertion point changed. Open Templates again at the caret.")
                }
                try await model.captureAndSave()
                let content = try importer.prepareInsertion(value, into: request.documentID)
                prepared = content
                model.refreshLibraryContext()
                model.session.refreshAttachments(documentID: request.documentID, json: content.canonicalJSON)
                model.session.setCollections(environment.collections.payloads(for: request.documentID))
                let document = TipTapContentAnalyzer.documentObject(from: content.canonicalJSON)
                // A bridge failure can occur after dispatch. Never delete resources the editor may already reference.
                mayHaveApplied = true
                let inserted = try await model.session.attachmentCommand("insertTemplate", args: ["token": request.token, "document": document]) as? Bool == true
                guard inserted else {
                    mayHaveApplied = false
                    throw VellixError.editorBridge("The template could not be inserted at that position.")
                }
                try await model.captureAndSave()
                environment.refresh()
                model.templateInsertionRequest = nil
            } catch {
                if !mayHaveApplied, let prepared { try? importer.discardInsertion(prepared); model.refreshLibraryContext() }
                errorMessage = error.localizedDescription
            }
        }
    }
}
