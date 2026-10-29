import Foundation
import CoreGraphics

enum DocumentExportFormat: String, CaseIterable, Identifiable {
    case pdf, markdown, print, image, word, email, duplicate, link, advanced, textBundle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pdf: return "PDF"
        case .markdown: return "Markdown"
        case .print: return "Print"
        case .image: return "Image"
        case .word: return "MS Word"
        case .email: return "Email"
        case .duplicate: return "Duplicate"
        case .link: return "Link"
        case .advanced: return "Advanced"
        case .textBundle: return "TextBundle"
        }
    }
    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .markdown: return "doc.plaintext"
        case .print: return "printer"
        case .image: return "photo.on.rectangle"
        case .word: return "doc.text"
        case .email: return "envelope"
        case .duplicate: return "doc.on.doc"
        case .link: return "link"
        case .advanced: return "ellipsis"
        case .textBundle: return "shippingbox"
        }
    }
    static var menuCases: [Self] { [.pdf, .markdown, .print, .image, .word, .email, .duplicate, .link, .advanced] }
}

enum ExportPaper: String, CaseIterable, Identifiable {
    case a3 = "A3", a4 = "A4", b5 = "B5", jisB5 = "JIS B5", tabloid = "Tabloid", legal = "US Legal", letter = "US Letter"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .a3: return CGSize(width: 842, height: 1191)
        case .a4: return CGSize(width: 595, height: 842)
        case .b5: return CGSize(width: 499, height: 709)
        case .jisB5: return CGSize(width: 516, height: 729)
        case .tabloid: return CGSize(width: 792, height: 1224)
        case .legal: return CGSize(width: 612, height: 1008)
        case .letter: return CGSize(width: 612, height: 792)
        }
    }
}

enum ExportFontSize: String, CaseIterable, Identifiable {
    case small = "Small", regular = "Regular", big = "Big"
    var id: String { rawValue }
    var scale: Double { self == .small ? 0.85 : self == .big ? 1.2 : 1 }
}

enum ExportImageShape: String, CaseIterable, Identifiable {
    case portrait = "Portrait", landscape = "Landscape", square = "Square"
    var id: String { rawValue }
}

struct DocumentExportSettings: Equatable {
    var paper = ExportPaper.a4
    var fontSize = ExportFontSize.regular
    var showTitle = true
    var showPageNumbers = false
    var showWatermark = true
    var showTags = true
    var useStyle = true
    var showCover = true
    var imageShape = ExportImageShape.portrait
    var headingLevel = 1
    var strongDelimiter = "**"
    var italicDelimiter = "*"
    var rule = "---"
    var imageSize: CGSize {
        switch imageShape {
        case .portrait: return CGSize(width: 720, height: 1080)
        case .landscape: return CGSize(width: 1080, height: 720)
        case .square: return CGSize(width: 900, height: 900)
        }
    }
}

struct DocumentExportOutput: Identifiable {
    let id = UUID()
    var format: DocumentExportFormat
    var files: [URL]
    var previewText: String?
    var warnings: [String]
    var directory: URL
}

enum DocumentExportError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}

enum DocumentExportNames {
    static func filename(_ title: String) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:?%*|\"<>"))
        let name = title.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty || name == "." || name == ".." ? "Document" : name).prefix(100))
    }
    static func xml(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
            let n = scalar.value
            return n == 9 || n == 10 || n == 13 || (32...0xD7FF).contains(n) || (0xE000...0xFFFD).contains(n) || (0x10000...0x10FFFF).contains(n)
        }))
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
