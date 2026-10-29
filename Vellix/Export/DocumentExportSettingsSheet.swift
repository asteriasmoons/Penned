import SwiftUI

struct DocumentExportSettingsSheet: View {
    let format: DocumentExportFormat
    @Binding var settings: DocumentExportSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if format == .markdown || format == .textBundle { markdown }
                else { visual }
            }.padding(20)
        }
        .font(.system(.body, design: .rounded))
        .pennedSheet(title: "Export Settings", close: { dismiss() })
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(width: 520, height: 650)
        #endif
    }

    private var visual: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("General")
                if format == .image {
                    Picker("Page Size", selection: $settings.imageShape) { ForEach(ExportImageShape.allCases) { Text($0.rawValue).tag($0) } }
                } else {
                    Picker("Paper Size", selection: $settings.paper) { ForEach(ExportPaper.allCases) { Text($0.rawValue).tag($0) } }
                }
                Picker("Font Size", selection: $settings.fontSize) { ForEach(ExportFontSize.allCases) { Text($0.rawValue).tag($0) } }
            }.pickerStyle(.menu)
            VStack(alignment: .leading, spacing: 20) {
                sectionTitle("Details")
                Toggle("Show Document Title", isOn: $settings.showTitle)
                Toggle("Show Cover Image", isOn: $settings.showCover)
                if format == .pdf || format == .print { Toggle("Show Page Numbers", isOn: $settings.showPageNumbers) }
                if format != .word { Toggle("Show Watermark", isOn: $settings.showWatermark) }
                Toggle("Show Tags", isOn: $settings.showTags)
            }
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Appearance")
                Toggle("Use Style", isOn: $settings.useStyle)
            }
        }
    }
    private var markdown: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker("Heading Size", selection: $settings.headingLevel) {
                ForEach(1...6, id: \.self) { Text("H\($0) (\(String(repeating: "#", count: $0)))").tag($0) }
            }
            Picker("Strong Emphasis Style", selection: $settings.strongDelimiter) { Text("**").tag("**"); Text("__").tag("__") }
            Picker("Italics Emphasis Style", selection: $settings.italicDelimiter) { Text("*").tag("*"); Text("_").tag("_") }
            Picker("Horizontal Rule Style", selection: $settings.rule) { Text("---").tag("---"); Text("***").tag("***"); Text("___").tag("___") }
            Toggle("Show Document Title", isOn: $settings.showTitle)
            Toggle("Show Cover Image", isOn: $settings.showCover)
            Toggle("Show Tags", isOn: $settings.showTags)
        }.pickerStyle(.menu)
    }
    private func sectionTitle(_ title: String) -> some View { Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
}
