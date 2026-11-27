// Exact allowlist from deployed src/migration-schema.json. Native sync only.
import Foundation

nonisolated enum RailwayNativeSchema {
    static let tables: [String: RailwayTableDefinition] = [
        "attachments": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "documentID": "text", "originalFileName": "text", "storedFileName": "text", "relativePath": "text", "mimeType": "text", "uti": "text", "fileSize": "bigint", "thumbnailRelativePath": "text", "createdAt": "timestamptz"]),
        "calendarEventNotes": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "documentID": "text", "spaceID": "text", "eventKey": "text", "calendarID": "text", "sourceID": "text", "localID": "text", "externalID": "text", "occurrenceKey": "text", "createdAt": "timestamptz"]),
        "collectionEntries": RailwayTableDefinition(keys: ["documentID"], types: ["documentID": "text", "collectionID": "text", "position": "bigint"]),
        "collectionFields": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "collectionID": "text", "name": "text", "kind": "text", "configurationJSON": "jsonb", "position": "bigint", "icon": "text"]),
        "collectionValues": RailwayTableDefinition(keys: ["documentID", "fieldID"], types: ["documentID": "text", "fieldID": "text", "valueJSON": "jsonb"]),
        "collectionViews": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "collectionID": "text", "name": "text", "kind": "text", "configurationJSON": "jsonb", "position": "bigint"]),
        "collections": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "documentID": "text", "name": "text", "activeViewID": "text", "createdAt": "timestamptz"]),
        "dailyNoteSettings": RailwayTableDefinition(keys: ["spaceID"], types: ["spaceID": "text", "templateID": "text"]),
        "documentSnapshots": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "documentID": "text", "tipTapJSON": "jsonb", "createdAt": "timestamptz", "revision": "bigint", "reason": "text", "isAutomatic": "boolean"]),
        "documentStyles": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "libraryID": "text", "title": "text", "styleJSON": "jsonb", "fingerprint": "text", "createdAt": "timestamptz", "updatedAt": "timestamptz"]),
        "documents": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "title": "text", "subtitle": "text", "icon": "text", "cover": "text", "appearanceJSON": "jsonb", "tipTapJSON": "jsonb", "plainText": "text", "previewText": "text", "spaceID": "text", "folderID": "text", "parentDocumentID": "text", "isFavorite": "boolean", "isArchived": "boolean", "isTrashed": "boolean", "trashedAt": "timestamptz", "createdAt": "timestamptz", "updatedAt": "timestamptz", "lastOpenedAt": "timestamptz", "revision": "bigint", "documentSchemaVersion": "bigint", "wordCount": "bigint", "characterCount": "bigint", "estimatedReadingMinutes": "bigint", "sortOrder": "double precision", "templateOriginID": "text", "templateID": "text", "trashBatchID": "text", "cardStyleJSON": "jsonb", "dailyNoteDate": "text"]),
        "folders": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "spaceID": "text", "parentFolderID": "text", "title": "text", "icon": "text", "iconColorHex": "text", "createdAt": "timestamptz", "updatedAt": "timestamptz", "sortOrder": "double precision"]),
        "librarySpaceDefaults": RailwayTableDefinition(keys: ["libraryID"], types: ["libraryID": "text", "spaceID": "text"]),
        "spaces": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "libraryID": "text", "title": "text", "spaceDescription": "text", "icon": "text", "iconImageData": "bytea", "isArchived": "boolean", "createdAt": "timestamptz", "updatedAt": "timestamptz", "sortOrder": "double precision"]),
        "taskCompletions": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "taskID": "text", "scheduledAt": "double precision", "completedAt": "double precision"]),
        "templates": RailwayTableDefinition(keys: ["id"], types: ["id": "text", "spaceID": "text", "title": "text", "templateDescription": "text", "icon": "text", "tipTapJSON": "jsonb", "category": "text", "isBuiltIn": "boolean", "createdAt": "timestamptz", "updatedAt": "timestamptz", "rootDocumentID": "text"])
    ]
}
