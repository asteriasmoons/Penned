import Foundation
nonisolated enum RailwayMigrationCommitPolicy {
    static func mustRetainFence(phase:String)->Bool {
        switch phase {
        case "confirmed","captured","staging","cutover":false
        default:true
        }
    }
}
