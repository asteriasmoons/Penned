import Foundation
import GRDB

nonisolated struct RailwayLocalDiagnostics:Codable,Sendable {
    let pendingMutations:Int;let failedOperations:Int;let pendingTransfers:Int;let deferredRecords:Int;let recoveryRecords:Int;let paused:Bool;let cursor:String
}
extension RailwayJournal {
    // The Settings integration reads these values from the same journal. No
    // conflict management interface or migration progress view is generated.
    func diagnostics()throws->RailwayLocalDiagnostics{
        try localDiagnostics()
    }
}
