import SwiftUI

struct MacInsertItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let category: String
    static let all: [Self] = [
        .init(id: "nestedPage", title: "Page", icon: "linedpages", category: "Nested Content"),
        .init(id: "pageCard", title: "Card", icon: "copy", category: "Nested Content"),
        .init(id: "table", title: "Table", icon: "gridboard", category: "Rich Blocks"),
        .init(id: "collection", title: "Collection", icon: "gridboard", category: "Rich Blocks"),
        .init(id: "codeBlock", title: "Code Block", icon: "codewindow", category: "Rich Blocks"),
        .init(id: "callout", title: "Callout", icon: "sparkle", category: "Rich Blocks"),
        .init(id: "quote", title: "Quote", icon: "quote", category: "Rich Blocks"),
        .init(id: "image", title: "Image", icon: "imagesign", category: "Media"),
        .init(id: "file", title: "File", icon: "openedfolder", category: "Media"),
        .init(id: "checkListItem", title: "Task List", icon: "checklist", category: "Lists"),
        .init(id: "bulletListItem", title: "Bulleted List", icon: "bulletlist", category: "Lists"),
        .init(id: "numberedListItem", title: "Numbered List", icon: "numberlist", category: "Lists"),
        .init(id: "toggleListItem", title: "Toggle List", icon: "chevright", category: "Lists"),
        .init(id: "heading1", title: "Title", icon: "boldtext", category: "Text Styles"),
        .init(id: "heading2", title: "Subtitle", icon: "boldtext", category: "Text Styles"),
        .init(id: "heading3", title: "Heading", icon: "boldtext", category: "Text Styles"),
        .init(id: "heading4", title: "Subheading", icon: "boldtext", category: "Text Styles"),
        .init(id: "paragraph", title: "Paragraph", icon: "linedpages", category: "Text Styles"),
        .init(id: "caption", title: "Caption", icon: "linedpages", category: "Text Styles")
    ]
}

struct MacInsertInspector: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var model: DocumentEditorModel
    @State private var search = ""
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    var body: some View {
        VStack(spacing: 12) {
            TextField("Search Blocks", text: $search).textFieldStyle(MacInputStyle())
            ForEach(["Nested Content", "Rich Blocks", "Media", "Lists", "Text Styles"], id: \.self) { category in
                let items = MacInsertItem.all.filter { $0.category == category && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
                if !items.isEmpty {
                    MacInspectorSectionHeader(title: category)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(items) { item in
                            Button { insert(item) } label: {
                                VStack(spacing: 6) {
                                    LibraryIcon(name: item.icon, size: 24).frame(maxWidth: .infinity).frame(height: 52)
                                        .background(VellixSurface.input, in: RoundedRectangle(cornerRadius: 7))
                                    Text(item.title).font(.system(size: 10, weight: .semibold, design: .rounded)).lineLimit(2)
                                        .frame(height: 26, alignment: .top)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Insert \(item.title)")
                        }
                    }
                }
            }
            if search.isEmpty || "separator divider page break".localizedCaseInsensitiveContains(search) {
                MacInspectorSectionHeader(title: "Separators")
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(VellixDividerStyle.allCases) { style in
                        Button(style.title) { model.session.insertDivider(style) }.font(.system(size: 10, weight: .semibold)).frame(height: 40)
                    }
                    Button("Page Break") { model.session.insertPageBreak() }.font(.system(size: 10, weight: .semibold)).frame(height: 40)
                }
            }
            let properties = InlinePropertyKind.allCases.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            if !properties.isEmpty {
                MacInspectorSectionHeader(title: "Properties")
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(properties) { kind in Button(kind.title) { model.session.insertBlock("property:" + kind.rawValue) }.font(.caption).frame(height: 36) }
                }
            }
            if model.document?.templateID != nil {
                MacInspectorSectionHeader(title: "Template Components")
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(TemplateComponentKind.allCases.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { kind in
                        Button(kind.title) { model.templateComponentRequest = TemplateComponentRequest(definition: TemplateComponentDefinition(kind: kind)) }.font(.caption).frame(height: 36)
                    }
                }
            }
        }
    }
    private func insert(_ item: MacInsertItem) {
        guard workspace.isAuthorized else { return }
        if item.id == "image" || item.id == "file" { MacEditorFiles.choose(workspace: workspace, model: model, imagesOnly: item.id == "image") }
        else { model.session.insertBlock(item.id) }
    }
}
