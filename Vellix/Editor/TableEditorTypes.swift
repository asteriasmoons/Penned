import Foundation

struct TipTapTableContext: Decodable, Equatable {
    var tableID: String
    var cellID: String
    var name: String
    var row: Int
    var column: Int
    var rowCount: Int
    var columnCount: Int
    var selectedCount: Int
    var fromRow: Int
    var toRow: Int
    var fromColumn: Int
    var toColumn: Int
    var formula: String
    var contents: String
    var result: String
    var bold: Bool
    var italic: Bool
    var strike: Bool
    var code: Bool
    var align: String
    var font: String
    var format: String
    var decimals: Int
    var currency: String
    var fillColor: String
    var textColor: String
    var stripeColor: String
    var headerRow: Bool
    var headerColumn: Bool
    var canDeleteRows: Bool
    var canDeleteColumns: Bool
    var canMerge: Bool
    var canSplit: Bool
    var canSort: Bool
    var functions: [String]
    var surfaceTop: Double?

    static func decode(_ payload: [String: Any]) -> Self? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct TableEditorRequest: Identifiable {
    enum Mode { case create, edit(TipTapTableContext) }
    let id = UUID()
    let mode: Mode
}
