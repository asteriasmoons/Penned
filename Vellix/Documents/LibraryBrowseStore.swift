import Combine
import SwiftUI

// Drives database-level, keyset-paginated browsing for the large library surfaces
// (All Docs and a single folder). It holds only the window of DocumentSummary rows
// loaded so far and fetches the next page from the database as the user scrolls —
// never the whole library, and never any document body. Filtering and sorting are
// pushed into the query, so they apply across the entire library including rows not
// yet loaded.
@MainActor
final class LibraryBrowseStore: ObservableObject {
    enum Scope: Equatable {
        case all
        case folder(String?)   // nil == the "Unsorted" bucket
    }

    @Published private(set) var items: [DocumentSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var reachedEnd = false

    private var documents: DocumentRepository?
    private let pageSize: Int
    private let prefetchMargin: Int

    private var scope: Scope = .all
    private var sort: DocumentSummarySort = .updated
    private var query = ""
    private var searchesBody = false
    private var signature: String?
    private var generation = 0

    init(pageSize: Int = 48, prefetchMargin: Int = 12) {
        self.pageSize = pageSize
        self.prefetchMargin = prefetchMargin
    }

    func attach(_ documents: DocumentRepository) {
        if self.documents == nil { self.documents = documents }
    }

    // Reconfigures the browse parameters and reloads from the first page only when
    // something actually changed, so ordinary view updates don't re-query.
    func configure(scope: Scope, sort: DocumentSummarySort, query: String, searchesBody: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = Self.signature(scope: scope, sort: sort, query: trimmed, searchesBody: searchesBody)
        guard next != signature else { return }
        signature = next
        self.scope = scope
        self.sort = sort
        self.query = trimmed
        self.searchesBody = searchesBody
        reload()
    }

    func reload() {
        generation += 1
        items = []
        reachedEnd = false
        isLoading = false
        loadNextPage()
    }

    // In-place refresh used after ordinary document mutations (star, trash,
    // duplicate, rename, move, metadata change). It re-fetches the currently loaded
    // range from the database with the same keyset order and replaces `items`,
    // WITHOUT resetting to an empty first page. Because the list is identified by
    // document id, SwiftUI diffs the result — removed rows disappear, added/reordered
    // rows move — while the user's scroll position is preserved. Never materializes
    // the whole library: it fetches only as many rows as are already loaded.
    func refresh() {
        guard let documents, !items.isEmpty else {
            // Nothing loaded yet; a normal first-page load is correct.
            if !items.isEmpty { return }
            loadNextPage()
            return
        }
        generation += 1
        let token = generation
        let target = max(items.count, pageSize)
        var refreshed: [DocumentSummary] = []
        var seen = Set<String>()
        var cursor: DocumentSummary? = nil
        var ended = false
        do {
            while refreshed.count < target {
                let page = try fetch(from: documents, after: cursor)
                if page.isEmpty { ended = true; break }
                for row in page where seen.insert(row.id).inserted { refreshed.append(row) }
                cursor = page.last
                if page.count < pageSize { ended = true; break }
            }
        } catch {
            // Keep the existing window rather than clearing it on a transient error.
            return
        }
        guard token == generation else { return }
        items = refreshed
        reachedEnd = ended
        isLoading = false
    }

    // Called as cells appear; loads the next page when the user nears the end.
    func loadMoreIfNeeded(current: DocumentSummary) {
        guard !reachedEnd, !isLoading,
              let index = items.firstIndex(where: { $0.id == current.id }),
              index >= items.count - prefetchMargin else { return }
        loadNextPage()
    }

    private func loadNextPage() {
        guard !reachedEnd, !isLoading, let documents else { return }
        isLoading = true
        let token = generation
        let cursor = items.last
        do {
            let page = try fetch(from: documents, after: cursor)
            guard token == generation else { return }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: page.filter { !existing.contains($0.id) })
            if page.count < pageSize { reachedEnd = true }
        } catch {
            // A failed page should not wedge the list; stop paginating this run.
            reachedEnd = true
        }
        if token == generation { isLoading = false }
    }

    private func fetch(from documents: DocumentRepository, after cursor: DocumentSummary?) throws -> [DocumentSummary] {
        switch scope {
        case .all:
            return try documents.topLevelSummaries(sort: sort, query: query, searchesBody: searchesBody, after: cursor, limit: pageSize)
        case .folder(let id):
            return try documents.folderSummaries(folderID: id, sort: sort, query: query, searchesBody: searchesBody, after: cursor, limit: pageSize)
        }
    }

    private static func signature(scope: Scope, sort: DocumentSummarySort, query: String, searchesBody: Bool) -> String {
        let scopeKey: String
        switch scope {
        case .all: scopeKey = "all"
        case .folder(let id): scopeKey = "folder:" + (id ?? "__unsorted")
        }
        let sortKey: String
        switch sort {
        case .updated: sortKey = "updated"
        case .created: sortKey = "created"
        case .title: sortKey = "title"
        }
        return [scopeKey, sortKey, query, searchesBody ? "body" : "title"].joined(separator: "|")
    }
}
