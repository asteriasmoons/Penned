import Foundation
@testable import Vellix

// The library no longer materializes every top-level document in `overview.all`;
// the gallery pages them from the database instead. These tests asserted against
// that whole list, so this helper reproduces it on demand (as body-free summaries)
// to preserve their original intent without re-introducing an eager full load into
// production code.
@MainActor
extension AppEnvironment {
    var topLevelDocumentSummaries: [DocumentSummary] {
        (try? documents.topLevelSummaries(limit: 1_000_000)) ?? []
    }
}
