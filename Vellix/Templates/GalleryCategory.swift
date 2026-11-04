import Foundation
import GRDB

/// A publisher-managed category in Penned's shared template gallery.
struct GalleryCategory: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "galleryCategories"

    var id: String
    var title: String
    var sortOrder: Double
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, title: String, sortOrder: Double = 0,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
