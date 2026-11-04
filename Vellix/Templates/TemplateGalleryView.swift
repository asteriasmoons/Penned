import SwiftUI

/// Browses personal and public templates without creating documents on card tap.
struct TemplateGalleryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let categories: [GalleryCategory]
    let publicTemplates: [GalleryTemplate]
    let publicDocuments: [String: DocumentRecord]
    let usePersonalTemplate: (TemplateRecord) -> Void
    let usePublicTemplate: (GalleryTemplate) -> Void
    let loadPublicPackage: (GalleryTemplate) async throws -> TemplateGalleryPackage
    let close: () -> Void
    let allowsManagement: Bool
    let isPublisher: Bool
    let publish: (TemplateRecord) async throws -> Void
    let update: (GalleryTemplate, String, String, String) -> Void
    let replaceTemplate: (GalleryTemplate) -> Void
    let removeTemplate: (GalleryTemplate) -> Void
    let createCategory: (String) -> Void
    let renameCategory: (GalleryCategory, String) -> Void
    let removeCategory: (GalleryCategory) -> Void

    @State private var searchText = ""
    @State private var selection: Selection?
    @State private var loadingTemplateID: String?
    @State private var fetchedPublicDocuments: [String: DocumentRecord] = [:]
    @State private var previewError: String?
    @State private var showCategoryEditor = false
    @State private var editingTemplate: GalleryTemplate?
    @State private var categoryError: String?
    @State private var savingTemplateIDs: Set<String> = []
    @State private var savedTemplateIDs: Set<String> = []
    @State private var saveError: String?
    @State private var saveConfirmation: String?
    @State private var publishingTemplateID: String?
    @State private var publishError: String?
    @State private var publishConfirmation: String?

    private var personalTemplates: [(template: TemplateRecord, document: DocumentRecord)] {
        environment.personalGalleryTemplates()
    }

    private var canManageCategories: Bool { allowsManagement && isPublisher }

    private var publicCategories: [GalleryCategory] {
        TemplateGalleryAuthorization.visibleCategories(categories, isPublisher: isPublisher)
    }

    // A personal template is grouped by its own stored category so it lands in the
    // right section immediately, without waiting for the managed category list to load
    // (that async gap is what made cards flash under Unsorted and then jump). Categories
    // are still only CREATED through Manage Categories; this is display grouping only.
    private func personalCategory(_ template: TemplateRecord) -> String {
        let value = template.category.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty
            || value.caseInsensitiveCompare("Mine") == .orderedSame
            || value.caseInsensitiveCompare(TemplateRepository.myTemplatesCategory) == .orderedSame {
            return TemplateRepository.unsortedCategory
        }
        return value
    }

    private var sectionCategories: [GalleryCategory] {
        let unsorted = categories.first { $0.title.caseInsensitiveCompare(TemplateRepository.unsortedCategory) == .orderedSame }
            ?? GalleryCategory(id: "personal-unsorted", title: TemplateRepository.unsortedCategory, sortOrder: -1)
        var result = [unsorted], names: Set<String> = [unsorted.title.lowercased()]
        for category in categories where names.insert(category.title.lowercased()).inserted { result.append(category) }
        // Include the categories templates are already assigned to so grouping never
        // waits on the managed-list load. Assignments only ever come from managed
        // categories (via Move to Category) or Unsorted, so no new category is introduced.
        for title in personalTemplates.map({ personalCategory($0.template) }).sorted()
            where names.insert(title.lowercased()).inserted {
            result.append(GalleryCategory(id: "personal-category-" + title.lowercased(), title: title))
        }
        return result
    }

    private func move(_ template: TemplateRecord, to category: String) {
        guard canManageCategories else { return }
        do {
            try environment.moveTemplateToCategory(template, category: category)
        } catch { categoryError = error.localizedDescription }
    }

    private enum Selection: Identifiable {
        case personal(TemplateRecord, DocumentRecord)
        case published(GalleryTemplate, DocumentRecord)

        var id: String {
            switch self {
            case .personal(let template, _): return "personal-" + template.id
            case .published(let template, _): return "published-" + template.id
            }
        }
    }

    private func matches(_ title: String) -> Bool {
        searchText.isEmpty || title.localizedStandardContains(searchText)
    }

    var body: some View {
        let personal = personalTemplates.filter { matches($0.template.title) }
        VStack(spacing: 0) {
            PennedSheetSearchField(text: $searchText, prompt: "Search templates")
                .padding(.horizontal, VellixSpacing.lg)
                .padding(.bottom, VellixSpacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(TemplateRepository.myTemplatesCategory)
                            .font(.headline)
                            .foregroundStyle(VellixSurface.controlInk)
                        if isPublisher {
                            ForEach(sectionCategories, id: \.title) { category in
                                let mine = personal.filter {
                                    personalCategory($0.template).caseInsensitiveCompare(category.title) == .orderedSame
                                }
                                let isUnsorted = category.title.caseInsensitiveCompare(TemplateRepository.unsortedCategory) == .orderedSame
                                // Managed categories are always visible so the full set is
                                // browsable here without opening Manage Categories; Unsorted
                                // shows only when something is actually in it.
                                if !isUnsorted || !mine.isEmpty {
                                    templateSection(category.title.uppercased()) {
                                        ForEach(mine.indices, id: \.self) { index in
                                            personalCard(mine[index].template, document: mine[index].document)
                                        }
                                    }
                                }
                            }
                        } else {
                            templateSection(nil) {
                                ForEach(personal.indices, id: \.self) { index in
                                    personalCard(personal[index].template, document: personal[index].document)
                                }
                            }
                        }
                    }
                    // Consumers browse the live catalog here. The publisher instead sees
                    // each template once under its category and manages published state
                    // from that card, so a published template never shows as a second header.
                    if !isPublisher {
                        ForEach(publicCategories) { category in
                            let templates = publicTemplates.filter {
                                $0.categoryID == category.id && matches($0.title)
                            }
                            if !templates.isEmpty {
                                templateSection(category.title.uppercased()) {
                                    ForEach(templates) { template in
                                        publishedCard(template)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(VellixSurface.controlInk)
        .pennedSheet(title: "Templates", close: close) {
            if !savingTemplateIDs.isEmpty || publishingTemplateID != nil {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(publishingTemplateID == nil ? "Saving template" : "Publishing template")
            }
            if canManageCategories {
                Menu {
                    Button("Manage Categories") { showCategoryEditor = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel("Manage Gallery")
            }
        }
        .alert("Could Not Move Template", isPresented: Binding(
            get: { categoryError != nil }, set: { if !$0 { categoryError = nil } }
        )) { Button("OK") { categoryError = nil } } message: { Text(categoryError ?? "") }
        .alert("Could Not Save Template", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) { Button("OK") { saveError = nil } } message: { Text(saveError ?? "") }
        .alert("Template Saved", isPresented: Binding(
            get: { saveConfirmation != nil }, set: { if !$0 { saveConfirmation = nil } }
        )) { Button("OK") { saveConfirmation = nil } } message: { Text(saveConfirmation ?? "") }
        .alert("Could Not Publish Template", isPresented: Binding(
            get: { publishError != nil }, set: { if !$0 { publishError = nil } }
        )) { Button("OK") { publishError = nil } } message: { Text(publishError ?? "") }
        .alert("Template Published", isPresented: Binding(
            get: { publishConfirmation != nil }, set: { if !$0 { publishConfirmation = nil } }
        )) { Button("OK") { publishConfirmation = nil } } message: { Text(publishConfirmation ?? "") }
        .alert("Template Preview Unavailable", isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) {
            Button("OK") { previewError = nil }
        } message: {
            Text(previewError ?? "The template could not be opened.")
        }
        .sheet(isPresented: $showCategoryEditor) {
            if canManageCategories {
                TemplateCategoryEditorSheet(categories: categories,
                    create: createCategory, rename: renameCategory,
                    delete: removeCategory, close: { showCategoryEditor = false })
            }
        }
        .sheet(item: $editingTemplate) { template in
            if canManageCategories {
                NavigationStack {
                    TemplateGalleryEditorSheet(mode: .edit(template), categories: categories,
                        submit: { title, description, categoryID in
                            editingTemplate = nil
                            update(template, title, description, categoryID)
                        }, cancel: { editingTemplate = nil })
                }
            }
        }
        .onChange(of: canManageCategories) { _, allowed in
            if !allowed {
                showCategoryEditor = false
                editingTemplate = nil
            }
        }
        .sheet(item: $selection) { selected in
            switch selected {
            case .personal(let template, let document):
                TemplateFullPreview(title: template.title, document: document,
                    useTemplate: { selection = nil; usePersonalTemplate(template) },
                    close: { selection = nil })
            case .published(let template, let document):
                TemplateFullPreview(title: template.title, document: document,
                    useTemplate: { selection = nil; usePublicTemplate(template) },
                    close: { selection = nil })
            }
        }
    }

    // The published copy of a personal template, if it has been published. Publishing
    // is a state of the one template, not a second gallery entry.
    private func publishedCopy(of template: TemplateRecord) -> GalleryTemplate? {
        let id = TemplateGalleryPublisher.publicationID(templateID: template.id,
                                                        libraryID: environment.database.libraryID)
        return publicTemplates.first { $0.id == id }
    }

    private func personalCard(_ template: TemplateRecord, document: DocumentRecord) -> some View {
        card(title: template.title, document: document) {
            selection = .personal(template, document)
        }
        .contextMenu {
            if canManageCategories {
                if let published = publishedCopy(of: template) {
                    Button("Unpublish Template", role: .destructive) { removeTemplate(published) }
                } else {
                    Button(publishingTemplateID == template.id ? "Publishing Template..." : "Publish Template") {
                        publishSelected(template)
                    }
                    .disabled(publishingTemplateID != nil)
                }
                Menu("Move to Category") {
                    ForEach(sectionCategories) { destination in
                        Button(destination.title) { move(template, to: destination.title) }
                    }
                }
            }
        }
    }

    private func publishSelected(_ template: TemplateRecord) {
        guard canManageCategories, publishingTemplateID == nil else { return }
        publishingTemplateID = template.id
        Task {
            defer { publishingTemplateID = nil }
            do {
                try await publish(template)
                publishConfirmation = "\(template.title) was published using its saved category."
            } catch { publishError = error.localizedDescription }
        }
    }

    private func save(_ template: GalleryTemplate) {
        guard !savingTemplateIDs.contains(template.id), !savedTemplateIDs.contains(template.id) else { return }
        savingTemplateIDs.insert(template.id)
        Task {
            defer { savingTemplateIDs.remove(template.id) }
            do {
                _ = try await environment.saveGalleryTemplate(template)
                savedTemplateIDs.insert(template.id)
                saveConfirmation = "\(template.title) was saved to My Templates."
            } catch { saveError = error.localizedDescription }
        }
    }

    private func publishedCard(_ template: GalleryTemplate) -> some View {
        Group {
            if let document = publicDocuments[template.id] ?? fetchedPublicDocuments[template.id] {
                card(title: template.title, document: document) {
                    selection = .published(template, document)
                }
            } else {
                Button { openPublicPreview(template) } label: {
                    pendingPublicCard(template)
                }
                .buttonStyle(.plain)
                .disabled(loadingTemplateID != nil)
                .task(id: template.id) {
                    guard fetchedPublicDocuments[template.id] == nil else { return }
                    if let package = try? await loadPublicPackage(template),
                       let snapshot = package.nativeSnapshot,
                       let root = snapshot.documents.first(where: { $0.id == snapshot.rootDocumentID }) {
                        fetchedPublicDocuments[template.id] = root
                    }
                }
            }
        }
        .contextMenu {
            Button(savingTemplateIDs.contains(template.id) ? "Saving Template..." :
                (savedTemplateIDs.contains(template.id) ? "Template Saved" : "Save Template")) {
                save(template)
            }
            .disabled(savingTemplateIDs.contains(template.id) || savedTemplateIDs.contains(template.id))
            if canManageCategories {
                Divider()
                Menu("Move to Category") {
                    ForEach(categories) { destination in
                        Button(destination.title) {
                            update(template, template.title, template.templateDescription, destination.id)
                        }
                        .disabled(destination.id == template.categoryID)
                    }
                }
                Button("Edit Template") { editingTemplate = template }
                Button("Update From Current Document") { replaceTemplate(template) }
                Button("Delete Template", role: .destructive) { removeTemplate(template) }
            }
        }
    }

    private func openPublicPreview(_ template: GalleryTemplate) {
        guard loadingTemplateID == nil else { return }
        loadingTemplateID = template.id
        Task {
            defer { loadingTemplateID = nil }
            do {
                let package = try await loadPublicPackage(template)
                guard let snapshot = package.nativeSnapshot,
                      let root = snapshot.documents.first(where: { $0.id == snapshot.rootDocumentID }) else {
                    throw PublishingFailure.invalidContent("This template does not include an editable preview.")
                }
                selection = .published(template, root)
            } catch {
                previewError = error.localizedDescription
            }
        }
    }

    private func templateSection<Content: View>(
        _ title: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VellixSurface.secondaryInk)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                GridItem(.flexible(), spacing: 14)], spacing: 18, content: content)
        }
    }

    private func pendingPublicCard(_ template: GalleryTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(VellixSurface.previewPlaceholder)
                .aspectRatio(0.9, contentMode: .fit)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text").font(.system(size: 28))
                        Text(loadingTemplateID == template.id ? "Loading" : "Preview")
                            .font(.caption)
                    }
                    .foregroundStyle(VellixSurface.secondaryInk)
                }
            Text(template.title)
                .font(.subheadline)
                .foregroundStyle(VellixSurface.controlInk.opacity(0.65))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(template.title)
    }

    private func card(title: String, document: DocumentRecord,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                TemplateGalleryThumbnail(document: document)
                    .aspectRatio(0.9, contentMode: .fit)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(VellixSurface.controlInk.opacity(0.65))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
