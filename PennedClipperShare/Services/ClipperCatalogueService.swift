import Foundation

/// Reads the destination catalogue published by the Penned app to the shared App Group.
struct ClipperCatalogueService {
    func loadConnection() throws -> ClipperConnection {
        guard let connection = try ClipperShared.connection() else {
            throw ShareClipError.pennedNotConnected
        }
        return connection
    }

    func spaces(in connection: ClipperConnection) -> [ClipperDestination] {
        connection.spaces
    }

    func folders(in connection: ClipperConnection, spaceID: String, parentID: String? = nil) -> [ClipperDestination] {
        connection.folders.filter { $0.spaceID == spaceID && $0.parentID == parentID }
    }

    func tags(in connection: ClipperConnection, spaceID: String) -> [ClipperDestination] {
        connection.tags.filter { $0.spaceID == spaceID }
    }

    func defaultSpaceID(in connection: ClipperConnection) -> String? {
        if let selected = connection.selectedSpaceID,
           connection.spaces.contains(where: { $0.id == selected }) {
            return selected
        }
        return connection.spaces.first?.id
    }

    func folderBreadcrumbs(for folderID: String, in connection: ClipperConnection) -> [ClipperDestination] {
        var breadcrumbs: [ClipperDestination] = []
        var currentID: String? = folderID
        var visited = Set<String>()

        while let id = currentID, !visited.contains(id),
              let folder = connection.folders.first(where: { $0.id == id }) {
            visited.insert(id)
            breadcrumbs.insert(folder, at: 0)
            currentID = folder.parentID
        }
        return breadcrumbs
    }
}
