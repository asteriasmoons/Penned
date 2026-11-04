import Foundation
import GRDB

/// Metadata for a published template; the document payload and assets are stored separately.
struct GalleryTemplate: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "galleryTemplates"

    var id: String
    var categoryID: String
    var title: String
    var templateDescription: String
    var revision: Int
    var sortOrder: Double
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, categoryID: String, title: String,
         templateDescription: String = "", revision: Int = 1, sortOrder: Double = 0,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.categoryID = categoryID
        self.title = title
        self.templateDescription = templateDescription
        self.revision = revision
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
