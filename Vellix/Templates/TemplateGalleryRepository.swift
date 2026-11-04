import Foundation
import GRDB

/// Local, read-through metadata cache for the public gallery.
/// This repository never modifies the user's private template records.
final class TemplateGalleryRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func categories() throws -> [GalleryCategory] {
        try database.read { db in
            try GalleryCategory.order(Column("sortOrder").asc, Column("title").asc).fetchAll(db)
        }
    }

    func templates(in categoryID: String? = nil) throws -> [GalleryTemplate] {
        try database.read { db in
            let request = GalleryTemplate.order(Column("sortOrder").asc, Column("title").asc)
            if let categoryID {
                return try request.filter(Column("categoryID") == categoryID).fetchAll(db)
            }
            return try request.fetchAll(db)
        }
    }

    /// Replaces the cached public catalog atomically after a successful cloud fetch.
    /// Personal templates and their CloudKit sync journal are untouched.
    func replaceCatalog(categories: [GalleryCategory], templates: [GalleryTemplate]) throws {
        try database.writeMetadata { db in
            try db.inTransaction {
                try db.execute(sql: "DELETE FROM galleryTemplates")
                try db.execute(sql: "DELETE FROM galleryCategories")
                for category in categories { try category.insert(db) }
                for template in templates { try template.insert(db) }
                return .commit
            }
        }
    }
}
