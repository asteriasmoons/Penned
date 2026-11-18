import Foundation
import SwiftUI
import WebKit

nonisolated struct CodeBlockConfiguration: Equatable, Sendable {
    var code: String
    var language: String
    var theme: String

    var payload: [String: Any] { ["code": code, "language": language, "theme": theme] }
}

nonisolated struct CodeBlockEditorRequest: Equatable, Identifiable, Sendable {
    let blockID: String
    let original: CodeBlockConfiguration
    var id: String { blockID }

    init?(payload: [String: Any]) {
        guard let blockID = payload["blockID"] as? String, !blockID.isEmpty,
              let code = payload["code"] as? String else { return nil }
        self.blockID = blockID
        original = CodeBlockConfiguration(code: code, language: payload["language"] as? String ?? "plaintext",
                                          theme: payload["theme"] as? String ?? "auto")
    }
}

nonisolated struct CodeBlockCatalog: Decodable, Sendable {
    struct Language: Decodable, Identifiable, Sendable { let id: String; let name: String }
    struct Theme: Decodable, Identifiable, Sendable { let id: String; let name: String; let colors: [String] }

    let languages: [Language]
    let colorRoles: [String]
    let themes: [Theme]

    static let shared: Self = {
        if let url = asset("code-block-catalog", extension: "json"), let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode(Self.self, from: data) { return catalog }
        return Self(languages: [Language(id: "plaintext", name: "Plain Text")], colorRoles: [],
                    themes: [Theme(id: "auto", name: "Auto", colors: [])])
    }()

    static func asset(_ name: String, extension ext: String) -> URL? {
        Bundle.main.url(forResource: "VellixEditor", withExtension: "bundle")?
            .appendingPathComponent(name).appendingPathExtension(ext)
    }

    func palette(_ theme: String, scheme: ColorScheme) -> CodeBlockPalette {
        let id = theme == "auto" ? (scheme == .light ? "github-light" : "aura") : theme
        let colors = themes.first(where: { $0.id == id })?.colors ?? []
        return CodeBlockPalette(colors: Dictionary(uniqueKeysWithValues: zip(colorRoles, colors)))
    }
}

nonisolated struct CodeBlockPalette: Equatable, Sendable {
    let colors: [String: String]

    func hex(_ role: String) -> String {
        colors[role] ?? (role == "background" || role == "gutter" ? "#15141b" : "#edecee")
    }
}

@MainActor
enum CodeBlockBridge {
    static func commit(_ request: CodeBlockEditorRequest, draft: CodeBlockConfiguration, in webView: WKWebView) async throws -> Any? {
        var args = draft.payload
        args["blockID"] = request.blockID
        args["original"] = request.original.payload
        return try await webView.callAsyncJavaScript("return await window.tiptapCommand('codeBlockUpdate', args);",
            arguments: ["args": args], in: nil, contentWorld: .page)
    }

    static func preview(_ request: CodeBlockEditorRequest, draft: CodeBlockConfiguration?) -> TipTapEditorCommand {
        if let draft {
            return TipTapEditorCommand("codeBlockPreview", args: ["blockID": request.blockID, "theme": draft.theme, "language": draft.language])
        }
        return TipTapEditorCommand("codeBlockEndPreview", args: ["blockID": request.blockID])
    }
}
