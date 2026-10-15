import Foundation

nonisolated enum InlinePropertyKind: String, Codable, CaseIterable, Identifiable {
    case text, number, date, select, multiSelect, checkbox, url

    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: return "Text"
        case .number: return "Number"
        case .date: return "Date"
        case .select: return "Select"
        case .multiSelect: return "Multi Select"
        case .checkbox: return "Checkbox"
        case .url: return "URL"
        }
    }

    var isSelect: Bool { self == .select || self == .multiSelect }
}

nonisolated struct InlinePropertyOption: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name = "Option"
    var color = "#2EC5F4"
}

nonisolated struct InlinePropertyDefinition: Codable, Equatable {
    var kind = InlinePropertyKind.text
    var name = ""
    var value = ""
    var checked = false
    var selectedOptionIDs: [String] = []
    var options: [InlinePropertyOption] = []
    var placeholder = ""
    var prefix = ""
    var suffix = ""
    var minimum = ""
    var maximum = ""
    var step = ""
    var includeTime = false
    var urlLabel = ""

    enum CodingKeys: String, CodingKey {
        case kind, name, value, checked, selectedOptionIDs, options, placeholder
        case prefix, suffix, minimum, maximum, step, includeTime, urlLabel
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(InlinePropertyKind.self, forKey: .kind) ?? .text
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try values.decodeIfPresent(String.self, forKey: .value) ?? ""
        checked = try values.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        selectedOptionIDs = try values.decodeIfPresent([String].self, forKey: .selectedOptionIDs) ?? []
        options = try values.decodeIfPresent([InlinePropertyOption].self, forKey: .options) ?? []
        placeholder = try values.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        prefix = try values.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try values.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        minimum = try values.decodeIfPresent(String.self, forKey: .minimum) ?? ""
        maximum = try values.decodeIfPresent(String.self, forKey: .maximum) ?? ""
        step = try values.decodeIfPresent(String.self, forKey: .step) ?? ""
        includeTime = try values.decodeIfPresent(Bool.self, forKey: .includeTime) ?? false
        urlLabel = try values.decodeIfPresent(String.self, forKey: .urlLabel) ?? ""
    }

    static func decode(_ object: Any?) -> Self? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func bridgeObject() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] ?? [:]
    }

    static func safeURL(_ value: String) -> URL? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        let hasScheme = clean.range(of: "^[a-z][a-z0-9+.-]*:", options: [.regularExpression, .caseInsensitive]) != nil
        guard let url = URL(string: hasScheme ? clean : "https://\(clean)"),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    var searchableText: String {
        var display = value
        if kind.isSelect {
            display = options.filter { selectedOptionIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
        } else if kind == .checkbox {
            display = checked ? "Checked" : "Unchecked"
        } else if kind == .number, !value.isEmpty {
            display = "\(prefix)\(value)\(suffix)"
        } else if kind == .url, !urlLabel.isEmpty {
            display = "\(urlLabel) \(value)"
        }
        return "\(name.isEmpty ? "" : "\(name): ")\(display)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a property name." }
        if kind.isSelect, options.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Enter a name for every option."
        }
        if kind == .url, !value.isEmpty, Self.safeURL(value) == nil { return "Enter an HTTP or HTTPS URL." }
        guard kind == .number else { return nil }
        for field in [value, minimum, maximum, step] where !field.isEmpty {
            guard let number = Double(field), number.isFinite else { return "Enter valid numbers." }
        }
        if let min = Double(minimum), let max = Double(maximum), min > max { return "Minimum must not exceed maximum." }
        if let step = Double(step), step <= 0 { return "Step must be greater than zero." }
        if let number = Double(value) {
            if let min = Double(minimum), number < min { return "Value is below the minimum." }
            if let max = Double(maximum), number > max { return "Value is above the maximum." }
            if let step = Double(step) {
                let steps = (number - (Double(minimum) ?? 0)) / step
                if abs(steps - steps.rounded()) > 1e-8 { return "Value must match the step." }
            }
        }
        return nil
    }

    var civilDate: Date? {
        civilDate(in: .current)
    }

    private func civilDate(in timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = value.count == 10 ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
        formatter.isLenient = false
        return formatter.date(from: value)
    }

    var selectedOptions: [InlinePropertyOption] {
        let validIDs = Set(options.map(\.id))
        let selected = selectedOptionIDs.filter { validIDs.contains($0) }
        let ids = Set(kind == .select ? Array(selected.prefix(1)) : selected)
        return options.filter { ids.contains($0.id) }
    }

    var emptyCaption: String { placeholder.isEmpty ? "Tap title to configure" : placeholder }

    var hasDisplayValue: Bool {
        switch kind {
        case .select, .multiSelect: return !selectedOptions.isEmpty
        case .date: return civilDate != nil
        case .checkbox: return true
        default: return !value.isEmpty
        }
    }

    func displayValue(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch kind {
        case .select, .multiSelect:
            let names = selectedOptions.map(\.name)
            return names.isEmpty ? emptyCaption : names.joined(separator: ", ")
        case .number: return value.isEmpty ? emptyCaption : "\(prefix)\(value)\(suffix)"
        case .checkbox: return checked ? "Checked" : "Unchecked"
        case .url: return value.isEmpty ? emptyCaption : (urlLabel.isEmpty ? value : urlLabel)
        case .date:
            guard let date = civilDate(in: timeZone) else { return emptyCaption }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = includeTime ? .short : .none
            return formatter.string(from: date)
        case .text: return value.isEmpty ? emptyCaption : value
        }
    }

    mutating func setDate(_ date: Date) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = includeTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        value = formatter.string(from: date)
    }
}

struct InlinePropertyEditorRequest: Equatable, Identifiable {
    let id = UUID()
    var blockID: String
    var property: InlinePropertyDefinition
}

struct InlinePropertyURLRequest: Equatable, Identifiable {
    let id = UUID()
    var url: String
}
