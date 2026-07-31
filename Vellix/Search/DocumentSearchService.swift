//
//  DocumentSearchService.swift
//  Vellix
//

import Foundation
import GRDB

struct SearchResult: Identifiable, Hashable {
    var id: String { documentID }
    var documentID: String
    var title: String
    var excerpt: String
    var icon: String?
    var locationPath: String
    var updatedAt: Date
    var isFavorite: Bool
}

final class DocumentSearchService: @unchecked Sendable {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func search(_ query: String, includeTrash: Bool = false) throws -> [SearchResult] {
        guard let searchQuery = Self.ftsQuery(from: query) else {
            return []
        }

        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        d.id AS documentID,
                        d.title AS title,
                        d.previewText AS fallbackPreview,
                        d.icon AS icon,
                        d.updatedAt AS updatedAt,
                        d.isFavorite AS isFavorite,
                        s.title AS spaceTitle,
                        f.title AS folderTitle,
                        snippet(documentSearch, 3, '', '', '...', 14) AS excerpt
                    FROM documentSearch
                    JOIN documents d ON d.id = documentSearch.documentID
                    LEFT JOIN spaces s ON s.id = d.spaceID
                    LEFT JOIN folders f ON f.id = d.folderID
                    WHERE documentSearch MATCH ?
                      AND (? OR d.isTrashed = 0)
                    ORDER BY rank
                    LIMIT 50
                    """,
                arguments: [searchQuery, includeTrash]
            )
            .map { row in
                let location = [row["spaceTitle"] as String?, row["folderTitle"] as String?]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")

                let excerpt = (row["excerpt"] as String?)?.trimmedNonEmpty
                    ?? (row["fallbackPreview"] as String?)?.trimmedNonEmpty
                    ?? "No content yet"

                return SearchResult(
                    documentID: row["documentID"],
                    title: row["title"],
                    excerpt: excerpt,
                    icon: row["icon"],
                    locationPath: location.isEmpty ? "Library" : location,
                    updatedAt: row["updatedAt"],
                    isFavorite: row["isFavorite"]
                )
            }
        }
    }

    func searchableTemplates(matching query: String) throws -> [TemplateRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return []
        }

        return try database.read { db in
            try TemplateRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM templates
                    WHERE lower(title) LIKE ? OR lower(templateDescription) LIKE ?
                    ORDER BY isBuiltIn DESC, title ASC
                    """,
                arguments: ["%\(normalized)%", "%\(normalized)%"]
            )
        }
    }

    private static func ftsQuery(from query: String) -> String? {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return nil
        }

        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }
}
