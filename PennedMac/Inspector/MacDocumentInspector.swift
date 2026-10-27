import SwiftUI

struct MacDocumentInspector: View {
    @ObservedObject var workspace: MacWorkspaceModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(MacInspectorSection.allCases) { section in
                    Button { workspace.inspector = section } label: {
                        Text(section.title).font(.system(size: 12, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .foregroundStyle(workspace.inspector == section ? VellixSurface.lilac : VellixSurface.secondaryInk)
                            .background(workspace.inspector == section ? VellixSurface.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                }
            }.padding(10)
            Divider()
            if let model = workspace.activeEditor {
                MacInspectorContent(workspace: workspace, model: model).id(model.documentID)
            } else {
                ContentUnavailableView { Label { Text("No Document Selected") } icon: { LibraryIcon(name: "linedpages", size: 32) } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxHeight: .infinity, alignment: .top).background(.regularMaterial)
    }
}

private struct MacInspectorContent: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var model: DocumentEditorModel
    var body: some View {
        ScrollView {
            Group {
                switch workspace.inspector {
                case .insert: MacInsertInspector(workspace: workspace, model: model)
                case .format: MacFormatInspector(workspace: workspace, session: model.session)
                case .style: MacStyleInspector(workspace: workspace, model: model)
                case .info: MacInfoInspector(workspace: workspace, model: model)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
