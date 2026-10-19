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
    var spaceID: String?

    init(database: AppDatabase) {
        self.database = database
    }

    func search(_ query: String, includeTrash: Bool = false) throws -> [SearchResult] {
        guard let searchQuery = Self.ftsQuery(from: query) else {
            return []
        }

        return try database.read { db in
            let hierarchy = FolderHierarchy(folders: try FolderRecord.fetchAll(db, sql: "SELECT * FROM folders WHERE \(LibraryAccess.spaces()) AND (? IS NULL OR spaceID=?)", arguments: [spaceID, spaceID]))
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        d.id AS documentID,
                        d.title AS title,
                        d.previewText AS fallbackPreview,
                        d.icon AS icon,
                        d.updatedAt AS updatedAt,
                        d.isFavorite AS isFavorite,
                        d.folderID AS folderID,
                        s.title AS spaceTitle,
                        snippet(documentSearch, 3, '', '', '...', 14) AS excerpt
                    FROM documentSearch
                    JOIN documents d ON d.id = documentSearch.documentID
                    LEFT JOIN spaces s ON s.id = d.spaceID
                    WHERE documentSearch MATCH ?
                      AND \(LibraryAccess.spaces("d.spaceID"))
                      AND d.templateID IS NULL
                      AND (? OR d.isTrashed = 0)
                      AND (? IS NULL OR d.spaceID = ?)
                    ORDER BY rank
                    LIMIT 50
                    """,
                arguments: [searchQuery, includeTrash, spaceID, spaceID]
            )
            .map { row in
                let folderID: String? = row["folderID"]
                let folderPath = folderID.map { hierarchy.path(to: $0).map(\.title) } ?? []
                let location = ([row["spaceTitle"] as String?].compactMap { $0 } + folderPath)
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
                    WHERE \(LibraryAccess.spaces()) AND (lower(title) LIKE ? OR lower(templateDescription) LIKE ?) AND (? IS NULL OR spaceID=?)
                    ORDER BY title ASC
                    """,
                arguments: ["%\(normalized)%", "%\(normalized)%", spaceID, spaceID]
            )
        }
    }

    nonisolated static func matchingDocumentIDs(_ query: String, titleOnly: Bool, spaceID: String?, in db: Database) throws -> Set<String> {
        guard let expression = ftsQuery(from: query) else { return [] }
        let match = titleOnly ? "title : (\(expression))" : expression
        return Set(try String.fetchAll(db, sql: """
            SELECT d.id FROM documentSearch JOIN documents d ON d.id=documentSearch.documentID
            WHERE documentSearch MATCH ? AND d.templateID IS NULL AND d.isTrashed=0 AND d.isArchived=0
            AND \(LibraryAccess.spaces("d.spaceID"))
            AND (? IS NULL OR d.spaceID=?)
            """, arguments: [match, spaceID, spaceID]))
    }

    private nonisolated static func ftsQuery(from query: String) -> String? {
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
