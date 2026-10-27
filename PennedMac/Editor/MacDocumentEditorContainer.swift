import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct MacDocumentEditorContainer: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var model: DocumentEditorModel
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    @State private var locked = false
    @State private var title = ""
    @State private var publishingDocument: DocumentRecord?
    @FocusState private var titleFocused: Bool
    private var active: Bool { workspace.activeTab.location.documentID == model.documentID }
    var body: some View {
        VStack(spacing: 0) {
            toolbar.zIndex(1)
            if workspace.findInDocument && active { MacFindBar(session: model.session) }
            MacDocumentSurface(model: model, session: model.session, title: $title, titleFocused: $titleFocused,
                active: active, locked: locked, workspace: workspace, state: workspace.viewState(for: model.documentID))
        }
        .modifier(MacEditorPresentations(workspace: workspace, model: model, locked: locked))
        .sheet(item: $publishingDocument) { document in PublishingSheet(document: document, queue: environment.publishing) }
        .modifier(TagEditorIntegration(model: model, session: model.session, locked: locked || !active))
        .onAppear {
            title = model.document?.title ?? ""
            let pendingTitle = $title
            model.prepareForSpaceChange = { [weak model] in
                guard let model, let document = model.document else { return }
                let value = pendingTitle.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && value != document.title {
                    model.rename(title: value)
                    if model.document?.title != value { throw VellixError.database(model.errorMessage ?? "The document title could not be saved.") }
                }
            }
            model.session.setApplicationColorScheme(colorScheme)
            model.session.setEditable(active && !locked)
        }
        .onChange(of: active) { _, value in
            if !value { persistTitle(); model.session.pauseAttachmentPlayback() }
            model.session.setEditable(value && !locked)
            if value { focusEditor() }
        }
        .onChange(of: locked) { _, value in model.session.setEditable(active && !value) }
        .onChange(of: colorScheme) { _, value in model.session.setApplicationColorScheme(value) }
        .onChange(of: titleFocused) { _, focused in if !focused { persistTitle() } }
        .onReceive(model.$document) { document in if !titleFocused, let document { title = document.title } }
        .onReceive(NotificationCenter.default.publisher(for: .vellixTasksChanged).receive(on: RunLoop.main)) { _ in model.refreshTaskHistoryPage() }
        .onReceive(model.session.$isReady) { ready in if ready && active { focusEditor() } }
        .onReceive(model.$nestedPageToOpen) { document in
            guard active, let document else { return }
            model.nestedPageToOpen = nil; workspace.perform { try await workspace.open(document) }
        }
        .onDisappear { persistTitle(); model.session.pauseAttachmentPlayback(); model.flushPendingSave() }
    }
    private var toolbar: some View {
        HStack(spacing: 8) {
            MacIconButton("Back", icon: "chevleft") { workspace.perform { try await workspace.travel(-1) } }.disabled(!workspace.canGoBack)
            MacIconButton("Forward", icon: "chevright") { workspace.perform { try await workspace.travel(1) } }.disabled(!workspace.canGoForward)
            Text(model.document?.title ?? "Document").font(.system(size: 12, weight: .heavy, design: .rounded)).lineLimit(1)
            Spacer()
            if model.document?.templateID != nil {
                Button("Save Template") { workspace.perform { _ = try await model.saveTemplateEdits() } }.disabled(!model.templateNeedsSave)
                MacIconButton("Toggle Placeholder Editing", icon: "selectsparkle") { model.session.togglePlaceholderMode() }
            }
            MacEditorSaveStatus(session: model.session)
            MacIconButton(locked ? "Unlock Editor" : "Lock Editor", icon: locked ? "eyeslash" : "eye") { locked.toggle() }
            Button {
                workspace.perform {
                    try model.prepareForSpaceChange?()
                    try await model.captureAndSave()
                    guard active else { return }
                    publishingDocument = try environment.documents.requireDocument(id: model.documentID)
                }
            } label: { LibraryIcon(name: "sendbutton", size: 17) }
                .help("Share").accessibilityLabel("Share")
        }
        .controlSize(.small).padding(.horizontal, 14).frame(height: 42).background(.thinMaterial)
    }
    private func persistTitle() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty && value != model.document?.title { model.rename(title: value) }
    }
    private func focusEditor() {
        guard active, !locked, !titleFocused, model.session.isReady else { return }
        workspace.window?.makeFirstResponder(model.webViewStore.webView)
        model.session.focus()
    }
}

private struct MacEditorSaveStatus: View {
    @ObservedObject var session: TipTapEditorSession
    var body: some View {
        Text(session.saveState.label).font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary).lineLimit(1).frame(minWidth: 30)
    }
}

private struct MacEditorBodyBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

private struct MacDocumentSurface: View {
    @ObservedObject var model: DocumentEditorModel
    @ObservedObject var session: TipTapEditorSession
    @Binding var title: String
    var titleFocused: FocusState<Bool>.Binding
    let active: Bool
    let locked: Bool
    @ObservedObject var workspace: MacWorkspaceModel
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var state: MacDocumentViewState
    private var appearance: DocumentAppearance { model.appearance.resolved(for: colorScheme) }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DocumentStyleSurface(style: appearance.editorBackground, store: environment.attachmentStore, theme: appearance.themeID)
                ScrollView {
                    if let document = model.document {
                        VStack(alignment: .leading, spacing: 18) {
                            if appearance.displaysCover {
                                Group {
                                    if let cover = CardImageLoader.image(path: document.cover, store: environment.attachmentStore) {
                                        Image(decorative: cover, scale: 1).resizable().scaledToFill()
                                    } else { ThemeCoverArt(theme: appearance.resolvedCoverTheme) }
                                }
                                .frame(height: min(360, max(170, geometry.size.width * 0.46)))
                                .clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            HStack(spacing: 10) {
                                if DocumentTaskPages.isDetail(document.id), let task = model.historyPageTask {
                                    TaskHistoryPageHeader(task: task, appearance: appearance, title: $title,
                                        saveTitle: { model.rename(title: $0) }, titleFocused: titleFocused, titleSize: 26, locked: locked)
                                } else {
                                TextField("Untitled", text: $title, axis: .vertical).textFieldStyle(.plain)
                                    .font(.system(size: 26, weight: .black, design: appearance.fontStyle.design))
                                    .foregroundStyle(Color(vellixHex: appearance.textColorHex)).focused(titleFocused)
                                    .onSubmit { model.rename(title: title) }.disabled(locked)
                                }
                                MacIconButton("Document Icon", icon: document.icon ?? "linedpages") { workspace.showIconPicker = true }
                                    .foregroundStyle(Color(vellixHex: appearance.textColorHex))
                            }
                            Rectangle().fill(Color(vellixHex: appearance.textColorHex).opacity(0.1)).frame(height: 1)
                            CollectionDocumentFields(store: environment.collections, documentID: document.id, appearance: appearance, onBeginEditing: {})
                            editor(document)
                            let entries = environment.collections.embeddedEntryIDs(document.id)
                            ForEach(model.children.filter { !model.pageReferenceIDs.contains($0.id) && !entries.contains($0.id) }) { child in
                                Button { workspace.perform { try await workspace.open(child) } } label: {
                                    if let style = child.cardStyle {
                                        PageCardView(document: child, style: style,
                                            photo: CardImageLoader.image(path: style.imagePath, store: environment.attachmentStore),
                                            fillsDocumentWidth: true, attachmentStore: environment.attachmentStore)
                                    } else { NestedPageRow(document: child, appearance: appearance) {} }
                                }.buttonStyle(.plain).contextMenu { MacDocumentMenu(document: child, workspace: workspace) }
                            }
                            Color.clear.frame(height: 28).contentShape(Rectangle()).onTapGesture { session.focusDocumentEnd() }
                        }
                        .padding(MacDocumentLayout.contentInset)
                        .backgroundPreferenceValue(MacEditorBodyBounds.self) { bounds in
                            GeometryReader { proxy in
                                let bodyY = bounds.map { proxy[$0].minY } ?? 0
                                let breaks = session.pageBreakRegions.map { PreviewPageBreak(y: $0.y, height: $0.height) }
                                let segments = PreviewPageBreak.segments(breaks, bodyY: bodyY, totalHeight: proxy.size.height)
                                ZStack(alignment: .top) {
                                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                        DocumentStyleSurface(style: document.isThemed || model.appearance.followsApplicationAppearance(.paper) ? appearance.innerPageBackground : appearance.editorBackground, store: environment.attachmentStore)
                                            .overlay { if !document.isThemed && !model.appearance.followsApplicationAppearance(.paper) && appearance.presentationColorScheme == .dark { Color.black.opacity(0.30) } }
                                            .frame(height: segment.height).clipShape(RoundedRectangle(cornerRadius: 16))
                                            .offset(y: segment.y)
                                    }
                                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            }
                        }
                        .frame(maxWidth: MacDocumentLayout.maximumPageWidth)
                        .padding(.horizontal, max(24, min(56, geometry.size.width * 0.045)))
                        .padding(.vertical, 30).frame(maxWidth: .infinity)
                    }
                }.scrollPosition($state.scroll)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onReceive(session.caretUpdates) { update in
            guard active, session.isEditing, let update, let scroll = model.webViewStore.webView.enclosingScrollView,
                  let document = scroll.documentView else { return }
            let rect = model.webViewStore.webView.convert(update.rect, to: document)
            document.scrollToVisible(rect.insetBy(dx: 0, dy: -24))
        }
    }
    private func editor(_ document: DocumentRecord) -> some View {
        TipTapWebView(session: session, store: model.webViewStore, documentID: document.id, canonicalJSON: document.tipTapJSON)
            .frame(height: max(220, session.editorContentHeight))
            .allowsHitTesting(active && !locked)
            .accessibilityLabel("Document Editor")
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(session.collectionRegions) { region in
                        if let snapshot = environment.collections.snapshots[region.collectionID], snapshot.activeView?.kind == .kanban {
                            CollectionKanbanView(store: environment.collections, collectionID: region.collectionID, blockID: region.id,
                                editable: active && !locked && session.selectionMode == "off", appearance: appearance, savedSnapshot: snapshot,
                                onRequest: { model.collectionEditorRequest = $0 }, onHeightChange: { height in
                                    if let view = snapshot.activeView?.id {
                                        session.nativeCollectionDidLayout(blockID: region.id, viewID: view, height: height, needsResize: abs(region.rect.height - height) > 1)
                                    }
                                })
                                .frame(width: region.rect.width, height: region.rect.height).offset(x: region.rect.minX, y: region.rect.minY)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .overlay(alignment: .topLeading) {
                if let menu = session.slashMenuState, active {
                    MacSlashMenu(state: menu, session: session).frame(width: min(menu.width, 340))
                        .offset(x: max(0, menu.anchorX), y: menu.anchorY + 8)
                }
            }
            .anchorPreference(key: MacEditorBodyBounds.self, value: .bounds) { $0 }
    }
}

private struct MacSlashMenu: View {
    let state: TipTapSlashMenuState
    let session: TipTapEditorSession
    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                    Button { session.chooseSlashMenuItem(item.key) } label: {
                        HStack(spacing: 10) {
                            LibraryIcon(name: item.icon, size: 18)
                            Text(item.title).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(8).contentShape(Rectangle())
                            .background(index == state.selectedIndex ? VellixSurface.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                }
            }.padding(6)
        }.frame(maxHeight: 300).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(VellixSurface.hairline)).shadow(color: VellixSurface.shadow, radius: 15)
    }
}

struct MacFindBar: View {
    let session: TipTapEditorSession
    @State private var query = ""
    @State private var found = true
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            LibraryIcon(name: "searchwavy", size: 16)
            TextField("Find in document", text: $query).textFieldStyle(MacInputStyle()).focused($focused).onSubmit { find() }
            if !found { Text("Not found").font(.caption).foregroundStyle(.secondary) }
            Button("Next", action: find).disabled(query.isEmpty)
        }.padding(10).background(.regularMaterial).onAppear { focused = true }
    }
    private func find() {
        guard let web = session.tagNavigationWebView, !query.isEmpty else { return }
        let config = WKFindConfiguration(); config.wraps = true
        web.find(query, configuration: config) { result in found = result.matchFound }
    }
}

@MainActor enum MacEditorFiles {
    static func choose(workspace: MacWorkspaceModel, model: DocumentEditorModel, imagesOnly: Bool = false) {
        workspace.perform {
            let token = try await model.session.attachmentCommand("attachmentCaptureInsertion") as? String
            guard workspace.isAuthorized, workspace.activeEditor === model else { return }
            let panel = NSOpenPanel(); panel.allowedContentTypes = imagesOnly ? [.image] : [.item]
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
            let response: NSApplication.ModalResponse
            if let window = workspace.window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK, workspace.isAuthorized, workspace.activeEditor === model else { return }
            await model.importAttachments(urls: Array(panel.urls.prefix(20)), token: token)
            try await model.captureAndSave()
        }
    }
}
