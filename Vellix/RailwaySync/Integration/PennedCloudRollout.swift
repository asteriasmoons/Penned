import Foundation

// Release-controlled, not a user preference. Keep off until the cross-device
// migration, attachment, and old-client retirement gates have been satisfied.
nonisolated enum PennedCloudRollout {
    static let automaticMigrationEnabled=false
    static func shouldMigrate(enabled:Bool,accountReady:Bool,legacy:Bool,fenced:Bool,hasEditor:Bool)->Bool {
        enabled && accountReady && (legacy || fenced) && !hasEditor
    }
}
