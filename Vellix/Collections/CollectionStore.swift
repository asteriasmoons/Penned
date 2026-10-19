import Combine
import Foundation

@MainActor
final class CollectionStore: ObservableObject {
    let repository: CollectionRepository
    @Published private(set) var snapshots: [String: CollectionSnapshot] = [:]
    @Published private(set) var revision = 0
    @Published var errorMessage: String?
    var onMetadataChanged: ((Set<String>) -> Void)?
    private var documents = Set<String>()
    private var observation: AnyCancellable?

    init(repository: CollectionRepository, database: AppDatabase) {
        self.repository = repository
        observation = NotificationCenter.default.publisher(for: .pennedCollectionsChanged, object: database)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func watchDocument(_ id: String) {
        documents = [id]
        refresh(markTemplateChanges: false)
    }

    func resetForSpaceChange() {
        documents.removeAll()
        snapshots.removeAll()
        errorMessage = nil
        revision += 1
    }

    func unwatchDocument(_ id: String) {
        guard documents.remove(id) != nil else { return }
        refresh(markTemplateChanges: false)
    }

    func refresh(markTemplateChanges: Bool = true) {
        do {
            var ids = Set<String>()
            for document in documents {
                ids.formUnion(try repository.collectionIDs(forDocument: document))
                if let id = try repository.collectionID(forEntry: document) { ids.insert(id) }
            }
            var next: [String: CollectionSnapshot] = [:]
            for id in ids { next[id] = try repository.snapshot(id: id) }
            if snapshots != next {
                let changed = Set(next.keys.filter { snapshots[$0] != next[$0] })
                snapshots = next; revision += 1
                if markTemplateChanges { onMetadataChanged?(changed) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func load(_ id: String) throws -> CollectionSnapshot {
        let snapshot = try repository.snapshot(id: id)
        if snapshots[id] != snapshot { snapshots[id] = snapshot; revision += 1 }
        return snapshot
    }

    func entryContext(_ documentID: String) -> (CollectionSnapshot, CollectionEntrySummary)? {
        for snapshot in snapshots.values {
            if let entry = snapshot.entries.first(where: { $0.id == documentID }) { return (snapshot, entry) }
        }
        return nil
    }

    func embeddedEntryIDs(_ documentID: String) -> Set<String> {
        Set(snapshots.values.filter { $0.record.documentID == documentID }.flatMap { $0.entries.map(\.id) })
    }

    func payloads(for documentID: String) -> [[String: Any]] {
        let ids: Set<String>
        do {
            ids = Set(try repository.collectionIDs(forDocument: documentID))
            for id in ids where snapshots[id] == nil { _ = try load(id) }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription; return [] }
        return Self.payloads(from: snapshots.values.filter { ids.contains($0.record.id) })
    }

    static func payloads(from snapshots: [CollectionSnapshot]) -> [[String: Any]] {
        snapshots.sorted { $0.record.id < $1.record.id }.compactMap { snapshot in
            guard let view = snapshot.activeView else { return nil }
            if view.kind == .kanban {
                return ["id": snapshot.record.id, "documentID": snapshot.record.documentID, "name": snapshot.name,
                    "totalCount": snapshot.entries.count, "viewID": view.id, "viewName": view.name,
                    "kind": view.kind.rawValue, "nativeHeight": CollectionViewConfiguration.kanbanMaxHeight]
            }
            let fields = snapshot.visibleFields(in: view)
            let definitions = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.configuration) })
            let config = view.configuration
            return [
                "id": snapshot.record.id, "documentID": snapshot.record.documentID, "name": snapshot.name,
                "totalCount": snapshot.entries.count, "viewID": view.id, "viewName": view.name, "kind": view.kind.rawValue,
                "galleryColumns": config.galleryColumns, "showsCover": config.showsCover, "compactCards": config.compactCards,
                "views": snapshot.views.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] },
                "fields": fields.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue, "icon": $0.resolvedIcon] },
                "entries": snapshot.presentedEntries(in: view).map { entry -> [String: Any] in
                    var result: [String: Any] = ["id": entry.id, "title": entry.title]
                    if entry.appearance.displaysCover {
                        var components = URLComponents()
                        components.scheme = "penned-cover"; components.host = "image"
                        if let path = entry.cover { components.queryItems = [URLQueryItem(name: "path", value: path)] }
                        else { components.queryItems = [URLQueryItem(name: "theme", value: entry.appearance.resolvedCoverTheme.rawValue)] }
                        result["cover"] = components.url?.absoluteString ?? ""
                    }
                    result["values"] = Dictionary(uniqueKeysWithValues: fields.map { field -> (String, [String: Any]) in
                        let value = entry.values[field.id] ?? CollectionValue()
                        let definition = definitions[field.id]!
                        let chips = definition.options.filter { value.optionIDs.contains($0.id) }
                        return (field.id, ["text": field.display(value, definition: definition), "empty": value.isEmpty,
                            "checked": value.checked as Any? ?? NSNull(), "chips": chips.map { ["name": $0.name, "color": $0.color] }])
                    })
                    return result
                }
            ]
        }
    }

    func perform(_ operation: () throws -> Void) {
        do { try operation(); refresh() }
        catch { errorMessage = error.localizedDescription }
    }
}
