import Foundation
import GRDB

nonisolated enum CollectionIntegrityError: LocalizedError {
    case confirmationRequired
    var errorDescription: String? { "This change clears incompatible values or values assigned to removed options. Confirm to continue." }
}

nonisolated enum CollectionViewKind: String, Codable, CaseIterable, Identifiable {
    case table, gallery, kanban
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .table: return "blackcal"
        case .gallery: return "linedpages"
        case .kanban: return "sf:\(systemIcon)"
        }
    }
    var systemIcon: String {
        switch self {
        case .table: return "tablecells"
        case .gallery: return "square.grid.2x2"
        case .kanban: return "rectangle.split.3x1"
        }
    }
}

nonisolated enum CollectionFieldKind: String, Codable, CaseIterable, Identifiable {
    case text, number, select, multiSelect, date, checkbox, url, email
    var id: String { rawValue }
    var title: String { self == .multiSelect ? "Multi Select" : self == .url ? "URL" : rawValue.capitalized }
    var inlineKind: InlinePropertyKind { InlinePropertyKind(rawValue: rawValue) ?? .text }
    var icon: String {
        switch self {
        case .text, .email: return "linedpages"
        case .number, .date: return "numcal"
        case .select, .multiSelect: return "listcircle"
        case .checkbox: return "checkwavy"
        case .url: return "linkcircle"
        }
    }
    var operators: [CollectionFilterOperator] {
        let empty: [CollectionFilterOperator] = [.isEmpty, .isNotEmpty]
        switch self {
        case .number, .date: return [.equals, .notEquals, .greater, .less, .greaterEqual, .lessEqual] + empty
        case .checkbox: return [.equals, .notEquals] + empty
        case .select, .multiSelect: return [.equals, .notEquals, .contains, .notContains] + empty
        default: return [.contains, .notContains, .equals, .notEquals] + empty
        }
    }
}

nonisolated struct CollectionValue: Codable, Equatable {
    var text = ""
    var checked: Bool?
    var optionIDs: [String] = []
    var isEmpty: Bool { text.isEmpty && checked == nil && optionIDs.isEmpty }
    func applying(to definition: InlinePropertyDefinition) -> InlinePropertyDefinition {
        var result = definition
        result.value = text
        result.checked = checked ?? false
        result.selectedOptionIDs = optionIDs
        return result
    }
}

struct CollectionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "collections"
    var id = UUID().uuidString
    var documentID: String
    var name: String
    var activeViewID: String
    var createdAt = Date()
}

struct CollectionField: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "collectionFields"
    var id = UUID().uuidString
    var collectionID: String
    var name: String
    var kind: CollectionFieldKind
    var configurationJSON = "{}"
    var position = 0
    var icon = ""
    var resolvedIcon: String { icon.isEmpty ? kind.icon : icon }
    var configuration: InlinePropertyDefinition {
        get {
            var value = (try? JSONDecoder().decode(InlinePropertyDefinition.self, from: Data(configurationJSON.utf8))) ?? InlinePropertyDefinition()
            value.name = name
            value.kind = kind.inlineKind
            return value
        }
        set { configurationJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}" }
    }
    func display(_ value: CollectionValue, definition: InlinePropertyDefinition? = nil) -> String {
        if value.isEmpty { return "Not set" }
        let configuration = definition ?? self.configuration
        if kind == .checkbox { return value.checked == true ? "Checked" : "Unchecked" }
        if kind == .select || kind == .multiSelect {
            return configuration.options.filter { value.optionIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
        }
        if kind == .number { return configuration.prefix + value.text + configuration.suffix }
        if kind == .date, let date = value.applying(to: configuration).civilDate {
            return date.formatted(date: .abbreviated, time: configuration.includeTime ? .shortened : .omitted)
        }
        return value.text
    }
    func filterValidation(_ filter: CollectionFilter) -> String? {
        guard filter.operation.needsValue else { return nil }
        if filter.value.isEmpty { return "Choose a filter value." }
        if kind == .number {
            guard let number = Double(filter.value.text), number.isFinite else { return "Enter a valid number." }
        }
        if kind == .date && filter.value.applying(to: configuration).civilDate == nil { return "Choose a valid date." }
        return nil
    }
}

nonisolated enum CollectionFilterOperator: String, Codable, CaseIterable, Identifiable {
    case equals, notEquals, contains, notContains, greater, less, greaterEqual, lessEqual, isEmpty, isNotEmpty
    var id: String { rawValue }
    var title: String {
        switch self {
        case .equals: return "Is"
        case .notEquals: return "Is Not"
        case .contains: return "Contains"
        case .notContains: return "Does Not Contain"
        case .greater: return "Greater Than / After"
        case .less: return "Less Than / Before"
        case .greaterEqual: return "At Least / On or After"
        case .lessEqual: return "At Most / On or Before"
        case .isEmpty: return "Is Empty"
        case .isNotEmpty: return "Is Not Empty"
        }
    }
    var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }
}

nonisolated struct CollectionFilter: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var fieldID = CollectionViewConfiguration.titleFieldID
    var operation = CollectionFilterOperator.contains
    var value = CollectionValue()
}

nonisolated struct CollectionSort: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var fieldID = CollectionViewConfiguration.titleFieldID
    var ascending = true
}

nonisolated struct CollectionKanbanColumn: Codable, Equatable, Identifiable {
    static let inboxID = "$inbox"
    var id = UUID().uuidString
    var name: String
    var color = "#34363F"
    var collapsed = false
    static var inbox: Self { Self(id: inboxID, name: "Unassigned") }
}

nonisolated struct CollectionViewConfiguration: Codable, Equatable {
    static let titleFieldID = "$title"
    static let kanbanMaxHeight = 560.0
    var filters: [CollectionFilter] = []
    var matchAll = true
    var sorts: [CollectionSort] = []
    var visibleFieldIDs: [String] = []
    var galleryColumns = 2
    var showsCover = true
    var compactCards = false
    var kanbanColumns: [CollectionKanbanColumn] = [.inbox]
    var kanbanAssignments: [String: String] = [:]
    var kanbanEntryOrder: [String: [String]] = [:]

    init() {}
    private enum CodingKeys: String, CodingKey {
        case filters, matchAll, sorts, visibleFieldIDs, galleryColumns, showsCover, compactCards
        case kanbanColumns, kanbanAssignments, kanbanEntryOrder
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filters = try container.decodeIfPresent([CollectionFilter].self, forKey: .filters) ?? []
        matchAll = try container.decodeIfPresent(Bool.self, forKey: .matchAll) ?? true
        sorts = try container.decodeIfPresent([CollectionSort].self, forKey: .sorts) ?? []
        visibleFieldIDs = try container.decodeIfPresent([String].self, forKey: .visibleFieldIDs) ?? []
        galleryColumns = try container.decodeIfPresent(Int.self, forKey: .galleryColumns) ?? 2
        showsCover = try container.decodeIfPresent(Bool.self, forKey: .showsCover) ?? true
        compactCards = try container.decodeIfPresent(Bool.self, forKey: .compactCards) ?? false
        kanbanColumns = try container.decodeIfPresent([CollectionKanbanColumn].self, forKey: .kanbanColumns) ?? [.inbox]
        kanbanAssignments = try container.decodeIfPresent([String: String].self, forKey: .kanbanAssignments) ?? [:]
        kanbanEntryOrder = try container.decodeIfPresent([String: [String]].self, forKey: .kanbanEntryOrder) ?? [:]
    }

    func kanbanColumnID(for entryID: String) -> String? {
        let assigned = kanbanAssignments[entryID]
        return kanbanColumns.first { $0.id == assigned }?.id ?? kanbanColumns.first?.id
    }
}

struct CollectionViewRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "collectionViews"
    var id = UUID().uuidString
    var collectionID: String
    var name: String
    var kind: CollectionViewKind
    var configurationJSON = "{}"
    var position = 0
    var configuration: CollectionViewConfiguration {
        get { (try? JSONDecoder().decode(CollectionViewConfiguration.self, from: Data(configurationJSON.utf8))) ?? CollectionViewConfiguration() }
        set { configurationJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}" }
    }
}

struct CollectionEntrySummary: Identifiable, Equatable, Codable {
    var id: String
    var title: String
    var cover: String?
    var appearance: DocumentAppearance
    var position: Int
    var values: [String: CollectionValue] = [:]
}

struct CollectionSnapshot: Equatable, Codable {
    var record: CollectionRecord
    var name: String
    var fields: [CollectionField]
    var views: [CollectionViewRecord]
    var entries: [CollectionEntrySummary]
    var activeView: CollectionViewRecord? { views.first { $0.id == record.activeViewID } ?? views.first }
    func field(_ id: String) -> CollectionField? { fields.first { $0.id == id } }
    func visibleFields(in view: CollectionViewRecord) -> [CollectionField] {
        view.configuration.visibleFieldIDs.compactMap(field)
    }

    func kanbanGroups(in view: CollectionViewRecord) -> [(column: CollectionKanbanColumn, entries: [CollectionEntrySummary])] {
        let config = view.configuration
        let grouped = Dictionary(grouping: presentedEntries(in: view)) { config.kanbanColumnID(for: $0.id) ?? "" }
        return config.kanbanColumns.map { column in
            var entries = grouped[column.id] ?? []
            if config.sorts.isEmpty {
                let order = config.kanbanEntryOrder[column.id] ?? []
                let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
                entries.sort {
                    let left = ranks[$0.id] ?? Int.max, right = ranks[$1.id] ?? Int.max
                    return left == right ? ($0.position == $1.position ? $0.id < $1.id : $0.position < $1.position) : left < right
                }
            }
            return (column, entries)
        }
    }

    func presentedEntries(in view: CollectionViewRecord) -> [CollectionEntrySummary] {
        let config = view.configuration
        let fieldMap = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
        let referenced = Set(config.sorts.map(\.fieldID) + config.filters.map(\.fieldID))
        let definitions = Dictionary(uniqueKeysWithValues: fields.filter { referenced.contains($0.id) }.map { ($0.id, $0.configuration) })
        let dateOnly = DateFormatter(), dateTime = DateFormatter()
        for formatter in [dateOnly, dateTime] { formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian) }
        dateOnly.dateFormat = "yyyy-MM-dd"; dateTime.dateFormat = "yyyy-MM-dd'T'HH:mm"
        func score(_ value: CollectionValue, field: CollectionField) -> Double? {
            guard !value.isEmpty else { return nil }
            switch field.kind {
            case .number: return Double(value.text)
            case .checkbox: return value.checked.map { $0 ? 1 : 0 }
            case .select, .multiSelect: return definitions[field.id]?.options.firstIndex { value.optionIDs.contains($0.id) }.map(Double.init)
            case .date:
                guard let date = (value.text.count == 10 ? dateOnly : dateTime).date(from: value.text) else { return nil }
                return (definitions[field.id]?.includeTime == true ? date : Calendar.current.startOfDay(for: date)).timeIntervalSince1970
            default: return nil
            }
        }
        // Parse dates and numeric keys once per entry, not on every sort comparison.
        var scores: [String: [String: Double]] = [:], targets: [String: Double] = [:]
        for field in fields where referenced.contains(field.id) {
            if [.number, .date, .select, .multiSelect, .checkbox].contains(field.kind) {
                for entry in entries {
                    if let key = score(entry.values[field.id] ?? CollectionValue(), field: field) { scores[field.id, default: [:]][entry.id] = key }
                }
                for filter in config.filters where filter.fieldID == field.id { targets[filter.id] = score(filter.value, field: field) }
            }
        }
        let filtered = entries.filter { entry in
            guard !config.filters.isEmpty else { return true }
            let results = config.filters.map { matches(entry, filter: $0, fields: fieldMap, scores: scores, targets: targets) }
            return config.matchAll ? results.allSatisfy { $0 } : results.contains(true)
        }
        return filtered.sorted { left, right in
            for sort in config.sorts {
                if sort.fieldID != CollectionViewConfiguration.titleFieldID {
                    let leftEmpty = left.values[sort.fieldID]?.isEmpty ?? true, rightEmpty = right.values[sort.fieldID]?.isEmpty ?? true
                    if leftEmpty != rightEmpty { return !leftEmpty }
                }
                let result = compare(left, right, fieldID: sort.fieldID, fields: fieldMap, scores: scores)
                if result != .orderedSame { return sort.ascending ? result == .orderedAscending : result == .orderedDescending }
            }
            return left.position == right.position ? left.id < right.id : left.position < right.position
        }
    }

    private func matches(_ entry: CollectionEntrySummary, filter: CollectionFilter, fields: [String: CollectionField],
                         scores: [String: [String: Double]], targets: [String: Double]) -> Bool {
        let field = fields[filter.fieldID]
        guard field != nil || filter.fieldID == CollectionViewConfiguration.titleFieldID else { return false }
        let value = field == nil ? CollectionValue(text: entry.title) : entry.values[filter.fieldID] ?? CollectionValue()
        if filter.operation == .isEmpty { return value.isEmpty }
        if filter.operation == .isNotEmpty { return !value.isEmpty }
        let target = filter.value
        let comparison: ComparisonResult?
        let contains: Bool
        switch field?.kind {
        case .select, .multiSelect:
            contains = !target.optionIDs.isEmpty && target.optionIDs.allSatisfy(value.optionIDs.contains)
            comparison = Set(value.optionIDs) == Set(target.optionIDs) ? .orderedSame : nil
        case .checkbox:
            contains = value.checked == target.checked
            comparison = contains ? .orderedSame : nil
        case .number, .date:
            if let left = scores[filter.fieldID]?[entry.id], let right = targets[filter.id] {
                comparison = left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
            } else { comparison = nil }
            contains = false
        default:
            contains = value.text.localizedCaseInsensitiveContains(target.text)
            comparison = value.text.compare(target.text, options: [.caseInsensitive, .diacriticInsensitive])
        }
        switch filter.operation {
        case .equals: return field?.kind == .multiSelect || field?.kind == .select ? contains : comparison == .orderedSame
        case .notEquals: return field?.kind == .multiSelect || field?.kind == .select ? !contains : comparison != .orderedSame
        case .contains: return contains
        case .notContains: return !contains
        case .greater: return comparison == .orderedDescending
        case .less: return comparison == .orderedAscending
        case .greaterEqual: return comparison == .orderedSame || comparison == .orderedDescending
        case .lessEqual: return comparison == .orderedSame || comparison == .orderedAscending
        case .isEmpty, .isNotEmpty: return false
        }
    }

    private func compare(_ left: CollectionEntrySummary, _ right: CollectionEntrySummary, fieldID: String,
                         fields: [String: CollectionField], scores: [String: [String: Double]]) -> ComparisonResult {
        guard let field = fields[fieldID] else { return left.title.localizedStandardCompare(right.title) }
        let a = left.values[fieldID] ?? CollectionValue(), b = right.values[fieldID] ?? CollectionValue()
        if a.isEmpty != b.isEmpty { return a.isEmpty ? .orderedDescending : .orderedAscending }
        if [.text, .url, .email].contains(field.kind) { return a.text.localizedStandardCompare(b.text) }
        guard let x = scores[fieldID]?[left.id], let y = scores[fieldID]?[right.id] else { return .orderedSame }
        return x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending
    }
}

extension Notification.Name {
    static let pennedCollectionsChanged = Notification.Name("penned.collectionsChanged")
}

struct CollectionEditorRequest: Identifiable, Equatable {
    var id = UUID().uuidString
    var action: String
    var blockID = ""
    var collectionID = ""
    var documentID = ""
    var fieldID = ""
    var viewID = ""
}
