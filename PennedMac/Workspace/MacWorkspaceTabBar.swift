import SwiftUI

struct MacWorkspaceTabBar: View {
    @ObservedObject var workspace: MacWorkspaceModel
    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        MacTabLabel(workspace: workspace, tab: tab)
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { values, _ in
                                guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                                workspace.moveTab(id, before: tab.id); return true
                            }
                    }
                    MacIconButton("New Tab", icon: "addwavy") { workspace.perform { try await workspace.newTab() } }
                        .frame(width: 32, height: 30).id("new-tab")
                }
            }
            .onChange(of: workspace.tabs.count) { _, _ in reader.scrollTo("new-tab", anchor: .trailing) }
        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 32)
    }
}

private struct MacTabLabel: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var tab: MacWorkspaceTab
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 7) {
            LibraryIcon(name: workspace.icon(tab), size: 14)
            Button { workspace.perform { try await workspace.selectTab(tab.id) } } label: {
                Text(workspace.title(tab)).lineLimit(1).frame(minWidth: 60, maxWidth: 180, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("mac-tab-" + tab.id.uuidString)
            Button { workspace.perform { try await workspace.closeTab(tab.id) } } label: {
                LibraryIcon(name: "xmarkwavy", size: 12).frame(width: 20, height: 20)
            }.buttonStyle(.plain).opacity(hovered || tab.id == workspace.activeID ? 1 : 0)
                .accessibilityLabel("Close \(workspace.title(tab))")
        }
        .font(.system(size: 12, weight: tab.id == workspace.activeID ? .bold : .medium, design: .rounded))
        .foregroundStyle(tab.id == workspace.activeID ? VellixSurface.ink : VellixSurface.secondaryInk)
        .padding(.leading, 10).padding(.trailing, 4).frame(height: 30)
        .background(tab.id == workspace.activeID ? VellixSurface.activeTab : hovered ? VellixSurface.subtleFill : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }.accessibilityAddTraits(tab.id == workspace.activeID ? .isSelected : [])
        .contextMenu {
            Button("Duplicate Tab") { workspace.perform { try await workspace.newTab(tab.location) } }
            Button("Close Tab") { workspace.perform { try await workspace.closeTab(tab.id) } }
        }
    }
}
