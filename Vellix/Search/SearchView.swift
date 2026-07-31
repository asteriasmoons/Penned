//
//  SearchView.swift
//  Vellix
//

import SwiftUI
import Combine

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [SearchResult] = []
    @Published var templates: [TemplateRecord] = []
    @Published var errorMessage: String?

    private let service: DocumentSearchService
    private var searchTask: Task<Void, Never>?

    init(service: DocumentSearchService) {
        self.service = service
    }

    func updateQuery(_ query: String) {
        self.query = query
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.performSearch()
        }
    }

    private func performSearch() {
        do {
            results = try service.search(query)
            templates = try service.searchableTemplates(matching: query)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model: SearchModel

    init(environment: AppEnvironment) {
        _model = StateObject(wrappedValue: SearchModel(service: environment.search))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VellixSpacing.xl) {
                VStack(alignment: .leading, spacing: VellixSpacing.md) {
                    Text("Search")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(VellixSurface.ink)
                    searchField
                }

                if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VellixEmptyState(
                        title: "Find anything",
                        message: "Search page titles, saved content, previews, spaces, folders, and templates.",
                        systemImage: "magnifyingglass",
                        actionTitle: nil,
                        action: nil
                    )
                    .frame(minHeight: 420)
                    .vellixPaper()
                } else if model.results.isEmpty && model.templates.isEmpty {
                    VellixEmptyState(
                        title: "No results",
                        message: "Try another title, phrase, or template name.",
                        systemImage: "doc.text.magnifyingglass",
                        actionTitle: nil,
                        action: nil
                    )
                    .frame(minHeight: 420)
                    .vellixPaper()
                } else {
                    if !model.results.isEmpty {
                        resultSection(title: "Pages") {
                            ForEach(model.results) { result in
                                SearchResultRow(result: result)
                                    .contentShape(RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous))
                                    .onTapGesture {
                                        if let document = try? environment.documents.requireDocument(id: result.documentID) {
                                            environment.select(document)
                                        }
                                    }
                            }
                        }
                    }

                    if !model.templates.isEmpty {
                        resultSection(title: "Templates") {
                            ForEach(model.templates) { template in
                                TemplateResultRow(template: template) {
                                    _ = environment.createDocument(title: template.title, from: template)
                                }
                            }
                        }
                    }
                }
            }
            .padding(VellixSpacing.xl)
        }
        .background(VellixBackground())
        .navigationTitle("Search")
    }

    private var searchField: some View {
        HStack(spacing: VellixSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search pages and templates", text: Binding(
                get: { model.query },
                set: { model.updateQuery($0) }
            ))
            .textFieldStyle(.plain)
            .font(.title3)
        }
        .padding(.horizontal, VellixSpacing.lg)
        .padding(.vertical, 16)
        .vellixPaper(cornerRadius: VellixRadius.md)
    }

    private func resultSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: VellixSpacing.md) {
            VellixSectionHeader(
                title: title,
                subtitle: nil,
                actionTitle: nil,
                action: nil
            )
            LazyVStack(spacing: VellixSpacing.sm) {
                content()
            }
        }
    }
}

struct SearchResultRow: View {
    var result: SearchResult

    var body: some View {
        HStack(spacing: VellixSpacing.md) {
            IconTile(systemName: result.icon, size: 38, tint: result.isFavorite ? VellixSurface.gold : VellixSurface.accent)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(result.title)
                        .font(.headline)
                        .foregroundStyle(VellixSurface.ink)
                    if result.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(VellixSurface.gold)
                    }
                }
                Text(result.excerpt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(result.locationPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(VellixSpacing.md)
        .vellixPaper(cornerRadius: VellixRadius.md)
    }
}

struct TemplateResultRow: View {
    var template: TemplateRecord
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: VellixSpacing.md) {
                IconTile(systemName: template.icon, size: 38, tint: VellixSurface.teal)
                VStack(alignment: .leading, spacing: 5) {
                    Text(template.title)
                        .font(.headline)
                        .foregroundStyle(VellixSurface.ink)
                    Text(template.templateDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(VellixSurface.teal)
            }
            .padding(VellixSpacing.md)
            .vellixPaper(cornerRadius: VellixRadius.md)
        }
        .buttonStyle(.plain)
    }
}
