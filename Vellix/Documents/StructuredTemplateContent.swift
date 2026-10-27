import Foundation

// Guidance is metadata. The author's editable projection must never reach persistence or export.
nonisolated enum StructuredTemplateContent {
    static func canonical(_ json: String) throws -> String {
        try transform(json) { node in
            var result = node
            if var attrs = node["attrs"] as? [String: Any], attrs["placeholderProjection"] as? Bool == true {
                attrs["placeholderGuidance"] = node["content"] as? [[String: Any]] ?? []
                attrs["placeholderEnabled"] = true
                attrs.removeValue(forKey: "placeholderProjection")
                result["attrs"] = attrs
                result["content"] = []
            }
            return result
        }
    }

    static func independent(_ json: String, pages: [String: String], paths: [String: String] = [:], resetsComponentResponses: Bool = false,
                            tasks: [String: String] = [:]) throws -> String {
        try transform(canonical(json)) { node in
            var result = node
            if node["type"] as? String == "doc", var attrs = node["attrs"] as? [String: Any] {
                if var projection = attrs["taskHistoryProjection"] as? [String: Any],
                   let old = projection["taskID"] as? String, let id = tasks[old] {
                    result["content"] = DocumentTaskPages.removingOccurrences(node["content"] as? [[String: Any]] ?? [],
                        ids: Set(projection["occurrences"] as? [String] ?? []))
                    projection["taskID"] = id; projection["occurrences"] = [String]()
                    attrs["taskHistoryProjection"] = projection
                } else {
                    attrs.removeValue(forKey: "taskHistoryProjection")
                }
                result["attrs"] = attrs
            }
            if node["type"] as? String != "text", node["type"] as? String != "doc" {
                var attrs = node["attrs"] as? [String: Any] ?? [:]
                attrs["id"] = UUID().uuidString
                attrs.removeValue(forKey: "placeholderProjection")
                if resetsComponentResponses, node["type"] as? String == "templateComponent" {
                    attrs["response"] = NSNull()
                }
                if let task = DocumentTaskMetadata.decode(attrs["trackedTask"]) {
                    var independent = task.independent()
                    independent.id = tasks[task.id] ?? independent.id
                    attrs["trackedTask"] = independent.object
                }
                if node["type"] as? String == "pageReference", let old = attrs["documentID"] as? String {
                    // Never leave a cloned template pointing at an editable source page.
                    attrs["documentID"] = pages[old] ?? ""
                }
                result["attrs"] = attrs
            }
            return replacePaths(in: result, paths: paths) as? [String: Any] ?? result
        }
    }

    static func replacingPaths(_ json: String?, paths: [String: String]) throws -> String? {
        guard let json, let data = json.data(using: .utf8) else { return json }
        let object = try JSONSerialization.jsonObject(with: data)
        let replaced = replacePaths(in: object, paths: paths)
        return String(data: try JSONSerialization.data(withJSONObject: replaced, options: [.sortedKeys]), encoding: .utf8)
    }

    static func independentTasks(_ json: String) throws -> String {
        try transform(json) { node in
            var copy = node
            if var attrs = node["attrs"] as? [String: Any], let task = DocumentTaskMetadata.decode(attrs["trackedTask"]) {
                attrs["trackedTask"] = task.independent().object
                copy["attrs"] = attrs
            }
            return copy
        }
    }

    private static func transform(_ json: String, visit: ([String: Any]) -> [String: Any]) throws -> String {
        func walk(_ node: [String: Any]) -> [String: Any] {
            var result = visit(node)
            if let children = result["content"] as? [[String: Any]] { result["content"] = children.map(walk) }
            return result
        }
        let object = walk(TipTapContentAnalyzer.documentObject(from: json))
        return String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8) ?? json
    }

    private static func replacePaths(in value: Any, paths: [String: String]) -> Any {
        if let text = value as? String { return paths[text] ?? text }
        if let array = value as? [Any] { return array.map { replacePaths(in: $0, paths: paths) } }
        if let object = value as? [String: Any] { return object.mapValues { replacePaths(in: $0, paths: paths) } }
        return value
    }
}
