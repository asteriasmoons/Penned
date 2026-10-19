import Foundation

nonisolated enum TemplateComponentKind: String, Codable, CaseIterable, Identifiable {
    case rating, singleSelect, multiSelect, slider
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rating: "Rating"
        case .singleSelect: "Single Select"
        case .multiSelect: "Multi-Select"
        case .slider: "Slider"
        }
    }
}

nonisolated struct TemplateComponentChoice: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var label: String
}

nonisolated struct TemplateComponentDefinition: Codable, Equatable {
    var kind: TemplateComponentKind
    var label = ""
    var minimum: Double = 1
    var maximum: Double = 5
    var step: Double = 1
    var minimumLabel = ""
    var maximumLabel = ""
    var choices: [TemplateComponentChoice] = []

    init(kind: TemplateComponentKind) {
        self.kind = kind
        if kind == .slider { minimum = 0; maximum = 100 }
        if kind == .singleSelect || kind == .multiSelect {
            choices = ["Great", "Good", "Okay", "Difficult"].map { TemplateComponentChoice(label: $0) }
        }
    }

    func validated() throws -> Self {
        var value = self
        value.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard minimum.isFinite, maximum.isFinite, step.isFinite,
              abs(minimum) <= 1_000_000_000, abs(maximum) <= 1_000_000_000 else {
            throw VellixError.impossibleMove("Enter finite component values.")
        }
        switch kind {
        case .rating:
            guard minimum.rounded() == minimum, maximum.rounded() == maximum, minimum < maximum, maximum - minimum <= 49 else {
                throw VellixError.impossibleMove("Choose whole-number rating limits with 2 to 50 choices.")
            }
            value.step = 1
        case .slider:
            guard maximum > minimum, step > 0, step <= maximum - minimum,
                  ((maximum - minimum) / step).isFinite, minimum + step != minimum, maximum - step != maximum else {
                throw VellixError.impossibleMove("The maximum must exceed the minimum, with a positive step within that range.")
            }
        case .singleSelect, .multiSelect:
            value.choices = choices.map { TemplateComponentChoice(id: $0.id, label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard !choices.isEmpty, choices.count <= 100, Set(choices.map(\.id)).count == choices.count,
                  value.choices.allSatisfy({ !$0.label.isEmpty && !$0.id.isEmpty }) else {
                throw VellixError.impossibleMove("Add between 1 and 100 named choices.")
            }
        }
        return value
    }

    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:] }
    static func decode(_ value: Any?) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let definition = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return try? definition.validated()
    }

    nonisolated static func contains(in json: String) -> Bool {
        func visit(_ node: [String: Any]) -> Bool {
            node["type"] as? String == "templateComponent"
                || (node["content"] as? [[String: Any]] ?? []).contains(where: visit)
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
        return visit(object)
    }
}

nonisolated struct TemplateComponentRequest: Identifiable, Equatable {
    var id: String { blockID ?? "new-" + definition.kind.rawValue }
    var blockID: String?
    var definition: TemplateComponentDefinition
}
