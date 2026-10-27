import SwiftUI

struct TagBrowserView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.pennedWorkspace) private var workspace
    @Environment(\.pennedGalleryColumns) private var preferredColumns
    @State private var availableWidth: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var query = ""
    @State private var scope = LibrarySearchScope.keyword
    @State private var snapshot = TagBrowserSnapshot()
    @State private var matchingDocument: TaggedDocument?
    private let accent = VellixSurface.lilac
    private var columnCount: Int {
        workspace == nil ? 2 : (availableWidth > 0
            ? PadWorkspaceMetrics.galleryColumns(width: max(0, availableWidth - 32), preferred: preferredColumns) : preferredColumns)
    }
    private var cardWidth: CGFloat? {
        workspace != nil && availableWidth > 0
            ? PadWorkspaceMetrics.galleryCardWidth(available: availableWidth, columns: columnCount) : nil
    }

    private var title: String {
        let selected = snapshot.tags.filter { environment.selectedTagIDs.contains($0.id) }
        return selected.isEmpty ? "All Tags" : selected.map { "#" + $0.name }.joined(separator: " + ")
    }
    private var visibleTags: [DocumentTag] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        return snapshot.tags.filter { environment.selectedTagIDs.contains($0.id) || search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var requestKey: String {
        (environment.selectedSpaceID ?? "") + environment.selectedTagIDs.sorted().joined(separator: ",") + "|" + query + "|" + scope.rawValue
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.system(.largeTitle, design: .rounded).weight(.black))
                    .fixedSize(horizontal: false, vertical: true)
                LibrarySearchField(query: $query, scope: $scope)
                    .font(.system(.body, design: .rounded).weight(.black))
                    .fontDesign(.rounded).fontWeight(.black)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleTags) { tag in
                            let selected = environment.selectedTagIDs.contains(tag.id)
                            Button {
                                if selected { environment.selectedTagIDs.remove(tag.id) }
                                else { environment.selectedTagIDs.insert(tag.id) }
                            } label: {
                                HStack(spacing: 6) {
                                    Text("#" + tag.name)
                                    if selected {
                                        LibraryIcon(name: "xmarkwavy", size: 14)
                                    } else {
                                        Text(String(snapshot.documentCounts[tag.id] ?? 0)).foregroundStyle(.secondary)
                                    }
                                }.font(.system(.subheadline, design: .rounded).weight(.black))
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .foregroundStyle(selected ? accent : .primary)
                                    .background(selected ? accent.opacity(0.18) : VellixSurface.controlInk.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityLabel("#" + tag.name)
                                .accessibilityHint(selected ? "Remove tag filter" : "Filter by this tag")
                        }
                    }
                }
                if snapshot.documents.isEmpty {
                    VStack(spacing: 8) {
                        Text(query.isEmpty && environment.selectedTagIDs.isEmpty ? "No tagged documents" : "No matching documents")
                            .font(.system(.headline, design: .rounded).weight(.black))
                    }.frame(maxWidth: .infinity).padding(.vertical, 48)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(0..<columnCount, id: \.self) { column in
                            LazyVStack(spacing: 12) {
                                ForEach(Array(snapshot.documents.enumerated()).filter { $0.offset % columnCount == column }.map(\.element)) { result in card(result) }
                            }.frame(width: cardWidth).frame(maxWidth: workspace == nil ? .infinity : nil, alignment: workspace == nil ? .top : .topLeading)
                        }
                    }
                }
            }
            .frame(width: workspace != nil && availableWidth > 0
                ? PadWorkspaceMetrics.galleryWidth(available: availableWidth, columns: columnCount) : nil, alignment: .leading)
            .padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: workspace == nil ? .center : .leading)
            .padding(.top, 12).padding(.bottom, 110)
        }
        .scrollPosition($scrollPosition)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .background(VellixSurface.workspace).navigationTitle("").navigationBarBackButtonHidden()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    if environment.selectedTagIDs.isEmpty { environment.selectedDestination = .home }
                    else { environment.selectedTagIDs = [] }
                } label: { LibraryIcon(name: "chevleft", size: 18) }.accessibilityLabel("Back")
            }
        }
        .task(id: requestKey) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .pennedTagsChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .pennedCollectionsChanged)) { _ in reload() }
        .sheet(item: $matchingDocument) { result in
            MatchingTagBlocksSheet(documentID: result.id, selectedTags: environment.selectedTagIDs, query: query, titleOnly: scope == .title)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    private func card(_ result: TaggedDocument) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { environment.tagNavigationTarget = nil; environment.select(result.document) } label: {
                LibraryDocumentPreview(document: result.document, showsStar: false, visibleHeightFraction: LibraryDocumentPreview.phoneGalleryHeightFraction
                    ?? (workspace == nil ? 1 : PadWorkspaceMetrics.galleryPreviewHeightFraction))
            }.buttonStyle(.plain).contextMenu { DocumentContextMenu(document: result.document) }
            Button { matchingDocument = result } label: {
                Text(result.blocks.count > 50 ? "50+" : String(result.blocks.count))
                    .font(.system(size: 15, weight: .black, design: .rounded)).monospacedDigit().foregroundStyle(VellixSurface.inverseInk)
                    .frame(minWidth: 32, minHeight: 32).padding(.horizontal, 4)
                    .background(accent, in: RoundedRectangle(cornerRadius: 8)).padding(10)
            }.buttonStyle(.plain).accessibilityLabel("\(result.blocks.count) matching blocks in \(result.document.title)")
        }
    }

    private func reload() {
        do { snapshot = try environment.tags.snapshot(selected: environment.selectedTagIDs, query: query, titleOnly: scope == .title) }
        catch { environment.report(error) }
    }
}

private struct MatchingTagBlocksSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let documentID: String
    let selectedTags: Set<String>
    let query: String
    let titleOnly: Bool
    @State private var result: TaggedDocument?
    @State private var selectedNames: Set<String> = []
    @State private var target: TaggedBlock?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let document = result?.document {
                    LibraryDocumentPreview(document: document, fixedAspectRatio: 0.72, showsStar: false, cornerRadius: 3).frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(document.title).font(.system(.headline, design: .rounded).weight(.black)).lineLimit(2)
                        Text(document.updatedAt, style: .relative).font(.system(.caption, design: .rounded).weight(.black)).foregroundStyle(.secondary)
                    }
                } else { Text("Matching Blocks").font(.system(.headline, design: .rounded).weight(.black)) }
                Spacer()
            }.padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(result?.blocks ?? []) { block in
                        Button { target = block; dismiss() } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(block.breadcrumbs.joined(separator: " > ")).font(.system(.subheadline, design: .rounded).weight(.black)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                highlighted(block).font(.system(.body, design: .rounded).weight(.black)).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if result?.blocks.isEmpty != false {
                        Text("These tagged blocks are no longer available.")
                            .font(.system(.body, design: .rounded).weight(.black)).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                }.padding(20)
            }
        }
        .pennedSheet(close: { dismiss() })
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .pennedTagsChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .pennedCollectionsChanged)) { _ in reload() }
        .onDisappear { if let target { Task { await environment.openTaggedBlock(target, selectedTags: selectedTags) } } }
    }

    private func highlighted(_ block: TaggedBlock) -> Text {
        var text = AttributedString()
        for run in block.runs {
            let active = run.tagName.map { selectedNames.isEmpty || selectedNames.contains($0) } ?? false
            var piece = AttributedString(run.text)
            if active {
                piece.font = .system(.body, design: .rounded).weight(.black)
                piece.foregroundColor = VellixSurface.lilac
                piece.backgroundColor = VellixSurface.lilac.opacity(0.12)
            }
            text.append(piece)
        }
        return Text(text)
    }

    private func reload() {
        do {
            let snapshot = try environment.tags.snapshot(selected: selectedTags, query: query, titleOnly: titleOnly)
            result = snapshot.documents.first { $0.id == documentID }
            selectedNames = Set(snapshot.tags.filter { selectedTags.contains($0.id) }.map(\.normalizedName))
        } catch { environment.report(error) }
    }
}
