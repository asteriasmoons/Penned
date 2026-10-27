import Combine
import SwiftUI

enum MacInspectorSection: String, CaseIterable, Identifiable {
    case insert, format, style, info
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@MainActor final class MacSidebarState: ObservableObject {
    @Published var scroll = ScrollPosition(edge: .top)
    @Published var expandedFolders: Set<String> = []
    @Published var starredExpanded = true
    @Published var foldersExpanded = true
    @Published var tagsExpanded = true
}

@MainActor final class MacDocumentViewState: ObservableObject {
    @Published var scroll = ScrollPosition(edge: .top)
}
