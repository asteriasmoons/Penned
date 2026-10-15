import Foundation

nonisolated enum DocumentEditorWarmupPolicy {
    static func documentIDs(recent: [DocumentRecord], selectedID: String?) -> [String] {
        if let selectedID { return [selectedID] }
        return Array(recent.lazy.filter {
            !$0.isTrashed && !$0.isArchived && $0.templateID == nil && $0.parentDocumentID == nil
        }.prefix(1).map(\.id))
    }
}
