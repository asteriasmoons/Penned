import Foundation

// A verified-but-not-committed cutover or an invalid receipt is never permission
// to restart CloudKit or to start Railway. Local-only libraries remain local.
nonisolated enum RailwayWorkspaceRoute: Equatable, Sendable {
    case local, legacy, blocked, railway
    static func select(local: Bool, phase: String?, verified: Bool) -> Self {
        if local { return .local }
        switch phase {
        case nil, "confirmed", "captured", "staging": return .legacy
        case "cutover": return verified ? .railway : .blocked
        default: return .blocked
        }
    }
}
