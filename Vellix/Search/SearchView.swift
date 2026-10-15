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

    var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(service: DocumentSearchService) {
        self.service = service
    }

    func updateQuery(_ query: String) {
        self.query = query
        refresh()
    }

    func refresh() {
        errorMessage = nil
        guard hasQuery else {
            results = []
            templates = []
            return
        }
        do {
            results = try service.search(query)
            templates = try service.searchableTemplates(matching: query)
        } catch {
            results = []
            templates = []
            errorMessage = error.localizedDescription
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
