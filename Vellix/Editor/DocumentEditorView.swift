//
//  DocumentEditorView.swift
//  Vellix
//

import Combine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private enum DocumentEditorCoordinateSpace {
    static let workspace = "DocumentEditorWorkspace"
}

#if canImport(UIKit)
/// Holds a weak reference to the document's backing UIScrollView so the editor can
/// drive it programmatically (e.g. lifting a table above the editing sheet).
final class DocumentScrollProxy {
    weak var scrollView: UIScrollView?
    var pendingCaretRevision: Int?
    var caretRevealQueued = false
    private var topBoundaryObservation: NSKeyValueObservation?

    func attach(to scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        topBoundaryObservation?.invalidate()
        self.scrollView = scrollView
        topBoundaryObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { scrollView, _ in
            let top = -scrollView.adjustedContentInset.top
            guard scrollView.contentOffset.y < top else { return }
            // Clamp only the top edge; bottom overscroll remains native.
            scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: top)
        }
    }
}

/// Transparent probe placed inside the document ScrollView; it walks up to the
/// enclosing UIScrollView and hands it to the proxy. Does not affect layout or hit-testing.
private struct DocumentScrollViewFinder: UIViewRepresentable {
    let proxy: DocumentScrollProxy

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        DispatchQueue.main.async { locate(from: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if proxy.scrollView == nil {
            DispatchQueue.main.async { locate(from: uiView) }
        }
    }

    private func locate(from view: UIView) {
        var candidate: UIView? = view.superview
        while let current = candidate {
            if let scrollView = current as? UIScrollView {
                proxy.attach(to: scrollView)
                return
            }
            candidate = current.superview
        }
    }
}
#endif

private struct EditorSurfaceFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct SavedDocumentBodyHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PageSheetEditorBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct DocumentEditorView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var publishingDocument: DocumentRecord?
    @Environment(\.pennedWorkspace) private var workspace
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var model: DocumentEditorModel
    private let sidebarAction: (() -> Void)?
    @State private var titleText = ""
    @FocusState private var isTitleFocused: Bool
    @State private var showSnapshots = false
    @State private var showAppearance = false
    @State private var showIconPicker = false
    @State private var showFileImporter = false
    @State private var fileInsertionToken: String?
    @State private var fileInsertionDocumentID: String?
    @State private var showCalloutIconPicker = false
    @State private var textColorRequest: InlineTextColorEditorRequest?
    @State private var preparingTextColor = false
    @State private var blockquoteColorRequest: BlockquoteColorRequest?
    @State private var calloutColorRequest: CalloutColorRequest?
    @State private var propertyEditorRequest: InlinePropertyEditorRequest?
    @State private var collectionEditorRequest: CollectionEditorRequest?
    @State private var collectionEntryIDs = Set<String>()
    @State private var propertyEditorReturnTarget: (documentID: String, blockID: String)?
    @State private var selectedBlockquoteColor = Color.white
    @State private var localAppearance = DocumentAppearance.plain
    @State private var localCover: String?
    @State private var calloutText = ""
    @State private var calloutIcon = "sparkle"
    @State private var calloutIconTargetBlockID: String?
    @State private var selectedCalloutColor = Color.white
    @State private var editorContentHeight: CGFloat = 320
    @State private var editorVisualContentBottom: CGFloat = 320
    @State private var selectedBlockCount = 0
    @State private var isEditingDocument = false
    @State private var isKeyboardVisible = false
    @State private var isEditorLocked = false
    @State private var showSelectedActions = false
    @State private var selectionMode: EditorSelectionMode = .off
    @State private var selectedStylePanel: SelectionStylePanel?
    @State private var editorSurfaceFrame: CGRect = .zero
    #if canImport(UIKit)
    @State private var documentScrollProxy = DocumentScrollProxy()
    @State private var keyboardFrame = CGRect.null
    #endif
    @State private var slashMenuState: TipTapSlashMenuState?
    @State private var pageBreakRegions: [TipTapPageBreakRegion] = []
    @State private var collectionRegions: [TipTapCollectionRegion] = []
    @State private var presentationReady = false
    @State private var savedBodyHeight: CGFloat = 0
    @State private var pageDeletionTarget: DocumentRecord?
    @State private var blockDeletionRequest: BlockDeletionRequest?
    @State private var placeholderMode = false
    @State private var canUseTemplateControls = false
    @State private var editorBanner: EditorStatusBanner?

    init(model: DocumentEditorModel, sidebarAction: (() -> Void)? = nil) {
        self.model = model
        self.sidebarAction = sidebarAction
        _editorContentHeight = State(initialValue: model.session.editorContentHeight)
        _editorVisualContentBottom = State(initialValue: model.session.editorVisualContentBottom)
        _pageBreakRegions = State(initialValue: model.session.pageBreakRegions)
        _collectionRegions = State(initialValue: model.session.collectionRegions)
        _presentationReady = State(initialValue: model.session.isPresentationReady)
        _placeholderMode = State(initialValue: model.session.placeholderMode)
        _canUseTemplateControls = State(initialValue: model.session.isReady && !model.session.isLoadingDocument)
    }

    private var editorLifecycleContent: some View {
        ZStack {
            VellixSurface.appBackground.ignoresSafeArea()

            if let document = model.document {
                documentWorkspace(document)
            }
        }
        .onAppear {
            model.session.setApplicationColorScheme(colorScheme)
            syncLocalState()
            model.prepareForSpaceChange = {
                guard let document = model.document, titleText != document.title else { return }
                let saved = try environment.documents.updateTitle(id: document.id, title: titleText)
                model.document = saved
            }
            if environment.selectedDocumentID == model.documentID {
                updateCollectionPresentation()
            }
        }
        .onChange(of: colorScheme) { _, scheme in model.session.setApplicationColorScheme(scheme) }
        .onReceive(environment.collections.$revision) { _ in updateCollectionPresentation() }
        .onReceive(NotificationCenter.default.publisher(for: .vellixTasksChanged).receive(on: RunLoop.main)) { _ in model.refreshTaskHistoryPage() }
        .onChange(of: model.pageReferenceIDs) { _, _ in updateCollectionPresentation() }
        .onReceive(model.$collectionEditorRequest) { request in
            guard let request else { return }
            model.collectionEditorRequest = nil
            handleCollectionRequest(request)
        }
        .onReceive(model.session.$placeholderMode) { placeholderMode = $0 }
        .onReceive(model.$taskFeedback) { message in
            guard let message, environment.selectedDocumentID == model.documentID else { return }
            showEditorBanner(message, icon: "clockfill")
            model.taskFeedback = nil
        }
        .onChange(of: placeholderMode) { _, active in
            guard model.document?.templateID != nil, environment.selectedDocumentID == model.documentID else { return }
            showEditorBanner(active ? "Placeholder Mode On" : "Placeholder Mode Off", icon: "linedpages")
        }
        .onReceive(model.session.$isReady) { ready in
            canUseTemplateControls = ready && !model.session.isLoadingDocument
        }
        .onReceive(model.session.$isLoadingDocument) { loading in
            canUseTemplateControls = model.session.isReady && !loading
        }
        .task(id: editorBanner?.id) {
            guard editorBanner != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            withAnimation(.easeOut(duration: 0.18)) { editorBanner = nil }
        }
        .onChange(of: environment.selectedDocumentID) { oldValue, newValue in
            dismissBlockDeletion()
            if newValue == model.documentID {
                updateCollectionPresentation()
            }
            guard oldValue == model.documentID, newValue != model.documentID else {
                return
            }
            model.session.endTextColorEditing(restoreFocus: false)
            textColorRequest = nil
            model.taskHistoryRequest = nil
            deactivateEditor()
        }
        .onChange(of: model.document?.id) { _, _ in
            editorBanner = nil
            syncLocalState()
        }
        .onChange(of: model.document?.title) { _, newValue in
            if !isTitleFocused { titleText = newValue ?? "" }
        }
        .onChange(of: isTitleFocused) { _, focused in
            if !focused { persistTitle() }
        }
    }

    private var editorViewportContent: some View {
        editorLifecycleContent
        .onChange(of: localAppearance) { _, newValue in
            guard model.document != nil, model.appearance != newValue else { return }
            model.updateAppearance(cover: localCover, appearance: newValue)
            environment.refresh()
        }
        .onChange(of: localCover) { _, newValue in
            guard let document = model.document, document.cover != newValue else { return }
            model.updateAppearance(cover: newValue, appearance: localAppearance)
            environment.refresh()
        }
        .onReceive(model.session.$editorContentHeight) { newHeight in
            let clampedHeight = max(60, newHeight)
            guard abs(editorContentHeight - clampedHeight) > 1 else { return }
            editorContentHeight = clampedHeight
        }
        #if os(iOS)
        .onReceive(model.session.caretUpdates) { update in
            if update == nil { documentScrollProxy.pendingCaretRevision = nil }
            else { queueCaretReveal() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            isKeyboardVisible = true
            updateKeyboardFrame(notification)
            model.session.requestCaretVisibility()
            // Re-reveal after the keyboard finishes animating, so a just-placed caret the
            // keyboard now covers is lifted into view against the settled layout.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                model.session.requestCaretVisibility()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardFrame(notification)
            queueCaretReveal()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
            keyboardFrame = .null
        }
        #endif
        .onReceive(model.session.$editorVisualContentBottom) { newBottom in
            let clampedBottom = max(0, newBottom)
            guard abs(editorVisualContentBottom - clampedBottom) > 1 else { return }
            editorVisualContentBottom = clampedBottom
        }
    }

    private var editorSelectionContent: some View {
        editorViewportContent
        .onReceive(model.session.$selectedBlockCount) { newCount in
            selectedBlockCount = newCount
            if newCount == 0 {
                selectedStylePanel = nil
            }
        }
        .onReceive(model.session.$selectionMode) { mode in
            let nextMode = EditorSelectionMode(rawValue: mode) ?? .off
            guard selectionMode != nextMode else { return }
            selectionMode = nextMode
            if nextMode == .off {
                selectedBlockCount = 0
                selectedStylePanel = nil
            }
        }
        .onReceive(model.session.$isEditing) { isEditing in
            isEditingDocument = isEditing
            if !isEditing {
                editorContentHeight = max(60, model.session.editorContentHeight)
                editorVisualContentBottom = max(
                    0,
                    model.session.editorVisualContentBottom
                )
            }
        }
        .onReceive(model.session.$slashMenuState) { state in
            slashMenuState = state
        }
        .onReceive(model.session.$pageBreakRegions) { regions in
            pageBreakRegions = regions
        }
        .onReceive(model.session.$collectionRegions) { collectionRegions = $0 }
        .onReceive(model.session.$isPresentationReady) { ready in
            presentationReady = ready
            if !ready { savedBodyHeight = 0 }
        }
        .onPreferenceChange(SavedDocumentBodyHeightPreference.self) { savedBodyHeight = $0 }
    }

    private var editorRequestContent: some View {
        editorSelectionContent
        .onReceive(model.$nestedPageActionTarget) { page in
            guard let page else { return }
            model.nestedPageActionTarget = nil
            guard !isEditorLocked, selectionMode == .off,
                  environment.selectedDocumentID == model.documentID else { return }
            dismissKeyboard()
            pageDeletionTarget = page
        }
        .onReceive(model.$blockDeletionRequest) { request in
            guard let request else { return }
            model.blockDeletionRequest = nil
            guard !isEditorLocked, selectionMode == .off, request.documentID == model.documentID,
                  environment.selectedDocumentID == model.documentID else {
                model.session.dismissBlockActions(requestToken: request.token)
                return
            }
            dismissKeyboard()
            blockDeletionRequest = request
        }
        .onReceive(model.$calloutIconRequest) { request in
            guard let request else { return }
            calloutIconTargetBlockID = request.blockID
            calloutIcon = request.icon
            selectedCalloutColor = Color(vellixHex: request.color)
            showCalloutIconPicker = true
        }
        .onReceive(model.$blockquoteColorRequest) { request in
            guard let request else { return }
            selectedBlockquoteColor = Color(vellixHex: request.color)
            blockquoteColorRequest = request
        }
        .onReceive(model.$calloutColorRequest) { request in
            guard let request, request.blockID?.isEmpty == false else { return }
            selectedCalloutColor = Color(vellixHex: request.color)
            calloutColorRequest = request
            model.calloutColorRequest = nil
        }
        .onReceive(model.$propertyEditorRequest) { request in
            guard let request else { return }
            dismissKeyboard()
            propertyEditorReturnTarget = (model.documentID, request.blockID)
            propertyEditorRequest = request
            model.propertyEditorRequest = nil
        }
    }

    private var editorContent: some View {
        editorRequestContent
        .onReceive(model.$propertyURLRequest) { request in
            guard let request, let url = InlinePropertyDefinition.safeURL(request.url) else { return }
            openURL(url)
            model.propertyURLRequest = nil
        }
        .onReceive(model.$appearance) { appearance in
            localAppearance = appearance
        }
        .onReceive(model.$nestedPageToOpen) { child in
            guard let child, environment.selectedDocumentID == model.documentID else { return }
            model.nestedPageToOpen = nil
            environment.refresh()
            environment.select(child)
        }
        .onDisappear {
            model.session.pauseAttachmentPlayback()
            model.attachmentActionRequest = nil
            dismissBlockDeletion()
            editorBanner = nil
            persistTitle()
            dismissKeyboard()
            model.flushPendingSave()
        }
    }

    private var editorPrimaryPresentations: some View {
        editorContent
        .modifier(TagEditorIntegration(model: model, session: model.session, locked: isEditorLocked))
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard fileInsertionDocumentID == model.documentID, !isEditorLocked else { return }
            switch result {
            case .success(let urls): Task { await model.importAttachments(urls: urls, token: fileInsertionToken) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $model.attachmentEditorRequest) { request in
            AttachmentEditorSheet(request: request, session: model.session, editable: !isEditorLocked)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $collectionEditorRequest) { request in
            collectionSheet(request)
        }
        .sheet(item: $model.taskEditorRequest) { request in
            TaskEditorSheet(model: model, notifications: environment.taskNotifications, request: request)
        }
        .sheet(item: $model.taskHistoryRequest) { request in
            TaskHistorySheet(request: request)
        }
        .onChange(of: model.taskHistoryRequest?.id) { _, id in if id != nil { dismissKeyboard() } }
        .sheet(item: $model.tableEditorRequest, onDismiss: { model.session.tableAction("close") }) { request in
            TableEditorSheet(model: model, request: request)
        }
    }

    private var editorAppearancePresentations: some View {
        editorPrimaryPresentations
        .sheet(isPresented: $showAppearance) {
            DocumentStyleSheet(
                documentID: model.documentID,
                definition: DocumentStyleDefinition(appearance: localAppearance, cover: localCover)
            ) { style in
                model.updateAppearance(cover: style.cover, appearance: style.appearance)
                localAppearance = style.appearance
                localCover = style.cover
                environment.refresh()
            }
        }
        .sheet(isPresented: $showIconPicker) {
            VellixIconLibraryPicker(title: "Page Icon") { icon in
                model.updateIcon(icon.name)
                environment.refresh()
                showIconPicker = false
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $blockquoteColorRequest) { request in
            NavigationStack {
                VellixBlockColorControls(
                    title: "Blockquote Color",
                    selection: $selectedBlockquoteColor,
                    onColorChange: { color in
                        model.session.updateBlockquoteColor(
                            blockID: request.blockID,
                            color: color.vellixHexString(fallback: "#ffffff")
                        )
                    }
                )
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("Blockquote Color")
                .pennedSheet(title: "Blockquote Color", close: { blockquoteColorRequest = nil })
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $calloutColorRequest) { request in
            NavigationStack {
                VellixBlockColorControls(title: "Callout Color", selection: $selectedCalloutColor,
                    onColorChange: { color in
                        if let blockID = request.blockID {
                            model.session.updateCalloutColor(blockID: blockID,
                                color: color.vellixHexString(fallback: "#ffffff"))
                        }
                    })
                    .frame(maxHeight: .infinity, alignment: .top)
                    .navigationTitle("Callout Color")
                    .pennedSheet(title: "Callout Color", close: { calloutColorRequest = nil }) {
                        if request.blockID == nil {
                            Button("Add") {
                                model.session.insertPlainCallout(color: selectedCalloutColor.vellixHexString(fallback: "#ffffff"))
                                calloutColorRequest = nil
                            }
                        }
                    }
            }.presentationDetents([.medium]).presentationDragIndicator(.visible)
        }
    }

    private var editorBlockPresentations: some View {
        editorAppearancePresentations
        .modifier(InlineTextColorPresentation(request: $textColorRequest, session: model.session))
        .sheet(item: $propertyEditorRequest, onDismiss: resumeEditingAfterProperty) { request in
            InlinePropertyEditorSheet(property: request.property,
                editingGuidance: model.document?.templateID != nil && placeholderMode, onSave: { property in
                model.session.updateInlineProperty(blockID: request.blockID, property: property)
            }, onDelete: {
                model.session.deleteInlineProperty(blockID: request.blockID)
            })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $model.templateComponentRequest) { request in
            TemplateComponentEditorSheet(request: request, session: model.session)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCalloutIconPicker) {
            VellixIconLibraryPicker(
                title: "Callout Style",
                colorSelection: $selectedCalloutColor,
                onColorChange: { color in
                    guard let calloutIconTargetBlockID else { return }
                    model.session.updateCalloutColor(
                        blockID: calloutIconTargetBlockID,
                        color: color.vellixHexString(fallback: "#ffffff")
                    )
                }
            ) { icon in
                calloutIcon = icon.name
                if let calloutIconTargetBlockID {
                    model.session.updateCalloutIcon(blockID: calloutIconTargetBlockID, icon: icon.name)
                } else {
                    model.session.insertCallout(
                        icon: icon.name,
                        text: calloutText.trimmedNonEmpty ?? "",
                        color: selectedCalloutColor.vellixHexString(fallback: "#ffffff")
                    )
                }
                calloutIconTargetBlockID = nil
                showCalloutIconPicker = false
            }
            .presentationDetents([.medium, .large])
            .onDisappear {
                calloutIconTargetBlockID = nil
            }
        }
    }

    private var editorUtilityPresentations: some View {
        editorBlockPresentations
        .sheet(isPresented: $showSnapshots) {
            SnapshotHistoryView(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSelectedActions) {
            SelectedBlockActionsSheet(
                copyAction: { model.session.copySelectedBlocks() },
                cutAction: { model.session.cutSelectedBlocks() },
                duplicateAction: { model.session.duplicateSelectedBlocks() },
                groupAction: { model.groupSelectedBlocksIntoChildPage() },
                deleteAction: { model.session.deleteSelectedBlocks() }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $model.cardEditorRequest, onDismiss: { model.cancelCardInsertion() }) { request in
            PageCardEditorSheet(request: request, store: environment.attachmentStore) { style, imageData in
                try await model.savePageCard(request: request, style: style, imageData: imageData)
                environment.refresh()
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var editorBlockActionDialogs: some View {
        editorUtilityPresentations
        .confirmationDialog("File", isPresented: Binding<Bool>(
            get: { model.attachmentActionRequest != nil },
            set: { if !$0 { model.attachmentActionRequest = nil } }
        ), titleVisibility: .visible, presenting: model.attachmentActionRequest) { request in
            Button("File Settings") {
                guard selectionMode == .off, environment.selectedDocumentID == request.documentID,
                      model.documentID == request.documentID else { return }
                model.attachmentActionRequest = nil
                model.attachmentEditorRequest = request.attachment
            }
            if !isEditorLocked {
                Button("Delete", role: .destructive) {
                    guard !isEditorLocked, selectionMode == .off,
                          environment.selectedDocumentID == request.documentID,
                          model.documentID == request.documentID else { return }
                    model.attachmentActionRequest = nil
                    Task { await model.deleteAttachment(request) }
                }
            }
            Button("Cancel", role: .cancel) { model.attachmentActionRequest = nil }
        }
        .confirmationDialog("Block", isPresented: Binding<Bool>(
            get: { blockDeletionRequest != nil },
            set: { if !$0 { blockDeletionRequest = nil } }
        ), titleVisibility: .visible, presenting: blockDeletionRequest) { request in
            Button("Delete Block", role: .destructive) {
                guard !isEditorLocked, selectionMode == .off,
                      environment.selectedDocumentID == request.documentID,
                      model.documentID == request.documentID else {
                    model.session.dismissBlockActions(requestToken: request.token)
                    return
                }
                model.session.deleteBlock(requestToken: request.token)
                blockDeletionRequest = nil
            }
            Button("Cancel", role: .cancel) {
                model.session.dismissBlockActions(requestToken: request.token)
                blockDeletionRequest = nil
            }
        } message: { _ in
            Text("You can undo this change.")
        }
    }

    private var editorPageActionDialogs: some View {
        editorBlockActionDialogs
        .confirmationDialog("Page", isPresented: Binding<Bool>(
            get: { pageDeletionTarget != nil },
            set: { if !$0 { pageDeletionTarget = nil } }
        ), titleVisibility: .visible) {
            if let page = pageDeletionTarget {
                Button(page.cardStyle == nil ? "Show as Card" : "Card Style") {
                    guard !isEditorLocked else { return }
                    pageDeletionTarget = nil
                    model.editPageCard(page)
                }
                Button("Delete Page", role: .destructive) {
                    guard !isEditorLocked else { return }
                    model.trashChildPage(id: page.id)
                    pageDeletionTarget = nil
                    environment.refresh()
                }
            }
            Button("Cancel", role: .cancel) { pageDeletionTarget = nil }
        } message: {
            Text("This page and its nested pages will move to Trash. You can restore them later.")
        }
        .alert("Convert this text to placeholder guidance?", isPresented: Binding<Bool>(
            get: { model.placeholderConversionToken != nil },
            set: { if !$0 { model.placeholderConversionToken = nil } }
        )) {
            if let token = model.placeholderConversionToken {
                Button("Convert to Guidance") {
                    model.session.placeholderAction("convert", token: token)
                    model.placeholderConversionToken = nil
                }
            }
            Button("Keep as Content", role: .cancel) {
                model.session.cancelPlaceholderConversion()
                model.placeholderConversionToken = nil
            }
        }
    }

    private var editorErrorPresentation: Binding<Bool> {
        Binding<Bool>(
            get: { model.tableEditorRequest == nil && model.taskEditorRequest == nil && (model.errorMessage != nil || model.session.bridgeErrorMessage != nil) },
            set: { isPresented in
                if !isPresented {
                    model.errorMessage = nil
                    model.session.bridgeErrorMessage = nil
                }
            }
        )
    }

    var body: some View {
        editorPageActionDialogs
        .sheet(item: $publishingDocument) { document in PublishingSheet(document: document, queue: environment.publishing) }
        .alert("Editor", isPresented: editorErrorPresentation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? model.session.bridgeErrorMessage ?? "")
        }
        .vellixHideEditorNavigationBar(isActive: environment.selectedDocumentID != nil)
    }

    private func documentWorkspace(_ document: DocumentRecord) -> some View {
        let appearance = localAppearance.resolved(for: colorScheme)

        return GeometryReader { proxy in
            documentWorkspaceLayers(document, appearance: appearance, proxy: proxy)
        }
    }

    private func documentWorkspaceLayers(_ document: DocumentRecord, appearance: DocumentAppearance, proxy: GeometryProxy) -> some View {
        let isCompact = workspace != nil || proxy.size.width < 620

        return ZStack(alignment: .topLeading) {
            DocumentBackgroundLayer(style: appearance.editorBackground, theme: appearance.themeID)
                .ignoresSafeArea()

            documentScrollView(document, appearance: appearance, size: proxy.size, isCompact: isCompact)

            documentTopControls(document, appearance: appearance, isCompact: isCompact)
                .padding(.horizontal, isCompact ? 18 : 28)
                .padding(.top, workspace != nil ? 8 : (isCompact ? 0 : 56))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            documentStatusBanner(isCompact: isCompact)
            documentBlockControls(isCompact: isCompact)

            #if os(iOS)
            documentKeyboardToolbar
            #endif

            documentSlashMenu(proxy: proxy, isCompact: isCompact)
        }
        .coordinateSpace(name: DocumentEditorCoordinateSpace.workspace)
        .onChange(of: proxy.size) { _, _ in
            #if canImport(UIKit)
            model.session.requestCaretVisibility()
            #endif
        }
    }

    private func documentScrollView(_ document: DocumentRecord, appearance: DocumentAppearance, size: CGSize, isCompact: Bool) -> some View {
        let scrollWidth: CGFloat? = workspace == nil ? nil : size.width
        let scrollHeight: CGFloat? = workspace == nil ? nil : size.height

        return ScrollView(showsIndicators: false) {
            documentScrollContent(document, appearance: appearance, size: size, isCompact: isCompact)
        }
        .frame(width: scrollWidth, height: scrollHeight)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            documentKeyboardInset
        }
        .onPreferenceChange(EditorSurfaceFramePreferenceKey.self) { frame in
            let resized = frame.size != editorSurfaceFrame.size
            editorSurfaceFrame = frame
            #if canImport(UIKit)
            if resized, documentScrollProxy.pendingCaretRevision != nil { queueCaretReveal() }
            #endif
        }
        .onChange(of: model.tableEditorRequest?.id) { _, _ in
            scrollTableIntoView(isCompact: isCompact)
        }
    }

    private func documentScrollContent(_ document: DocumentRecord, appearance: DocumentAppearance, size: CGSize, isCompact: Bool) -> some View {
        let horizontalPadding: CGFloat = appearance.themeID == nil
            ? (isCompact ? 10 : 30)
            : (isCompact ? 8 : 30)
        let topPadding: CGFloat = isCompact ? 74 : 150
        let bottomPadding: CGFloat = isCompact ? 118 : 140
        let minimumHeight: CGFloat = max(0, size.height - topPadding - bottomPadding)

        return VStack(spacing: appearance.themeID == nil ? 0 : 30) {
            if appearance.themeID == nil {
                plainDocument(document, appearance: appearance, isCompact: isCompact, minimumHeight: minimumHeight)
            } else {
                themedDocument(document, appearance: appearance, isCompact: isCompact, bottomPadding: isCompact ? 4 : 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .background(documentScrollFinder())
    }

    @ViewBuilder private var documentKeyboardInset: some View {
        #if os(iOS)
        if isEditingDocument && isKeyboardVisible && selectionMode == .off && !isEditorLocked {
            Color.clear
                .frame(height: EditorKeyboardFormattingToolbar.height + EditorKeyboardFormattingToolbar.bottomPadding + 8)
                .allowsHitTesting(false)
        }
        #endif
    }

    @ViewBuilder private func documentStatusBanner(isCompact: Bool) -> some View {
        if let editorBanner {
            HStack(spacing: 10) {
                LibraryIcon(name: editorBanner.icon, size: 20)
                Text(editorBanner.message)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center).lineLimit(2)
            }
            .foregroundStyle(VellixSurface.controlInk)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(VellixSurface.controlInk.opacity(0.14), lineWidth: 1))
            .shadow(color: VellixSurface.elevationShadow(opacity: 0.2), radius: 8, y: 4)
            .frame(maxWidth: 440).padding(.horizontal, 18)
            .padding(.top, isCompact ? 58 : 134)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false).accessibilityElement(children: .combine)
            .transition(.opacity).zIndex(100)
        }
    }

    @ViewBuilder private func documentBlockControls(isCompact: Bool) -> some View {
        if selectionMode != .off && !isEditorLocked {
            SelectionActionPill(
                session: model.session,
                copyAction: { model.session.copySelectedBlocks() },
                duplicateAction: { model.session.duplicateSelectedBlocks() },
                groupAction: { model.groupSelectedBlocksIntoChildPage() },
                deleteAction: { model.session.deleteSelectedBlocks() },
                isCompact: isCompact
            )
            .padding(.horizontal, isCompact ? 28 : 34)
            .padding(.bottom, isCompact ? 18 : 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }

        if selectionMode == .off && selectedBlockCount == 0 && !isEditingDocument && !isEditorLocked {
            EditorFloatingToolbar(
                appearanceAction: { showAppearance = true },
                selectionModeAction: { setSelectionMode($0) },
                isCompact: isCompact
            )
            .padding(.horizontal, isCompact ? 26 : 34)
            .padding(.bottom, isCompact ? 0 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    #if os(iOS)
    @ViewBuilder private var documentKeyboardToolbar: some View {
        if isEditingDocument && isKeyboardVisible && selectionMode == .off && !isEditorLocked {
            keyboardFormattingToolbar
                .padding(.horizontal, 8)
                .padding(.bottom, EditorKeyboardFormattingToolbar.bottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(90)
        }
    }
    #endif

    @ViewBuilder private func documentSlashMenu(proxy: GeometryProxy, isCompact: Bool) -> some View {
        if let slashMenuState, !isEditorLocked {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.session.dismissSlashMenu() }
                slashCommandOverlay(state: slashMenuState, proxy: proxy, isCompact: isCompact)
            }
            .zIndex(80)
        }
    }

    private func documentTopControls(_ document: DocumentRecord, appearance: DocumentAppearance, isCompact: Bool) -> some View {
        EditorTopControls(
            document: document,
            showsDocumentHeading: workspace == nil,
            isThemed: appearance.themeID != nil,
            isCompact: isCompact,
            isSelectionMode: selectionMode != .off && !isEditorLocked,
            isEditorLocked: isEditorLocked,
            placeholderMode: placeholderMode,
            canSaveTemplate: canUseTemplateControls && !model.isSavingTemplate
                && (model.templateNeedsSave || hasTitleChanges),
            isSavingTemplate: model.isSavingTemplate,
            sidebarAction: sidebarAction
        ) {
            Task {
                do {
                    try await model.captureAndSave()
                    environment.returnFromDocument(model.document ?? document)
                } catch { model.errorMessage = error.localizedDescription }
            }
        } lockAction: {
            toggleEditorLock()
        } shareAction: {
            Task {
                do {
                    try model.prepareForSpaceChange?()
                    try await model.captureAndSave()
                    guard environment.selectedDocumentID == model.documentID else { return }
                    publishingDocument = try environment.documents.requireDocument(id: model.documentID)
                }
                catch { model.errorMessage = error.localizedDescription }
            }
        } moreAction: {
            showSnapshots = true
        } selectionDoneAction: {
            setSelectionMode(.off)
        } placeholderModeAction: {
            model.session.togglePlaceholderMode()
        } placeholderAction: {
            model.session.placeholderAction($0)
        } saveTemplateAction: {
            persistTitle()
            let documentID = model.documentID
            Task {
                do {
                    guard try await model.saveTemplateEdits() else { return }
                    environment.refresh()
                    guard environment.selectedDocumentID == documentID else { return }
                    showEditorBanner(model.templateNeedsSave ? "Template saved. New changes pending." : "Template Saved", icon: "checkwavy")
                } catch {
                    model.errorMessage = error.localizedDescription
                    if environment.selectedDocumentID == documentID {
                        showEditorBanner("Template could not be saved", icon: "xmarkwavy")
                    }
                }
            }
        } saveAsTemplateAction: {
            Task {
                do { try await model.captureAndSave(); environment.saveAsTemplate(model.document ?? document) }
                catch { model.errorMessage = error.localizedDescription }
            }
        }
    }

    #if os(iOS)
    private var keyboardFormattingToolbar: some View {
        let taskAction: (() -> Void)? = model.taskContext == nil ? nil : {
            model.openTaskScheduling()
            dismissKeyboard()
        }
        let templateComponentAction: ((TemplateComponentKind) -> Void)? = model.document?.templateID == nil ? nil : { kind in
            model.templateComponentRequest = TemplateComponentRequest(definition: TemplateComponentDefinition(kind: kind))
        }

        return EditorKeyboardFormattingToolbar(
            session: model.session,
            textColorAction: { presentTextColorEditor() },
            boldAction: { model.session.formatCurrentSelection(action: "bold") },
            italicAction: { model.session.formatCurrentSelection(action: "italic") },
            underlineAction: { model.session.formatCurrentSelection(action: "underline") },
            strikeAction: { model.session.formatCurrentSelection(action: "strike") },
            codeAction: { model.session.formatCurrentSelection(action: "code") },
            alignLeftAction: { model.session.formatCurrentSelection(action: "align", value: "left") },
            alignCenterAction: { model.session.formatCurrentSelection(action: "align", value: "center") },
            alignRightAction: { model.session.formatCurrentSelection(action: "align", value: "right") },
            outdentAction: { model.session.formatCurrentSelection(action: "outdent") },
            indentAction: { model.session.formatCurrentSelection(action: "indent") },
            checklistAction: { model.session.formatCurrentSelection(action: "checkList") },
            taskAction: taskAction,
            bulletListAction: { model.session.formatCurrentSelection(action: "bulletList") },
            numberListAction: { model.session.formatCurrentSelection(action: "numberList") },
            iconAction: { showIconPicker = true },
            fileAction: { presentFileImporter() },
            insertBlockAction: { model.session.insertBlock($0) },
            insertDividerAction: { model.session.insertDivider($0) },
            pageBreakAction: { model.session.insertPageBreak() },
            calloutAction: { presentNewCalloutPicker() },
            plainCalloutAction: { presentNewPlainCalloutPicker() },
            templateComponentAction: templateComponentAction,
            dismissAction: { dismissKeyboard() }
        )
    }

    private func presentTextColorEditor() {
        guard !preparingTextColor, !isEditorLocked, selectionMode == .off,
              environment.selectedDocumentID == model.documentID else { return }
        preparingTextColor = true
        Task {
            defer { preparingTextColor = false }
            do {
                let request = try await model.session.beginTextColorEditing()
                guard request?.documentID == model.documentID, !isEditorLocked,
                      environment.selectedDocumentID == model.documentID else {
                    model.session.endTextColorEditing(restoreFocus: false)
                    return
                }
                textColorRequest = request
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
    #endif

    @ViewBuilder private func documentTitle(_ document: DocumentRecord, appearance: DocumentAppearance, isCompact: Bool) -> some View {
        if DocumentTaskPages.isDetail(document.id), let task = model.historyPageTask {
            TaskHistoryPageHeader(task: task, appearance: appearance, title: $titleText,
                saveTitle: { model.rename(title: $0) }, titleFocused: $isTitleFocused, titleSize: isCompact ? 22 : 30, locked: isEditorLocked)
        } else {
        HStack(alignment: .center, spacing: 10) {
            if let day = document.dailyNoteDate.flatMap(DailyNoteDay.init(key:)) {
                Button {
                    persistTitle()
                    Task {
                        do {
                            try await model.captureAndSave()
                            environment.calendar.select(day.date())
                            environment.selectedDocumentID = nil
                            environment.selectedDestination = .calendar
                        } catch { environment.report(error) }
                    }
                } label: {
                    HStack(spacing: 6) { LibraryIcon(name: "mooncal", size: 18); Text(day.title) }
                        .font(.system(size: isCompact ? 17 : 23, weight: .bold, design: appearance.fontStyle.design))
                        .padding(.horizontal, 8).frame(minHeight: 44)
                        .background(Color(vellixHex: appearance.textColorHex).opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).fixedSize().accessibilityLabel("Open Calendar for " + day.title)
                titleInput("Title", text: Binding(get: { day.suffix(from: titleText) }, set: { titleText = $0.isEmpty ? day.title : day.title + " " + $0 }), appearance: appearance, isCompact: isCompact)
            } else {
                titleInput("Untitled", text: $titleText, appearance: appearance, isCompact: isCompact)
            }
        }.foregroundStyle(Color(vellixHex: appearance.textColorHex))
        }
    }

    private func titleInput(_ prompt: String, text: Binding<String>, appearance: DocumentAppearance, isCompact: Bool) -> some View {
        TextField(prompt, text: text.singleLinePageTitle)
            .focused($isTitleFocused)
            .font(.system(size: isCompact ? 22 : 30, weight: .black, design: appearance.fontStyle.design))
            .foregroundStyle(Color(vellixHex: appearance.textColorHex))
            .textFieldStyle(.plain).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(!isEditorLocked)
            .onSubmit { model.rename(title: titleText); environment.refresh() }
    }

    private func plainDocument(
        _ document: DocumentRecord,
        appearance: DocumentAppearance,
        isCompact: Bool,
        minimumHeight: CGFloat
    ) -> some View {
        let isPaged = !pageBreakRegions.isEmpty

        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: isCompact ? 8 : 26) {
                documentTitle(document, appearance: appearance, isCompact: isCompact)

                Rectangle()
                    .fill(Color(vellixHex: appearance.textColorHex).opacity(0.07))
                    .frame(height: 1)

                collectionDocumentFields(appearance: appearance)

                VStack(spacing: 0) {
                    editorSurface(
                        document: document,
                        minimumHeight: isCompact ? 64 : 110
                    )

                    unplacedPages(appearance: appearance)
                    if isPaged {
                        editorEndFocusZone(height: isCompact ? 28 : 36)
                    }
                }
            }
            .padding(.horizontal, isPaged ? (isCompact ? 22 : 28) : 0)
            .padding(.top, isPaged ? (isCompact ? 16 : 28) : 0)
        }
        .frame(minHeight: minimumHeight, alignment: .topLeading)
        .backgroundPreferenceValue(PageSheetEditorBoundsPreferenceKey.self) { editorBounds in
            pageSheetBackgrounds(
                appearance: appearance,
                isCompact: isCompact,
                editorBounds: editorBounds,
                isVisible: isPaged
            )
        }
        .frame(maxWidth: workspace == nil ? 900 : 720, alignment: .leading)
    }

    private func themedDocument(
        _ document: DocumentRecord,
        appearance: DocumentAppearance,
        isCompact: Bool,
        bottomPadding: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    if appearance.displaysCover {
                        coverView(document: document, appearance: appearance, isCompact: isCompact)
                            .padding(.bottom, 28)
                    }

                    HStack(alignment: .bottom) {
                        documentTitle(document, appearance: appearance, isCompact: isCompact)

                        Button {
                            showIconPicker = true
                        } label: {
                            IconTile(systemName: document.icon, size: isCompact ? 38 : 42, tint: Color(vellixHex: appearance.themeID?.accentHex ?? "#8FE9FF"))
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(spacing: 4) {
                        Rectangle()
                            .fill(Color(vellixHex: appearance.textColorHex).opacity(0.08))
                            .frame(height: 1)

                        collectionDocumentFields(appearance: appearance)

                        VStack(spacing: 0) {
                            editorSurface(
                                document: document,
                                minimumHeight: isCompact ? 68 : 118
                            )

                            unplacedPages(appearance: appearance)
                            editorEndFocusZone(height: isCompact ? 28 : 36)
                        }
                    }
                }
                .padding(.horizontal, isCompact ? 16 : 28)
                .padding(.top, isCompact ? 16 : 28)
            }
            .padding(.bottom, bottomPadding)
            .backgroundPreferenceValue(PageSheetEditorBoundsPreferenceKey.self) { editorBounds in
                pageSheetBackgrounds(
                    appearance: appearance,
                    isCompact: isCompact,
                    editorBounds: editorBounds,
                    isVisible: true
                )
            }

        }
        .frame(maxWidth: workspace != nil ? 720 : (isCompact ? .infinity : 900))
    }

    @ViewBuilder
    private func unplacedPages(appearance: DocumentAppearance) -> some View {
        // Older snapshots and grouped pages may not yet contain a reference block.
        let unplaced = model.children.filter { !model.pageReferenceIDs.contains($0.id) && !collectionEntryIDs.contains($0.id) }
        if !unplaced.isEmpty {
            VStack(spacing: 0) {
                ForEach(unplaced) { child in
                    Group {
                        if let style = child.cardStyle {
                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    dismissKeyboard()
                                    environment.select(child)
                                } label: {
                                    PageCardView(document: child, style: style,
                                        photo: CardImageLoader.image(path: style.imagePath, store: environment.attachmentStore), fillsDocumentWidth: true,
                                        attachmentStore: environment.attachmentStore)
                                        .shadow(color: VellixSurface.elevationShadow(opacity: 0.3), radius: 10, x: 0, y: 7)
                                }.buttonStyle(.plain)
                                if style.backdrop == .photo, let photo = style.remotePhoto { CardPhotoCredit(photo: photo) }
                            }
                        } else {
                            NestedPageRow(document: child, appearance: appearance) {
                                dismissKeyboard()
                                environment.select(child)
                            }
                        }
                    }
                    .contextMenu {
                        Button(child.cardStyle == nil ? "Show as Card" : "Card Style") {
                            guard !isEditorLocked else { return }
                            model.editPageCard(child)
                        }
                        DocumentContextMenu(document: child, trashAction: {
                            guard !isEditorLocked else { return }
                            pageDeletionTarget = child
                        })
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private var hasUnplacedPages: Bool {
        model.children.contains { !model.pageReferenceIDs.contains($0.id) && !collectionEntryIDs.contains($0.id) }
    }

    @ViewBuilder
    private func collectionDocumentFields(appearance: DocumentAppearance) -> some View {
        if environment.collections.entryContext(model.documentID) != nil {
            CollectionDocumentFields(store: environment.collections, documentID: model.documentID, appearance: appearance,
                onBeginEditing: { dismissKeyboard() })
            .allowsHitTesting(!isEditorLocked && selectionMode == .off)
        }
    }

    private func updateCollectionPresentation() {
        guard environment.selectedDocumentID == model.documentID else { return }
        let store = environment.collections
        collectionEntryIDs = store.embeddedEntryIDs(model.documentID)
        model.session.setCollections(store.payloads(for: model.documentID))
        if let error = store.errorMessage { model.errorMessage = error }
    }

    private func handleCollectionRequest(_ request: CollectionEditorRequest) {
        guard environment.selectedDocumentID == model.documentID, !isEditorLocked, selectionMode == .off else { return }
        dismissKeyboard()
        if request.action == "create" { collectionEditorRequest = request; return }
        do {
            guard try environment.collections.repository.collectionIDs(forDocument: model.documentID).contains(request.collectionID) else {
                throw VellixError.impossibleMove("This collection does not belong to this page.")
            }
            let snapshot = try environment.collections.load(request.collectionID)
            switch request.action {
            case "openCollection": collectionEditorRequest = CollectionEditorRequest(action: "configure", blockID: request.blockID, collectionID: request.collectionID)
            case "openEntry":
                guard snapshot.entries.contains(where: { $0.id == request.documentID }) else { return }
                openCollectionPage(request.documentID)
            default: collectionEditorRequest = request
            }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func openCollectionPage(_ id: String) {
        guard id != model.documentID else { return }
        let ownerID = model.documentID
        Task { @MainActor in
            do {
                try await model.captureAndSave()
                guard environment.selectedDocumentID == ownerID else { return }
                let document = try environment.documents.requireDocument(id: id)
                guard !document.isTrashed else { throw VellixError.impossibleMove("Restore this page from Trash before opening it.") }
                environment.editorCache.prepare(document).refreshLibraryContext()
                environment.select(document)
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func collectionSheet(_ request: CollectionEditorRequest) -> some View {
        let store = environment.collections
        if request.action == "create" {
            CollectionCreateSheet(model: model, blockID: request.blockID)
        } else if let snapshot = store.snapshots[request.collectionID] {
            switch request.action {
            case "field":
                CollectionFieldEditorSheet(store: store, field: snapshot.field(request.fieldID)
                    ?? CollectionField(collectionID: snapshot.record.id, name: "", kind: .text))
            case "value":
                if let field = snapshot.field(request.fieldID), let entry = snapshot.entries.first(where: { $0.id == request.documentID }) {
                    CollectionValueSheet(store: store, collectionID: snapshot.record.id, documentID: entry.id,
                        field: field, value: entry.values[field.id] ?? CollectionValue())
                }
            case "addEntry":
                CollectionAddEntrySheet(store: store, collectionID: snapshot.record.id, onOpen: openCollectionPage)
            case "entry":
                if let entry = snapshot.entries.first(where: { $0.id == request.documentID }) {
                    CollectionEntryActionsSheet(store: store, collectionID: snapshot.record.id, entry: entry, onOpen: openCollectionPage)
                }
            default:
                CollectionManagementSheet(store: store, snapshot: snapshot, closesOnSelection: request.action == "menu")
            }
        }
    }

    private func pageSheetBackgrounds(
        appearance: DocumentAppearance,
        isCompact: Bool,
        editorBounds: Anchor<CGRect>?,
        isVisible: Bool,
        minimumHeight: CGFloat = 0
    ) -> some View {
        GeometryReader { proxy in
            if isVisible {
                let cornerRadius: CGFloat = isCompact ? 22 : 30
                let editorFrame = editorBounds.map { proxy[$0] } ?? .zero
                let segments = pageSheetSegments(
                    totalHeight: proxy.size.height,
                    editorFrame: editorFrame,
                    visualContentBottom: editorVisualContentBottom,
                    minimumHeight: minimumHeight
                )
                ZStack(alignment: .topLeading) {
                    ForEach(segments) { segment in
                        pageSheetBackground(appearance: appearance)
                            .frame(width: proxy.size.width, height: segment.height)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .stroke(Color(vellixHex: appearance.textColorHex).opacity(0.10), lineWidth: 1)
                            }
                            .shadow(color: VellixSurface.elevationShadow(opacity: 0.42), radius: 34, x: 0, y: 18)
                            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                            .onTapGesture { model.session.focusDocumentEnd() }
                            .offset(y: segment.y)
                    }
                }
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.session.focusDocumentEnd() }
            }
        }
        .allowsHitTesting(!isEditorLocked && selectionMode == .off)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func pageSheetBackground(appearance: DocumentAppearance) -> some View {
        if appearance.themeID == nil {
            ZStack {
                DocumentBackgroundLayer(style: appearance.editorBackground, theme: nil)
                if appearance.presentationColorScheme == .dark { Color.black.opacity(0.30) }
            }
        } else {
            DocumentBackgroundLayer(style: appearance.innerPageBackground, theme: nil)
        }
    }

    private func pageSheetSegments(
        totalHeight: CGFloat,
        editorFrame: CGRect,
        visualContentBottom: CGFloat,
        minimumHeight: CGFloat
    ) -> [DocumentPageSheetSegment] {
        let fallback = [DocumentPageSheetSegment(index: 0, y: 0, height: totalHeight)]
        guard totalHeight > 0, editorFrame.height > 0 else {
            return fallback
        }

        let editorBottomInset = max(0, totalHeight - editorFrame.maxY)
        let measuredVisualBottom = visualContentBottom > 0
            ? min(visualContentBottom, editorFrame.height)
            : editorFrame.height
        let finalBottom = min(
            totalHeight,
            max(minimumHeight, editorFrame.minY + measuredVisualBottom + editorBottomInset)
        )
        let measuredFallback = [
            DocumentPageSheetSegment(index: 0, y: 0, height: finalBottom)
        ]

        let breaks = pageBreakRegions
            .filter { $0.height > 0 && $0.y >= 0 }
            .sorted { $0.y < $1.y }
        guard !breaks.isEmpty else {
            return measuredFallback
        }

        let editorTop = editorFrame.minY
        var startY: CGFloat = 0
        var segments: [DocumentPageSheetSegment] = []

        for pageBreak in breaks {
            let endY = min(totalHeight, editorTop + pageBreak.y)
            if endY > startY {
                segments.append(
                    DocumentPageSheetSegment(
                        index: segments.count,
                        y: startY,
                        height: endY - startY
                    )
                )
            }
            startY = min(totalHeight, editorTop + pageBreak.y + pageBreak.height)
        }

        if finalBottom > startY {
            segments.append(
                DocumentPageSheetSegment(
                    index: segments.count,
                    y: startY,
                    height: finalBottom - startY
                )
            )
        }

        return segments.isEmpty ? measuredFallback : segments
    }

    @ViewBuilder
    private func documentScrollFinder() -> some View {
        #if canImport(UIKit)
        DocumentScrollViewFinder(proxy: documentScrollProxy)
        #else
        Color.clear
        #endif
    }

    private func scrollTableIntoView(isCompact: Bool) {
        #if canImport(UIKit)
        guard let request = model.tableEditorRequest, case .edit = request.mode,
              let surfaceTop = model.tableContext?.surfaceTop else { return }
        // The web content is a fixed-height, non-scrolling WKWebView, so the table's DOM
        // offset maps 1:1 onto the editor surface. Lift the table to just under the top
        // controls so it stays visible above the editing sheet.
        let targetViewportY: CGFloat = isCompact ? 96 : 150
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let scrollView = documentScrollProxy.scrollView else { return }
            let tableViewportY = editorSurfaceFrame.minY + CGFloat(surfaceTop)
            let delta = tableViewportY - targetViewportY
            guard abs(delta) > 1 else { return }
            let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            let target = min(max(0, scrollView.contentOffset.y + delta), maxOffset)
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: true)
        }
        #endif
    }

    #if canImport(UIKit)
    private func updateKeyboardFrame(_ notification: Notification) {
        if let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            keyboardFrame = value.cgRectValue
        }
    }

    private func queueCaretReveal() {
        // Only reveal once the keyboard is up. Scrolling/laying out during the focus-
        // acquiring tap cancels the WebView becoming first responder (tap-twice-to-type).
        guard let update = model.session.caretUpdate, model.session.isEditing, isKeyboardVisible,
              !isEditorLocked, selectionMode == .off,
              environment.selectedDocumentID == model.documentID else { documentScrollProxy.pendingCaretRevision = nil; return }
        documentScrollProxy.pendingCaretRevision = update.revision
        guard !documentScrollProxy.caretRevealQueued else { return }
        documentScrollProxy.caretRevealQueued = true
        DispatchQueue.main.async {
            documentScrollProxy.caretRevealQueued = false
            revealCaretIfNeeded()
        }
    }

    private func revealCaretIfNeeded() {
        guard let update = model.session.caretUpdate, documentScrollProxy.pendingCaretRevision == update.revision,
              model.session.isEditing, !model.session.isLoadingDocument, !isEditorLocked, selectionMode == .off,
              model.session.renderedDocumentID == model.documentID,
              environment.selectedDocumentID == model.documentID,
              let scrollView = documentScrollProxy.scrollView, let window = scrollView.window,
              model.webViewStore.webView.isDescendant(of: scrollView) else { return }
        guard !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else {
            documentScrollProxy.pendingCaretRevision = nil
            return
        }
        scrollView.superview?.layoutIfNeeded()
        let webView = model.webViewStore.webView
        let caret = webView.convert(update.rect, to: window)
        let visible = scrollView.convert(scrollView.bounds, to: window)
        let insets = scrollView.adjustedContentInset
        let top = visible.minY + max(insets.top, visible.width < 620 ? 74 : 150) + 8
        var bottom = visible.maxY - insets.bottom - 18
        if isKeyboardVisible, !keyboardFrame.isNull {
            let keyboard = window.convert(keyboardFrame, from: nil)
            let toolbar = EditorKeyboardFormattingToolbar.height + EditorKeyboardFormattingToolbar.bottomPadding + 8
            bottom = min(bottom, keyboard.minY - toolbar - 18)
        }
        let viewport = CGRect(x: visible.minX, y: top, width: visible.width, height: max(0, bottom - top))
        let minimum = -insets.top
        let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
        guard let target = TipTapCaretVisibility.targetOffset(caret: caret, viewport: viewport,
            current: scrollView.contentOffset.y, minimum: minimum, maximum: maximum) else {
            documentScrollProxy.pendingCaretRevision = nil
            return
        }
        if abs(target - scrollView.contentOffset.y) > 1 {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
            let movedCaret = webView.convert(update.rect, to: window)
            if TipTapCaretVisibility.targetOffset(caret: movedCaret, viewport: viewport,
                current: target, minimum: minimum, maximum: maximum) == nil { documentScrollProxy.pendingCaretRevision = nil }
        }
    }
    #endif

    private func editorSurface(
        document: DocumentRecord,
        minimumHeight: CGFloat
    ) -> some View {
        // Reserve empty-space editing room after fallback page rows, not between content and those rows.
        let liveHeight = hasUnplacedPages ? editorVisualContentBottom : max(editorContentHeight, minimumHeight)
        let contentHeight = presentationReady ? liveHeight : max(liveHeight, savedBodyHeight)

        return ZStack(alignment: .topLeading) {
            TipTapWebView(
                session: model.session,
                store: model.webViewStore,
                documentID: document.id,
                canonicalJSON: document.tipTapJSON
            )
            .allowsHitTesting(!isEditorLocked && presentationReady)
            .accessibilityLabel(isEditorLocked ? "Locked editor" : "Editor")
            .frame(height: contentHeight, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(collectionRegions) { region in
                        if let snapshot = environment.collections.snapshots[region.collectionID]
                            ?? environment.documentPreviews.content(for: document).collections.first(where: { $0.record.id == region.collectionID }),
                           snapshot.activeView?.kind == .kanban {
                            CollectionKanbanView(store: environment.collections, collectionID: region.collectionID,
                                blockID: region.id, editable: !isEditorLocked && selectionMode == .off,
                                appearance: localAppearance.resolved(for: colorScheme),
                                savedSnapshot: snapshot,
                                onRequest: handleCollectionRequest,
                                onHeightChange: { height in
                                    guard let viewID = snapshot.activeView?.id else { return }
                                    model.session.nativeCollectionDidLayout(blockID: region.id, viewID: viewID, height: height,
                                        needsResize: abs(region.rect.height - height) > 1)
                                })
                                .frame(width: region.rect.width, height: region.rect.height)
                                .offset(x: region.rect.minX, y: region.rect.minY)
                                .allowsHitTesting(presentationReady && selectionMode == .off && environment.selectedDocumentID == model.documentID)
                                .id(region.id + (snapshot.activeView?.id ?? ""))
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .opacity(presentationReady ? 1 : 0)
            .accessibilityHidden(!presentationReady)
            if !presentationReady {
                ImmediateDocumentBodyPreview(document: document)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in Color.clear.preference(key: SavedDocumentBodyHeightPreference.self, value: proxy.size.height) }
                    }
            }
        }
        .frame(height: contentHeight, alignment: .topLeading)
        .anchorPreference(
            key: PageSheetEditorBoundsPreferenceKey.self,
            value: .bounds
        ) { $0 }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: EditorSurfaceFramePreferenceKey.self,
                        value: proxy.frame(in: .named(DocumentEditorCoordinateSpace.workspace))
                    )
            }
        }
    }

    private func editorEndFocusZone(height: CGFloat) -> some View {
        Color.clear
            .frame(height: height)
            .contentShape(Rectangle())
            .allowsHitTesting(!isEditorLocked && selectionMode == .off)
            .onTapGesture {
                model.session.focusDocumentEnd()
            }
    }

    private func slashCommandOverlay(
        state: TipTapSlashMenuState,
        proxy: GeometryProxy,
        isCompact: Bool
    ) -> some View {
        let menuWidth = min(state.width, proxy.size.width - 28)
        let x = min(
            proxy.size.width - menuWidth - 14,
            max(14, editorSurfaceFrame.minX + state.anchorX)
        )
        let y = max(10, editorSurfaceFrame.minY + state.anchorY)

        return TipTapSlashCommandMenu(
            state: state,
            isCompact: isCompact,
            chooseAction: { key in
                model.session.chooseSlashMenuItem(key)
            }
        )
        .frame(width: menuWidth, alignment: .topLeading)
        .offset(x: x, y: y)
    }

    private func coverView(document: DocumentRecord, appearance: DocumentAppearance, isCompact: Bool) -> some View {
        ZStack {
            if let localCover {
                StoredAttachmentImage(relativePath: localCover, contentMode: .fill)
            } else {
                ThemeCoverArt(theme: appearance.resolvedCoverTheme)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.78, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 8 : 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 8 : 10, style: .continuous)
                .stroke(VellixSurface.controlInk.opacity(0.08), lineWidth: 1)
        }
    }

    private func setSelectionMode(_ mode: EditorSelectionMode) {
        selectedStylePanel = nil
        if mode == .off {
            model.session.clearBlockSelection()
        } else {
            model.session.setSelectionMode(mode.rawValue)
        }
    }

    private func deactivateEditor() {
        model.session.pauseAttachmentPlayback()
        persistTitle()
        dismissKeyboard()
        editorContentHeight = max(60, model.session.editorContentHeight)
        editorVisualContentBottom = max(
            0,
            model.session.editorVisualContentBottom
        )
        selectedBlockCount = 0
        isEditingDocument = false
        isEditorLocked = false
        showSelectedActions = false
        selectionMode = .off
        selectedStylePanel = nil
        slashMenuState = nil
        model.session.clearBlockSelection()
        model.session.setEditable(true)
        model.flushPendingSave()
        environment.refresh()
    }

    private func toggleEditorLock() {
        let nextValue = !isEditorLocked
        isEditorLocked = nextValue
        showSelectedActions = false
        selectedStylePanel = nil
        selectedBlockCount = 0
        selectionMode = .off
        if nextValue {
            dismissKeyboard()
        }
        model.session.clearBlockSelection()
        model.session.setEditable(!nextValue)
    }

    private func dismissKeyboard() {
        #if os(iOS)
        isKeyboardVisible = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #elseif os(macOS)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }

    private func resumeEditingAfterProperty() {
        let target = propertyEditorReturnTarget
        propertyEditorReturnTarget = nil
        guard let target, target.documentID == model.documentID, !isEditorLocked, selectionMode == .off,
              environment.selectedDocumentID == model.documentID,
              model.session.renderedDocumentID == model.documentID else { return }
        model.session.focusAfterInlineProperty(blockID: target.blockID)
    }

    private func dismissBlockDeletion() {
        if let request = blockDeletionRequest {
            model.session.dismissBlockActions(requestToken: request.token)
        }
        blockDeletionRequest = nil
    }

    private func presentFileImporter() {
        guard !isEditorLocked else { return }
        let id = model.documentID
        Task {
            do {
                let token = try await model.session.attachmentCommand("attachmentCaptureInsertion") as? String
                guard id == model.documentID else { return }
                fileInsertionDocumentID = id; fileInsertionToken = token
                showFileImporter = true
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func presentNewCalloutPicker() {
        calloutIconTargetBlockID = nil
        calloutIcon = "sparkle"
        selectedCalloutColor = .white
        showCalloutIconPicker = true
    }

    private func presentNewPlainCalloutPicker() {
        selectedCalloutColor = .white
        calloutColorRequest = CalloutColorRequest(blockID: nil, color: "#ffffff")
    }

    private func persistTitle() {
        guard let document = model.document else { return }
        let savedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = savedTitle.isEmpty ? "Untitled" : savedTitle
        guard normalized != document.title else { return }
        model.rename(title: titleText)
    }

    private var hasTitleChanges: Bool {
        guard let document = model.document else { return false }
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? "Untitled" : title) != document.title
    }

    private func showEditorBanner(_ message: String, icon: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            editorBanner = EditorStatusBanner(message: message, icon: icon)
        }
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }

    private func syncLocalState() {
        guard let document = model.document else {
            titleText = ""
            localAppearance = .plain
            localCover = nil
            return
        }

        titleText = document.title
        localAppearance = model.appearance
        localCover = document.cover
    }

}

private enum SelectionStylePanel {
    case page
    case formatting
    case heading
}

private enum EditorSelectionMode: String {
    case off
    case single
    case multi
}

private struct DocumentPageSheetSegment: Identifiable {
    var index: Int
    var y: CGFloat
    var height: CGFloat

    var id: Int { index }
}

private extension View {
    @ViewBuilder
    func vellixHideEditorNavigationBar(isActive: Bool) -> some View {
        #if os(iOS)
        if isActive { self.toolbar(.hidden, for: .navigationBar) }
        else { self }
        #else
        self
        #endif
    }
}

private struct EditorStatusBanner: Identifiable {
    let id = UUID()
    let message: String
    let icon: String
}

private struct EditorTopControls: View {
    var document: DocumentRecord
    var showsDocumentHeading: Bool
    var isThemed: Bool
    var isCompact: Bool
    var isSelectionMode: Bool
    var isEditorLocked: Bool
    var placeholderMode: Bool
    var canSaveTemplate: Bool
    var isSavingTemplate: Bool
    var sidebarAction: (() -> Void)?
    var backAction: () -> Void
    var lockAction: () -> Void
    var shareAction: () -> Void
    var moreAction: () -> Void
    var selectionDoneAction: () -> Void
    var placeholderModeAction: () -> Void
    var placeholderAction: (String) -> Void
    var saveTemplateAction: () -> Void
    var saveAsTemplateAction: () -> Void

    var body: some View {
        let controlSize: CGFloat = isCompact ? 46 : 68

        HStack {
            if let sidebarAction {
                Button(action: sidebarAction) {
                    editorAssetIcon("sidebar", padding: isCompact ? 12 : 18)
                        .frame(width: controlSize, height: controlSize)
                        .background(.thinMaterial, in: Circle())
                        .overlay {
                            Circle().stroke(VellixSurface.controlInk.opacity(0.14), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show Sidebar").help("Show Sidebar")
                .accessibilityIdentifier("ipad-editor-sidebar-toggle")
            }
            Button(action: backAction) {
                editorAssetIcon("backwavy", padding: isCompact ? 12 : 18)
                    .frame(width: controlSize, height: controlSize)
                    .background(.thinMaterial, in: Circle())
                    .overlay {
                        Circle().stroke(VellixSurface.controlInk.opacity(0.14), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)

            if showsDocumentHeading && isThemed && !isCompact {
              VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.system(size: isCompact ? 16 : 22, weight: .black, design: document.appearance.fontStyle.design))
                    .foregroundStyle(VellixSurface.controlInk.opacity(0.82))
                    .lineLimit(1)
                Text("Library")
                    .font(.system(size: isCompact ? 12 : 17, weight: .medium, design: .rounded))
                    .foregroundStyle(VellixSurface.secondaryControlInk(opacity: 0.32))
                    .lineLimit(1)
            }
            .padding(.leading, isCompact ? 8 : 18)
              .opacity(0.72)
            }

            Spacer()

            if isSelectionMode { templateControls }
            if isSelectionMode {
                Button(action: selectionDoneAction) {
                    editorAssetIcon("checkwavy", padding: isCompact ? 11 : 17)
                        .foregroundStyle(Color(red: 0.78, green: 0.97, blue: 1.0))
                        .frame(width: controlSize, height: controlSize)
                        .background(Color(red: 0.0, green: 0.58, blue: 1.0), in: Circle())
                        .overlay {
                            Circle().stroke(VellixSurface.controlInk.opacity(0.16), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: isCompact ? 12 : 18) {
                    templateControls
                    Button(action: lockAction) {
                        editorAssetIcon(isEditorLocked ? "eyeslash" : "eye", padding: isCompact ? 2 : 4)
                    }
                    .accessibilityLabel(isEditorLocked ? "Unlock editor" : "Lock editor")

                    Button(action: shareAction) {
                        editorAssetIcon("sendbutton", padding: isCompact ? 2 : 4)
                    }
                    Menu {
                        Button("Version History", action: moreAction)
                        if document.templateID == nil {
                            Button("Save as Template", action: saveAsTemplateAction)
                        }
                    } label: {
                        editorAssetIcon("dotswavy", padding: isCompact ? 2 : 4)
                    }
                    .pennedIconMenuStyle()
                }
                .foregroundStyle(VellixSurface.controlInk)
                .frame(height: controlSize)
                .padding(.horizontal, isCompact ? 18 : 28)
                .background(.thinMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(VellixSurface.controlInk.opacity(0.16), lineWidth: 1)
                }
            }
        }
        .foregroundStyle(VellixSurface.controlInk)
    }

    @ViewBuilder private var templateControls: some View {
        if document.templateID != nil {
            Button(action: placeholderModeAction) {
                editorAssetIcon("linedpages", padding: isCompact ? 2 : 4)
                    .foregroundStyle(placeholderMode ? VellixSurface.controlInk : Color.gray)
            }
            .disabled(isEditorLocked)
            .accessibilityLabel("Placeholder Mode")
            .accessibilityValue(placeholderMode ? "On" : "Off")
            .help("Placeholder Mode")
            .contextMenu {
                Button("Convert Text to Guidance") { placeholderAction("convert") }
                Button("Convert Guidance to Content") { placeholderAction("ordinary") }
                Button("Clear Guidance") { placeholderAction("clear") }
            }
            Button(action: saveTemplateAction) {
                editorAssetIcon("checkwavy", padding: isCompact ? 2 : 4)
                    .foregroundStyle(canSaveTemplate ? VellixSurface.controlInk : Color.gray)
            }
            .disabled(!canSaveTemplate)
            .accessibilityValue(isSavingTemplate ? "Saving" : canSaveTemplate ? "Unsaved changes" : "Saved")
            .accessibilityLabel("Save Template").help("Save Template")
        }
    }

    private func editorAssetIcon(_ name: String, padding: CGFloat) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: isCompact ? 22 : 28, height: isCompact ? 22 : 28)
            .padding(padding)
    }
}

private struct TipTapSlashCommandMenu: View {
    var state: TipTapSlashMenuState
    var isCompact: Bool
    var chooseAction: (String) -> Void

    private var visibleRowCount: Int {
        min(max(state.items.count, 1), 5)
    }

    private var menuMaxHeight: CGFloat {
        14 + CGFloat(visibleRowCount) * 62
    }

    var body: some View {
        ScrollView(showsIndicators: state.items.count > visibleRowCount) {
            LazyVStack(spacing: 0) {
                ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        chooseAction(item.key)
                    } label: {
                        HStack(spacing: 11) {
                            Image(item.icon)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(VellixSurface.controlInk)
                                .padding(7)
                                .frame(width: 34, height: 34)
                                .background(VellixSurface.controlInk.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(VellixSurface.controlInk)
                                    .lineLimit(1)

                                Text(item.detail)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(VellixSurface.secondaryControlInk(opacity: 0.55))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            VellixSurface.controlInk.opacity(index == state.selectedIndex ? 0.12 : 0),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
        }
        .frame(maxHeight: menuMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(VellixSurface.toolbar.opacity(0.96), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(VellixSurface.controlInk.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: VellixSurface.elevationShadow(opacity: 0.44), radius: 24, x: 0, y: 12)
    }
}

private struct SelectionActionPill: View {
    @ObservedObject var session: TipTapEditorSession
    var copyAction: () -> Void
    var duplicateAction: () -> Void
    var groupAction: () -> Void
    var deleteAction: () -> Void
    var isCompact: Bool

    var body: some View {
        HStack(spacing: isCompact ? 6 : 8) {
            EditorTextConversionMenu(session: session, blockSelection: true, isCompact: isCompact)
            pillButton("Copy", assetName: "copy", action: copyAction)
            pillButton("Duplicate", assetName: "threeboxes", action: duplicateAction)
            pillButton("Group", assetName: "groupfill", action: groupAction)
            pillButton("Delete", assetName: "trash", tint: VellixSurface.destructiveAccessory, action: deleteAction)
        }
        .padding(.horizontal, isCompact ? 10 : 12)
        .padding(.vertical, isCompact ? 8 : 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(VellixSurface.controlInk.opacity(0.16), lineWidth: 1) }
        .shadow(color: VellixSurface.elevationShadow(opacity: 0.42), radius: 26, x: 0, y: 12)
    }

    private func pillButton(
        _ title: String,
        assetName: String,
        tint: Color = VellixSurface.controlInk,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .padding(isCompact ? 7 : 9)
                .foregroundStyle(tint)
                .frame(width: isCompact ? 42 : 50, height: isCompact ? 36 : 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct SelectedBlocksToolbar: View {
    var styleAction: () -> Void
    var actionsAction: () -> Void
    var copyAction: () -> Void
    var cutAction: () -> Void
    var duplicateAction: () -> Void
    var deleteAction: () -> Void
    var groupAction: () -> Void
    var isCompact: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isCompact ? 2 : 4) {
                SelectedToolbarItem(title: "Style", assetName: nil, textIcon: "Aa", tint: VellixSurface.formattingAccent, action: styleAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Group", assetName: "groupfill", textIcon: nil, tint: VellixSurface.groupingAccent, action: groupAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Actions", assetName: "sendbutton", textIcon: nil, tint: VellixSurface.controlInk.opacity(0.92), action: actionsAction, isCompact: isCompact)
                SelectedToolbarItem(title: "React", assetName: "xsmile", textIcon: nil, tint: VellixSurface.reactionAccent, action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "Comment", assetName: "lovechatbubbles", textIcon: nil, tint: VellixSurface.commentAccent, action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "Assistant", assetName: "sparklesstarflag", textIcon: nil, tint: VellixSurface.assistantAccent, action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "Writing To...", assetName: "linespencil", textIcon: nil, tint: VellixSurface.writingAccent, action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "Edit", assetName: "plainpencil", textIcon: nil, tint: VellixSurface.editingAccent, action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "Copy", assetName: "copy", textIcon: nil, tint: VellixSurface.controlInk.opacity(0.88), action: copyAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Cut", assetName: "prohibitedwavy", textIcon: nil, tint: VellixSurface.controlInk.opacity(0.88), action: cutAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Duplicate", assetName: "threeboxes", textIcon: nil, tint: VellixSurface.controlInk.opacity(0.88), action: duplicateAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Share", assetName: "sendbutton", textIcon: nil, tint: VellixSurface.controlInk.opacity(0.88), action: actionsAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Move", assetName: "rightwavy", textIcon: nil, tint: VellixSurface.controlInk.opacity(0.78), action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "More", assetName: "dotswavy", textIcon: nil, tint: VellixSurface.controlInk.opacity(0.78), action: actionsAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Delete", assetName: "trash", textIcon: nil, tint: VellixSurface.destructiveAccessory, action: deleteAction, isCompact: isCompact, isDestructive: true)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, isCompact ? 8 : 10)
            .padding(.vertical, isCompact ? 6 : 8)
        }
        .frame(maxWidth: isCompact ? .infinity : 720)
        .frame(height: isCompact ? 88 : 102)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: isCompact ? 24 : 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 24 : 28, style: .continuous)
                .stroke(VellixSurface.controlInk.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: VellixSurface.elevationShadow(opacity: 0.42), radius: 30, x: 0, y: 14)
    }
}

private struct SelectedToolbarItem: View {
    var title: String
    var assetName: String?
    var textIcon: String?
    var tint: Color
    var action: () -> Void
    var isCompact: Bool
    var isDestructive = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                if let textIcon {
                    Text(textIcon)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                } else if let assetName {
                    Image(assetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: isCompact ? 24 : 28, height: isCompact ? 24 : 28)
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(VellixSurface.controlInk.opacity(0.42))
            }
            .foregroundStyle(tint)
            .frame(width: isCompact ? 74 : 88, height: isCompact ? 70 : 80)
            .background(VellixSurface.controlInk.opacity(isDestructive ? 0.055 : 0.001))
            .clipShape(RoundedRectangle(cornerRadius: isCompact ? 17 : 21, style: .continuous))
            .overlay {
                if isDestructive {
                    RoundedRectangle(cornerRadius: isCompact ? 17 : 21, style: .continuous)
                        .stroke(VellixSurface.controlInk.opacity(0.10), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SelectedBlockStylePanel: View {
    var panel: SelectionStylePanel
    var isCompact: Bool
    @Binding var calloutColor: Color
    var headingAction: () -> Void
    var bodyAction: () -> Void
    var pageAction: () -> Void
    var checklistAction: () -> Void
    var toggleAction: () -> Void
    var bulletsAction: () -> Void
    var numbersAction: () -> Void
    var outdentAction: () -> Void
    var indentAction: () -> Void
    var quoteAction: () -> Void
    var calloutAction: () -> Void
    var showPagePanel: () -> Void
    var showFormattingPanel: () -> Void
    var showHeadingPanel: () -> Void
    var dismissAction: () -> Void

    var body: some View {
        VStack(spacing: isCompact ? 14 : 18) {
            Capsule()
                .fill(VellixSurface.controlInk.opacity(0.18))
                .frame(width: 38, height: 5)

            switch panel {
            case .page:
                pagePanel
            case .formatting:
                formattingPanel
            case .heading:
                headingPanel
            }
        }
        .padding(.horizontal, isCompact ? 14 : 18)
        .padding(.top, 8)
        .padding(.bottom, isCompact ? 14 : 18)
        .frame(maxWidth: isCompact ? .infinity : 720)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: isCompact ? 24 : 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 24 : 28, style: .continuous)
                .stroke(Color(red: 0.21, green: 0.72, blue: 1.0).opacity(0.38), lineWidth: 1)
        }
        .shadow(color: VellixSurface.elevationShadow(opacity: 0.46), radius: 32, x: 0, y: 16)
        .gesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    guard value.translation.height > 34 else { return }
                    advancePanel()
                }
        )
    }

    private var pagePanel: some View {
        VStack(spacing: isCompact ? 14 : 18) {
            HStack(spacing: 0) {
                panelTab("Heading", selected: false, action: headingAction)
                divider()
                panelTab("Body", selected: false, action: bodyAction)
                divider()
                panelTab("Page", selected: true, assetName: "linedpages", action: pageAction)
                panelTab("More...", selected: false, action: showHeadingPanel)
            }

            HStack(spacing: isCompact ? 8 : 12) {
                styleSquare("checklist", action: checklistAction)
                styleSquare("chevright", action: toggleAction)
                styleSquare("bulletlist", action: bulletsAction)
                styleSquare("numberlist", action: numbersAction)
                styleSquare("chevleft", action: outdentAction)
                styleSquare("chevright", action: indentAction)
            }

            HStack(spacing: isCompact ? 10 : 14) {
                styleWide("Quote", assetName: "quote", action: quoteAction)
                styleWide("Callout", assetName: "sparkle", selected: false, action: calloutAction)
                calloutColorPicker
                styleSquare("dotswavy", selected: true, action: showFormattingPanel)
                    .frame(width: isCompact ? 58 : 70)
            }
        }
    }

    private var formattingPanel: some View {
        VStack(spacing: isCompact ? 14 : 18) {
            HStack(spacing: isCompact ? 8 : 12) {
                styleSquare("boldtext", selected: true)
                styleSquare("italics")
                styleSquare("underline")
                styleSquare("strikethrough")
                styleSquare("codewindow")
                styleSquare("leftalign")
                styleSquare("centeralign")
                styleSquare("rightalign")
            }

            HStack(spacing: isCompact ? 8 : 10) {
                fontTile("Aa", title: "System", selected: true)
                fontTile("Ss", title: "Serif")
                fontTile("00", title: "Mono")
                fontTile("Rr", title: "Round")
            }

            HStack(spacing: isCompact ? 10 : 12) {
                styleWide("Copy Format", assetName: "copy")
                styleWide("Paste Format", assetName: "linedpages", disabled: true)
            }
        }
    }

    private var headingPanel: some View {
        VStack(spacing: isCompact ? 14 : 18) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                headingOption("Title", weight: .bold)
                headingOption("Subtitle", weight: .semibold)
                headingOption("Heading", weight: .semibold, opacity: 0.72)
                headingOption("Strong", weight: .bold)
                headingOption("Body", weight: .regular)
                headingOption("Caption", weight: .regular, opacity: 0.52)
            }

            Rectangle()
                .fill(VellixSurface.controlInk.opacity(0.08))
                .frame(height: 1)

            HStack(spacing: isCompact ? 12 : 16) {
                headingMode("Page", assetName: "linedpages", selected: true)
                headingMode("Card", assetName: "threeboxes")
                Spacer(minLength: 0)
            }
        }
    }

    private var calloutColorPicker: some View {
        ColorPicker(selection: $calloutColor, supportsOpacity: false) {
            HStack(spacing: 7) {
                Image("paintbrush")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text("Color")
                    .font(.system(size: isCompact ? 15 : 17, weight: .semibold))
            }
            .foregroundStyle(VellixSurface.controlInk.opacity(0.88))
        }
        .frame(width: isCompact ? 112 : 128, height: 56)
    }

    private func advancePanel() {
        switch panel {
        case .page:
            showFormattingPanel()
        case .formatting:
            showHeadingPanel()
        case .heading:
            dismissAction()
        }
    }

    private func panelTab(_ title: String, selected: Bool, assetName: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let assetName {
                    Image(assetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: isCompact ? 18 : 22, height: isCompact ? 18 : 22)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .font(.system(size: isCompact ? 18 : 22, weight: selected ? .bold : .semibold, design: .rounded))
            .foregroundStyle(selected ? VellixSurface.controlInk : VellixSurface.controlInk.opacity(0.76))
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 46 : 54)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(VellixSurface.controlInk.opacity(0.06))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color(red: 0.18, green: 0.78, blue: 1.0), lineWidth: 1.5)
                        }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(VellixSurface.controlInk.opacity(0.12))
            .frame(width: 1, height: 34)
    }

    private func styleSquare(
        _ imageName: String,
        selected: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            styleSquareIcon(imageName, disabled: disabled)
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 54 : 62)
            .background(VellixSurface.controlInk.opacity(selected ? 0.07 : 0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(red: 0.18, green: 0.78, blue: 1.0), lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func styleSquareIcon(_ imageName: String, disabled: Bool) -> some View {
        Image(imageName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 23, height: 23)
            .foregroundStyle(disabled ? VellixSurface.controlInk.opacity(0.24) : VellixSurface.controlInk.opacity(0.88))
    }

    private func styleWide(
        _ title: String,
        assetName: String?,
        selected: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let assetName {
                    Image(assetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                Text(title)
                    .font(.system(size: isCompact ? 17 : 20, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(disabled ? VellixSurface.controlInk.opacity(0.28) : VellixSurface.controlInk.opacity(0.86))
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 56 : 64)
            .background(VellixSurface.controlInk.opacity(selected ? 0.09 : 0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func fontTile(_ sample: String, title: String, selected: Bool = false) -> some View {
        VStack(spacing: 5) {
            Text(sample)
                .font(.system(size: isCompact ? 25 : 30, weight: .bold, design: title == "Serif" ? .serif : title == "Mono" ? .monospaced : title == "Round" ? .rounded : .default))
            Text(title)
                .font(.system(size: isCompact ? 11 : 13, weight: .medium, design: .rounded))
                .foregroundStyle(VellixSurface.secondaryControlInk(opacity: 0.45))
        }
        .foregroundStyle(VellixSurface.controlInk.opacity(selected ? 0.92 : 0.72))
        .frame(maxWidth: .infinity)
        .frame(height: isCompact ? 76 : 88)
        .background(VellixSurface.controlInk.opacity(selected ? 0.075 : 0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func headingOption(_ title: String, weight: Font.Weight, opacity: Double = 0.92) -> some View {
        Text(title)
            .font(.system(size: isCompact ? 20 : 24, weight: weight, design: .rounded))
            .foregroundStyle(VellixSurface.controlInk.opacity(opacity))
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 50 : 60)
    }

    private func headingMode(_ title: String, assetName: String, selected: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 23, height: 23)
            Text(title)
                .font(.system(size: isCompact ? 19 : 23, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(VellixSurface.controlInk.opacity(0.88))
        .frame(width: isCompact ? 136 : 176, height: isCompact ? 58 : 66)
        .background(VellixSurface.controlInk.opacity(selected ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(red: 0.18, green: 0.78, blue: 1.0), lineWidth: 1.5)
            }
        }
    }
}

private struct SelectedBlockActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var copyAction: () -> Void
    var cutAction: () -> Void
    var duplicateAction: () -> Void
    var groupAction: () -> Void
    var deleteAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 0) {
                    actionRow("Copy", assetName: "copy", action: copyAction)
                    actionRow("Cut", assetName: "prohibitedwavy", action: cutAction)
                    actionRow("Duplicate", assetName: "threeboxes", action: duplicateAction)
                    actionRow("Group into Sub Page", assetName: "groupfill", action: groupAction)
                    sheetDivider()
                    actionRow("Share & Export", assetName: "sendbutton", showsChevron: true, action: copyAction)
                    sheetDivider()
                    actionRow("Move to Daily Note", assetName: "calheart", showsChevron: true, action: {})
                    actionRow("Move to...", assetName: "rightwavy", showsChevron: true, action: {})
                    sheetDivider()
                    actionRow("More", assetName: "dotswavy", showsChevron: true, action: {})
                    actionRow("Delete", assetName: "trash", destructive: true, action: deleteAction)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .pennedSheet(title: "Actions", close: { dismiss() })
    }

    private func actionRow(
        _ title: String,
        assetName: String,
        showsChevron: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 18) {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34)
                Text(title)
                    .font(.system(size: 25, weight: .regular, design: .rounded))
                Spacer()
                if showsChevron {
                    Image("chevright")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(VellixSurface.secondaryControlInk(opacity: 0.55))
                }
            }
            .foregroundStyle(destructive ? VellixSurface.destructiveLabel : VellixSurface.controlInk.opacity(0.88))
            .frame(height: 58)
        }
        .buttonStyle(.plain)
    }

    private func sheetDivider() -> some View {
        Rectangle()
            .fill(VellixSurface.controlInk.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 7)
    }
}

private struct EditorFloatingToolbar: View {
    var appearanceAction: () -> Void
    var selectionModeAction: (EditorSelectionMode) -> Void
    var isCompact: Bool

    var body: some View {
        HStack {
            HStack(spacing: isCompact ? 16 : 26) {
                assetToolbarButton("paintbrush", action: appearanceAction)
                Menu {
                    Button("Single Select") {
                        selectionModeAction(.single)
                    }
                    Button("Multi Select") {
                        selectionModeAction(.multi)
                    }
                    Button("Stop Selecting") {
                        selectionModeAction(.off)
                    }
                } label: {
                    assetToolbarImage("selectsparkle")
                }
                .pennedIconMenuStyle()
            }
            .padding(.horizontal, isCompact ? 18 : 30)
            .frame(height: isCompact ? 54 : 74)
            .background(.thinMaterial, in: Capsule())
            .overlay { Capsule().stroke(VellixSurface.controlInk.opacity(0.13), lineWidth: 1) }

            Spacer()
        }
        .shadow(color: VellixSurface.elevationShadow(opacity: 0.42), radius: 26, x: 0, y: 12)
    }

    private func assetToolbarButton(_ assetName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            assetToolbarImage(assetName)
        }
        .buttonStyle(.plain)
    }

    private func assetToolbarImage(_ name: String) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(VellixSurface.controlInk)
            .padding(isCompact ? 3 : 4)
            .frame(width: isCompact ? 26 : 36, height: isCompact ? 38 : 44)
    }
}

#if os(iOS)
private struct EditorKeyboardFormattingToolbar: View {
    static let height: CGFloat = 50
    static let bottomPadding: CGFloat = 6

    @ObservedObject var session: TipTapEditorSession
    var textColorAction: () -> Void
    var boldAction: () -> Void
    var italicAction: () -> Void
    var underlineAction: () -> Void
    var strikeAction: () -> Void
    var codeAction: () -> Void
    var alignLeftAction: () -> Void
    var alignCenterAction: () -> Void
    var alignRightAction: () -> Void
    var outdentAction: () -> Void
    var indentAction: () -> Void
    var checklistAction: () -> Void
    var taskAction: (() -> Void)?
    var bulletListAction: () -> Void
    var numberListAction: () -> Void
    var iconAction: () -> Void
    var fileAction: () -> Void
    var insertBlockAction: (String) -> Void
    var insertDividerAction: (VellixDividerStyle) -> Void
    var pageBreakAction: () -> Void
    var calloutAction: () -> Void
    var plainCalloutAction: () -> Void
    var templateComponentAction: ((TemplateComponentKind) -> Void)?
    var dismissAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if session.formattingState.hasTextSelection {
                toolbarButton("Text Color", assetName: "paintbrush", selected: session.formattingState.textColor != nil, action: textColorAction)
                    .help("Text Color")
                divider
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    toolbarButton("Bold", assetName: "boldtext", selected: session.formattingState.bold, action: boldAction)
                    toolbarButton("Italic", assetName: "italics", selected: session.formattingState.italic, action: italicAction)
                    toolbarButton("Underline", assetName: "underline", selected: session.formattingState.underline, action: underlineAction)
                    toolbarButton("Strikethrough", assetName: "strikethrough", selected: session.formattingState.strike, action: strikeAction)
                    toolbarButton("Inline Code", assetName: "codewindow", selected: session.formattingState.code, action: codeAction)
                    divider
                    toolbarButton("Align Left", assetName: "leftalign", selected: session.formattingState.alignment == "left", action: alignLeftAction)
                    toolbarButton("Align Center", assetName: "centeralign", selected: session.formattingState.alignment == "center", action: alignCenterAction)
                    toolbarButton("Align Right", assetName: "rightalign", selected: session.formattingState.alignment == "right", action: alignRightAction)
                    divider
                    toolbarButton("Outdent", assetName: "chevleft", action: outdentAction)
                    toolbarButton("Indent", assetName: "chevright", action: indentAction)
                    divider
                    toolbarButton("Checklist", assetName: "checklist", selected: session.formattingState.checklist, action: checklistAction)
                    toolbarButton("Bullet List", assetName: "bulletlist", selected: session.formattingState.bulletList, action: bulletListAction)
                    toolbarButton("Numbered List", assetName: "numberlist", selected: session.formattingState.numberList, action: numberListAction)
                }
                .padding(.leading, 6)
                .padding(.trailing, 2)
            }

            divider
            if let taskAction {
                toolbarButton("Checklist Task Scheduling", assetName: "clockfill", action: taskAction)
                divider
            }
            EditorInsertMenu(
                iconAction: iconAction,
                fileAction: fileAction,
                insertBlockAction: insertBlockAction,
                insertDividerAction: insertDividerAction,
                pageBreakAction: pageBreakAction,
                calloutAction: calloutAction,
                plainCalloutAction: plainCalloutAction,
                templateComponentAction: templateComponentAction
            )
            divider
            toolbarButton("Dismiss Keyboard", assetName: "chevdown", action: dismissAction)
                .padding(.trailing, 4)
        }
        .frame(height: Self.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VellixSurface.controlInk.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: VellixSurface.elevationShadow(opacity: 0.28), radius: 12, x: 0, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text formatting")
    }

    private var divider: some View {
        Rectangle()
            .fill(VellixSurface.controlInk.opacity(0.14))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 4)
    }

    private func toolbarButton(
        _ label: String,
        assetName: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(selected ? VellixSurface.violet : VellixSurface.controlInk)
                .frame(width: 20, height: 20)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct EditorInsertMenu: View {
    var iconAction: () -> Void
    var fileAction: () -> Void
    var insertBlockAction: (String) -> Void
    var insertDividerAction: (VellixDividerStyle) -> Void
    var pageBreakAction: () -> Void
    var calloutAction: () -> Void
    var plainCalloutAction: () -> Void
    var templateComponentAction: ((TemplateComponentKind) -> Void)?

    var body: some View {
        Menu {
            Button("File") { fileAction() }
            if let templateComponentAction {
                Menu("Template Components") {
                    ForEach(TemplateComponentKind.allCases) { kind in
                        Button(kind.title) { templateComponentAction(kind) }
                    }
                }
            }
            Button("H1") { insertBlockAction("heading1") }
            Button("H2") { insertBlockAction("heading2") }
            Button("H3") { insertBlockAction("heading3") }
            Button("H4") { insertBlockAction("heading4") }
            Button("H5") { insertBlockAction("heading5") }
            Button("Paragraph") { insertBlockAction("paragraph") }
            Button("Caption") { insertBlockAction("caption") }
            Button("Page") { insertBlockAction("nestedPage") }
            Button("Card") { insertBlockAction("pageCard") }
            Button("Table") { insertBlockAction("table") }
            Button("Collection") { insertBlockAction("collection") }
            Menu("Toggle") {
                Button("Body") { insertBlockAction("toggleListItem") }
                Button("H1") { insertBlockAction("toggleHeading1") }
                Button("H2") { insertBlockAction("toggleHeading2") }
                Button("H3") { insertBlockAction("toggleHeading3") }
                Button("H4") { insertBlockAction("toggleHeading4") }
                Button("H5") { insertBlockAction("toggleHeading5") }
            }
            Menu("Callout") {
                Button("With Icon") { calloutAction() }
                Button("Without Icon") { plainCalloutAction() }
            }
            Button("Blockquote") { insertBlockAction("quote") }
            Button("Checklist") { insertBlockAction("checkListItem") }
            Button("Bullet List") { insertBlockAction("bulletListItem") }
            Button("Numbered List") { insertBlockAction("numberedListItem") }
            Menu("Properties") {
                ForEach(InlinePropertyKind.allCases) { kind in
                    Button(kind.title) { insertBlockAction("property:\(kind.rawValue)") }
                }
            }
            Button("Page Break") { pageBreakAction() }
            Menu("Divider") {
                ForEach(VellixDividerStyle.allCases) { style in
                    Button(style.title) {
                        insertDividerAction(style)
                    }
                }
            }
            Button("Page Icon") { iconAction() }
        } label: {
            Image("addwavy")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(VellixSurface.controlInk)
                .frame(width: 22, height: 22)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .pennedIconMenuStyle()
        .accessibilityLabel("Add block")
    }
}
#endif

struct VellixIconLibraryPicker: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    var colorSelection: Binding<Color>?
    var onColorChange: ((Color) -> Void)?
    var onSelect: (VellixAssetIcon) -> Void
    @State private var query = ""
    @State private var selectedCategoryID: String = VellixAssetIconLibrary.categories.first?.id ?? ""
    @State private var isCategoryMenuOpen = false
    @State private var isSystemLibrary = false

    init(
        title: String,
        selectedIcon: String? = nil,
        colorSelection: Binding<Color>? = nil,
        onColorChange: ((Color) -> Void)? = nil,
        onSelect: @escaping (VellixAssetIcon) -> Void
    ) {
        self.title = title
        let usesSymbols = selectedIcon?.hasPrefix("sf:") == true
        _isSystemLibrary = State(initialValue: usesSymbols)
        _selectedCategoryID = State(initialValue: usesSymbols ? VellixSymbolCatalog.categories.first?.id ?? "" : VellixAssetIconLibrary.categories.first?.id ?? "")
        self.colorSelection = colorSelection
        self.onColorChange = onColorChange
        self.onSelect = onSelect
    }

    // Show at most 4 category rows at once; the rest scroll inside the menu.
    private let categoryRowHeight: CGFloat = 46
    private let maxVisibleCategories = 4

    private var categories: [VellixAssetIconCategory] { isSystemLibrary ? VellixSymbolCatalog.categories : VellixAssetIconLibrary.categories }

    private var selectedCategory: VellixAssetIconCategory {
        categories.first { $0.id == selectedCategoryID } ?? categories.first ?? VellixAssetIconCategory(name: "All", icons: [])
    }

    // Only the selected category is loaded into the grid at a time.
    private var icons: [VellixAssetIcon] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return selectedCategory.icons }
        if isSystemLibrary { return VellixSymbolCatalog.search(trimmed) }
        return selectedCategory.icons.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PennedSheetSearchField(text: $query, prompt: isSystemLibrary ? "Search all SF Symbols" : "Search \(selectedCategory.name)")
                    .padding(.horizontal).padding(.bottom, 12)
                if let colorSelection {
                    VellixBlockColorControls(
                        title: "Callout Color",
                        selection: colorSelection,
                        onColorChange: onColorChange
                    )
                    Divider()
                        .padding(.horizontal)
                }

                HStack {
                    Picker("Icon Library", selection: $isSystemLibrary) {
                        Text("Penned Icons").tag(false)
                        Text("SF Symbols").tag(true)
                    }.pickerStyle(.menu).tint(VellixSurface.violet)
                    Spacer()
                    if isSystemLibrary { Text("\(VellixSymbolCatalog.symbols.count) symbols").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal).frame(minHeight: 44).pennedSheetField().padding(.horizontal).padding(.top, 10)

                categoryDropdown
                    .padding(.horizontal)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    .zIndex(1)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 14)], spacing: 16) {
                        ForEach(icons) { icon in
                            let symbol = icon.systemName.flatMap { VellixSymbolCatalog.byName[$0] }
                            let available = symbol?.isAvailable ?? true
                            Button {
                                onSelect(icon)
                            } label: {
                                VStack(spacing: 8) {
                                    LibraryIcon(name: available ? icon.name : "sf:questionmark.square.dashed", size: 34)
                                        .foregroundStyle(VellixSurface.controlInk)
                                    Text(icon.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let symbol, !available {
                                        Text("OS \(symbol.requiredVersion)+").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .opacity(available ? 1 : 0.45)
                                .pennedSheetField()
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(VellixSurface.controlInk.opacity(0.08), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!available)
                            .accessibilityLabel(icon.displayName)
                            .accessibilityHint(available ? "Select icon" : "Requires OS \(symbol?.requiredVersion ?? "") or later")
                            .help(icon.displayName)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
            .onChange(of: isSystemLibrary) { _, _ in
                selectedCategoryID = categories.first?.id ?? ""; query = ""; isCategoryMenuOpen = false
            }
            .navigationTitle(title)
            .pennedSheet(title: title, close: { dismiss() })
        }
    }

    private var categoryDropdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isCategoryMenuOpen.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text(selectedCategory.name)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(VellixSurface.ink)
                    Spacer(minLength: 8)
                    Text("\(selectedCategory.icons.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VellixSurface.secondaryInk)
                    Image(isCategoryMenuOpen ? "chevup" : "chevdown")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(VellixSurface.secondaryInk)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .pennedSheetField(cornerRadius: VellixRadius.md)
                .overlay {
                    RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous)
                        .stroke(VellixSurface.hairline, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)

            if isCategoryMenuOpen {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(categories) { category in
                            categoryRow(category)
                            if category.id != categories.last?.id {
                                PennedSheetFieldDivider()
                            }
                        }
                    }
                }
                .frame(maxHeight: categoryRowHeight * CGFloat(maxVisibleCategories))
                .pennedSheetField(cornerRadius: VellixRadius.md)
                .overlay {
                    RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous)
                        .stroke(VellixSurface.hairline, lineWidth: 1)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func categoryRow(_ category: VellixAssetIconCategory) -> some View {
        let isSelected = category.id == selectedCategory.id
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedCategoryID = category.id
                isCategoryMenuOpen = false
            }
            query = ""
        } label: {
            HStack(spacing: 10) {
                Text(category.name)
                    .font(.system(.subheadline, design: .rounded).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? VellixSurface.accent : VellixSurface.ink)
                Spacer(minLength: 8)
                Text("\(category.icons.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(VellixSurface.secondaryInk)
            }
            .padding(.horizontal, 14)
            .frame(height: categoryRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? VellixSurface.controlInk.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VellixBlockColorControls: View {
    enum Layout {
        case stacked, inline, optionEditor
    }

    var title: String
    @Binding var selection: Color
    var onColorChange: ((Color) -> Void)?
    var layout: Layout = .stacked

    private let palette = [
        "#FFFFFF", "#2EC5F4", "#5B8CFF", "#A970FF",
        "#FF5CAA", "#FF9F43", "#FFD84D", "#52D273"
    ]

    private var editableSelection: Binding<Color> {
        Binding(
            get: { selection },
            set: { color in
                selection = color
                onColorChange?(color)
            }
        )
    }

    @ViewBuilder
    var body: some View {
        if layout == .inline {
            HStack(spacing: 8) {
                swatches
                    .frame(minWidth: 0, maxWidth: .infinity)
                customPicker
                    .labelsHidden()
                    .frame(width: 44, height: 44)
            }
        } else if layout == .optionEditor {
            VStack(spacing: 12) {
                swatches
                HStack {
                    Text("Custom Color").font(.body.weight(.medium))
                    Spacer()
                    customPicker.labelsHidden().frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 54)
                .pennedSheetField(cornerRadius: 16)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                swatches
                customPicker.padding(.horizontal, 16).pennedSheetField(cornerRadius: 16)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    private var swatches: some View {
        let selectedHex = selection.vellixHexString(fallback: "#FFFFFF")
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: layout == .optionEditor ? 0 : 4) {
                ForEach(palette, id: \.self) { hex in
                    Button {
                        editableSelection.wrappedValue = Color(vellixHex: hex)
                    } label: {
                        Circle()
                            .fill(Color(vellixHex: hex))
                            .frame(width: layout == .optionEditor ? 36 : 28, height: layout == .optionEditor ? 36 : 28)
                            .overlay {
                                Circle()
                                    .stroke(
                                        VellixSurface.controlInk.opacity(selectedHex.caseInsensitiveCompare(hex) == .orderedSame ? 1 : 0.22),
                                        lineWidth: selectedHex.caseInsensitiveCompare(hex) == .orderedSame ? 3 : 1
                                    )
                            }
                            .overlay {
                                if layout == .optionEditor, selectedHex.caseInsensitiveCompare(hex) == .orderedSame {
                                    Image("checkwavy")
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 14, height: 14)
                                        .foregroundStyle(hex == "#FFFFFF" ? Color.black : Color.white)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(hex)")
                }
            }
        }
        .frame(height: 44)
    }

    private var customPicker: some View {
        ColorPicker("Custom Color", selection: editableSelection, supportsOpacity: false)
            .font(.body.weight(.medium))
            .frame(minHeight: 44)
            .accessibilityLabel("Custom \(title.lowercased())")
    }
}

private struct DocumentBackgroundLayer: View {
    @EnvironmentObject private var environment: AppEnvironment
    var style: DocumentBackgroundStyle
    var theme: DocumentThemeID?

    var body: some View {
        DocumentStyleSurface(style: style, store: environment.attachmentStore, theme: theme)
    }
}

struct ThemePatternOverlay: View {
    var theme: DocumentThemeID

    var body: some View {
        GeometryReader { proxy in
            let columns = max(4, Int(proxy.size.width / 118))
            let rows = max(8, Int(proxy.size.height / 86))
            let asset = theme == .lunarClouds ? "rainbowclouds" : "codewindow"

            ZStack {
                ForEach(0..<rows, id: \.self) { row in
                    ForEach(0..<columns, id: \.self) { column in
                        Image(asset)
                            .resizable()
                            .scaledToFit()
                            .opacity(theme == .lunarClouds ? 0.28 : 0.20)
                            .frame(width: theme == .lunarClouds ? 104 : 92)
                            .position(
                                x: CGFloat(column) * 118 + (row.isMultiple(of: 2) ? 32 : 86),
                                y: CGFloat(row) * 86 + 44
                            )
                    }
                }
            }
            .blur(radius: 1.2)
        }
        .allowsHitTesting(false)
    }
}

struct ThemeCoverArt: View {
    var theme: DocumentThemeID

    var body: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: coverGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(coverAsset)
                .resizable()
                .scaledToFit()
                .padding(coverPadding)
                .shadow(color: Color(vellixHex: theme.accentHex).opacity(0.55), radius: 26)
        }
    }

    private var coverGradient: [Color] {
        switch theme {
        case .custom:
            return [Color(vellixHex: "#121416"), Color(vellixHex: "#2A2B31")]
        case .lunarClouds:
            return [Color(vellixHex: "#09213A"), Color(vellixHex: "#6928A8")]
        case .neonCode:
            return [Color.black, Color(vellixHex: "#061B1B"), Color(vellixHex: "#160B28")]
        }
    }

    private var coverAsset: String {
        switch theme {
        case .custom, .lunarClouds:
            return "moonzs"
        case .neonCode:
            return "codewindow"
        }
    }

    private var coverPadding: CGFloat {
        switch theme {
        case .custom:
            return 72
        case .lunarClouds:
            return 70
        case .neonCode:
            return 56
        }
    }
}

private struct StoredAttachmentImage: View {
    @EnvironmentObject private var environment: AppEnvironment
    var relativePath: String
    var contentMode: ContentMode
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                platformImage(image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let cached = CardImageLoader.image(path: relativePath, store: environment.attachmentStore) {
                Image(decorative: cached, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.black
            }
        }
        .clipped()
        .task(id: relativePath) {
            let url = environment.attachmentStore.fileURL(relativePath: relativePath)
            guard let data = try? Data(contentsOf: url) else {
                image = nil
                return
            }
            image = PlatformImage(data: data)
        }
    }

    @ViewBuilder
    private func platformImage(_ image: PlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #elseif canImport(AppKit)
        Image(nsImage: image)
        #endif
    }
}

#if canImport(UIKit)
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
private typealias PlatformImage = NSImage
#endif

private struct SnapshotHistoryView: View {
    @ObservedObject var model: DocumentEditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.snapshots.isEmpty {
                    Text("No snapshots yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshots) { snapshot in
                        Button {
                            model.restore(snapshot)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snapshot.reason.capitalized)
                                    .font(.headline)
                                Text(snapshot.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Revision \(snapshot.revision)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Snapshots")
            .pennedSheet(title: "Snapshots", close: { dismiss() })
        }
    }
}

struct DocumentInspectorView: View {
    @EnvironmentObject private var environment: AppEnvironment
    var document: DocumentRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VellixSpacing.md) {
                if let document {
                    InspectorCard(title: "Page") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112))], spacing: VellixSpacing.sm) {
                            MetadataTile(title: "Created", value: document.createdAt.formatted(date: .abbreviated, time: .omitted))
                            MetadataTile(title: "Updated", value: document.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            MetadataTile(title: "Revision", value: "\(document.revision)")
                            MetadataTile(title: "Words", value: "\(document.wordCount)")
                            MetadataTile(title: "Characters", value: "\(document.characterCount)")
                            MetadataTile(title: "Location", value: document.folderID == nil ? "Library" : "Folder")
                        }
                    }
                    InspectorCard(title: "Recovery") {
                        let count = (try? environment.snapshots.history(documentID: document.id).count) ?? 0
                        MetadataTile(title: "Snapshots", value: "\(count)")
                    }
                } else {
                    Text("No page selected.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(VellixSpacing.md)
        }
        .frame(minWidth: 284)
        .background(VellixSurface.sidebar)
    }
}

extension Color {
    func vellixHexString(fallback: String) -> String {
        #if canImport(UIKit)
        let color = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return fallback
        }
        #elseif canImport(AppKit)
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return fallback
        }
        let red = color.redComponent
        let green = color.greenComponent
        let blue = color.blueComponent
        #endif

        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}
