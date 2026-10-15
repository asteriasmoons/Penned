import Foundation

enum VellixSymbolCatalog {
    struct Symbol: Decodable {
        var name: String
        var categories: [String]
        var releases: [String: String]
        var keywords: [String]
        var icon: VellixAssetIcon { VellixAssetIcon(name: "sf:" + name) }
        var requiredVersion: String {
            #if os(iOS)
            releases["iOS"] ?? "13.0"
            #else
            releases["macOS"] ?? "10.15"
            #endif
        }
        var isAvailable: Bool {
            let components = requiredVersion.split(separator: ".").compactMap { Int($0) }
            return ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
                majorVersion: components.first ?? 0, minorVersion: components.dropFirst().first ?? 0,
                patchVersion: components.dropFirst(2).first ?? 0))
        }
    }
    private struct Category: Decodable { var id: String; var name: String; var icon: String }
    private struct Catalog: Decodable { var categories: [Category]; var symbols: [Symbol] }
    private static let catalog: Catalog = {
        guard let url = Bundle.main.url(forResource: "SFSymbolCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Catalog.self, from: data) else {
            assertionFailure("The complete SF Symbols catalog resource is missing.")
            return Catalog(categories: [], symbols: [])
        }
        return value
    }()
    static let symbols = catalog.symbols
    static let byName = Dictionary(uniqueKeysWithValues: symbols.map { ($0.name, $0) })
    static let categories: [VellixAssetIconCategory] = {
        var result = catalog.categories.map { category in
            VellixAssetIconCategory(name: category.name,
                icons: symbols.filter { category.id == "all" || $0.categories.contains(category.id) }.map(\.icon))
        }
        let uncategorized = symbols.filter { $0.categories.isEmpty }
        if !uncategorized.isEmpty { result.append(VellixAssetIconCategory(name: "Other Symbols", icons: uncategorized.map(\.icon))) }
        return result
    }()
    static func search(_ query: String) -> [VellixAssetIcon] {
        symbols.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.keywords.contains { $0.localizedCaseInsensitiveContains(query) } }.map(\.icon)
    }
}
