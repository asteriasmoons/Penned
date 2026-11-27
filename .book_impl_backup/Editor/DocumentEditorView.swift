//
//  DocumentEditorView.swift
//  Vellix
//

import Combine
import EventKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private enum DocumentEditorCoordinateSpace {
    static let workspace = "DocumentEditorWorkspace"
}

#if os(iOS)
private struct MobileCollectionSelectionHighlight: View {
    @ObservedObject var session: TipTapEditorSession
    let blockID: String

    var body: some View {
        if session.selectionMode != "off", session.selectedCollectionBlockIDs.contains(blockID) {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.black, lineWidth: 3)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white, lineWidth: 2)
                        .padding(1)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
#endif

#if canImport(UIKit)
/// Holds a weak reference to the document's backing UIScrollView so the editor can
/// drive it programmatically (e.g. lifting a table above the editing sheet).
final class DocumentScrollProxy {
    weak var scrollView: UIScrollView?
    var pendingCaretRevision: Int?
    var caretRevealQueued = false
    private var topBoundaryObservation: NSKeyValueObservation?
    #if os(iOS)
    private var blockDragGesture: MobileBlockDragGesture?

    func updateSelectionScrolling(webView: WKWebView, session: TipTapEditorSession, editorIsActive: Bool) {
        guard let scrollView else { return }
        if blockDragGesture?.view !== scrollView || blockDragGesture?.webView !== webView {
            if let old = blockDragGesture { old.isEnabled = false; old.view?.removeGestureRecognizer(old) }
            blockDragGesture = MobileBlockDragGesture(webView: webView, session: session, scrollView: scrollView)
            session.blockDragGesture = blockDragGesture
        }
        blockDragGesture?.editorIsActive = editorIsActive
    }
    #endif

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
    let session: TipTapEditorSession
    let webView: WKWebView
    let editorIsActive: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        DispatchQueue.main.async { locate(from: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        #if os(iOS)
        proxy.updateSelectionScrolling(webView: webView, session: session, editorIsActive: editorIsActive)
        #endif
        if proxy.scrollView == nil {
            DispatchQueue.main.async { locate(from: uiView) }
        }
    }

    private func locate(from view: UIView) {
        var candidate: UIView? = view.superview
        while let current = candidate {
            if let scrollView = current as? UIScrollView {
                proxy.attach(to: scrollView)
                #if os(iOS)
                proxy.updateSelectionScrolling(webView: webView, session: session, editorIsActive: editorIsActive)
                #endif
                session.renderRecovery.attachScrollView(scrollView)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PennedEditorPreferences.scrollToTopButtonKey) private var showsScrollToTopButton = false
    @ObservedObject private var model: DocumentEditorModel
    #if !canImport(UIKit)
    @State private var documentScrollPosition = ScrollPosition(edge: .top)
    #endif
    private let sidebarAction: (() -> Void)?
    @State private var titleText = ""
    @FocusState private var isTitleFocused: Bool
    @State private var showSnapshots = false
    @State private var showAppearance = false
    @State private var showFileImporter = false
    @State private var fileInsertionToken: String?
    @State private var fileInsertionDocumentID: String?
    @State private var textColorRequest: InlineTextColorEditorRequest?
    @State private var preparingTextColor = false
    @State private var linkRequest: DocumentLinkRequest?
    @State private var preparingLink = false
    @State private var linkLayoutRequest: SelectedDocumentLink?
    @State private var queuedLinkEdit: SelectedDocumentLink?
    @State private var selectionFormattingTarget: String?
    @State private var blockquoteColorRequest: BlockquoteColorRequest?
    @State private var propertyEditorRequest: InlinePropertyEditorRequest?
    @State private var collectionEditorRequest: CollectionEditorRequest?
    @State private var collectionEntryIDs = Set<String>()
    @State private var propertyEditorReturnTarget: (documentID: String, blockID: String)?
    @State private var selectedBlockquoteColor = Color.white
    @State private var localAppearance = DocumentAppearance.plain
    @State private var localCover: String?
    @State private var editorContentHeight: CGFloat = 320
    @State private var editorVisualContentBottom: CGFloat = 320
    @State private var selectedBlockCount = 0
    @State private var isEditingDocument = false
    @State private var isKeyboardVisible = false
    @State private var isEditorLocked = false
    @State private var showSelectedActions = false
    @State private var reportedSelectionMode: EditorSelectionMode = .off
    @State private var selectedStylePanel: SelectionStylePanel?
    @State private var editorSurfaceFrame: CGRect = .zero
    #if canImport(UIKit)
    @State private var documentScrollProxy = DocumentScrollProxy()
    @State private var keyboardFrame = CGRect.null
    #endif
    #if os(iOS)
    @State private var blockSelectionScrollDriver = MobileBlockSelectionScrollDriver()
    @State private var copyHapticRevision = 0
    #endif
    @State private var slashMenuState: TipTapSlashMenuState?
    @State private var pageBreakRegions: [TipTapPageBreakRegion] = []
    @State private var collectionRegions: [TipTapCollectionRegion] = []
    @State private var presentationReady = false
    @State private var savedBodyHeight: CGFloat = 0
    @State private var pageDeletionTarget: DocumentRecord?
    @State private var blockDeletionRequest: BlockDeletionRequest?
    @State private var placeholderMode = false
    @State private var templateMode = false
    @State private var canUseTemplateControls = false
    @State private var editorBanner: EditorStatusBanner?

    private var selectionMode: EditorSelectionMode { selectedBlockCount > 0 ? reportedSelectionMode : .off }

    private var ownsEditorPresentation: Bool { environment.ownsEditorPresentation(documentID: model.documentID) }

    private func editorPresentation<Item>(_ item: Binding<Item?>) -> Binding<Item?> {
        Binding(get: { ownsEditorPresentation ? item.wrappedValue : nil },
                set: { if $0 == nil || ownsEditorPresentation { item.wrappedValue = $0 } })
    }

    private func editorPresentation(_ presented: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { ownsEditorPresentation && presented.wrappedValue },
                set: { if !$0 || ownsEditorPresentation { presented.wrappedValue = $0 } })
    }

    init(model: DocumentEditorModel, sidebarAction: (() -> Void)? = nil) {
        self.model = model
        self.sidebarAction = sidebarAction
        _editorContentHeight = State(initialValue: model.session.editorContentHeight)
        _editorVisualContentBottom = State(initialValue: model.session.editorVisualContentBottom)
        _pageBreakRegions = State(initialValue: model.session.pageBreakRegions)
        _collectionRegions = State(initialValue: model.session.collectionRegions)
        _presentationReady = State(initialValue: model.session.isPresentationReady)
        _placeholderMode = State(initialValue: model.session.placeholderMode)
        _templateMode = State(initialValue: model.session.templateEditing)
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
            #if DEBUG && os(iOS)
            model.session.openingTrace?.event("editor-view-appeared",
                "selected=\(environment.selectedDocumentID == model.documentID) viewReady=\(presentationReady) \(model.session.openingReadinessState(for: model.documentID))")
            PennedKeyboardTrace.start()
            if environment.selectedDocumentID == model.documentID {
                PennedKeyboardTrace.setActiveSession(model.session)
            }
            PennedKeyboardTrace.record("ui.editor.appear", session: model.session,
                "viewDoc=\(PennedKeyboardTrace.documentToken(model.documentID)) selected=\(environment.selectedDocumentID == model.documentID)", live: true)
            #endif
            environment.documentPreviews.setEditorActive(model.documentID, active: true)
            model.session.setApplicationColorScheme(colorScheme)
            syncLocalState()
            model.prepareForSpaceChange = {
                guard let document = model.document, hasTitleChanges else { return }
                let saved = try environment.documents.updateTitle(id: document.id, title: titleText)
                model.document = saved
            }
            if environment.selectedDocumentID == model.documentID {
                #if os(iOS)
                activateRendering(from: nil)
                #endif
                updateCollectionPresentation()
            }
        }
        #if DEBUG && os(iOS)
        .onChange(of: environment.selectedDocumentID == model.documentID && presentationReady, initial: true) { _, eligible in
            model.session.traceOpeningSurface(eligible: eligible)
        }
        .onDisappear {
            if !ownsEditorPresentation { model.session.traceOpeningSurface(eligible: false) }
        }
        #endif
        .onChange(of: colorScheme) { _, scheme in model.session.setApplicationColorScheme(scheme) }
        .onReceive(environment.collections.$revision) { _ in updateCollectionPresentation() }
        .onChange(of: model.session.renderedDocumentID) { _, rendered in
            if rendered == model.documentID { model.syncLinkedCalendarEvents() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: RunLoop.main)) { _ in
            model.syncLinkedCalendarEvents()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: RunLoop.main)) { _ in
            model.syncLinkedCalendarEvents()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellixTasksChanged).receive(on: RunLoop.main)) { _ in
            model.refreshTaskHistoryPage()
            model.refreshSharedTaskReferences()
        }
        .onChange(of: model.pageReferenceIDs) { _, _ in updateCollectionPresentation() }
        .onReceive(model.$collectionEditorRequest) { request in
            guard let request else { return }
            model.collectionEditorRequest = nil
            guard ownsEditorPresentation else { return }
            handleCollectionRequest(request)
        }
        .onReceive(model.session.$placeholderMode) { placeholderMode = $0 }
        .onReceive(model.session.$templateEditing) { templateMode = $0 }
        .onReceive(model.$taskFeedback) { message in
            guard let message, environment.selectedDocumentID == model.documentID else { return }
            showEditorBanner(message, icon: "clockfill")
            model.taskFeedback = nil
        }
        .onChange(of: placeholderMode) { _, active in
            guard templateMode, environment.selectedDocumentID == model.documentID else { return }
            showEditorBanner(active ? "Placeholder Mode On" : "Placeholder Mode Off", icon: "linedpages")
        }
        .onReceive(model.session.$isReady) { ready in
            canUseTemplateControls = ready && !model.session.isLoadingDocument
            if !ready, linkRequest?.mode == .text { linkRequest = nil }
        }
        .onReceive(model.session.$isLoadingDocument) { loading in
            canUseTemplateControls = model.session.isReady && !loading
            if loading, linkRequest?.mode == .text { linkRequest = nil }
        }
        .task(id: editorBanner?.id) {
            guard editorBanner != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            withAnimation(.easeOut(duration: 0.18)) { editorBanner = nil }
        }
        .onChange(of: environment.selectedDocumentID) { oldValue, newValue in
            #if DEBUG && os(iOS)
            if newValue == model.documentID { PennedKeyboardTrace.setActiveSession(model.session) }
            if oldValue == model.documentID || newValue == model.documentID {
                PennedKeyboardTrace.record("ui.editor.activeDocument", session: model.session,
                    "oldDoc=\(PennedKeyboardTrace.documentToken(oldValue)) newDoc=\(PennedKeyboardTrace.documentToken(newValue))", live: true)
            }
            #endif
            dismissBlockDeletion()
            if newValue == model.documentID {
                #if os(iOS)
                activateRendering(from: oldValue)
                #endif
                updateCollectionPresentation()
            }
            guard oldValue == model.documentID, newValue != model.documentID else {
                return
            }
            #if os(iOS)
            model.session.renderRecovery.deactivate(reason: "selected-document-changed")
            #endif
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
            #if DEBUG && os(iOS)
            PennedKeyboardTrace.record("ui.titleFocus", session: model.session, "focused=\(focused)")
            #endif
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
            #if os(iOS)
            queueCaretReveal()
            #endif
        }
        #if os(iOS)
        .onReceive(model.session.blockSelectionDragUpdates) { handleBlockSelectionDrag($0) }
        .onReceive(model.session.blockReorderDidLift) { _ in blockSelectionScrollDriver.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            blockSelectionScrollDriver.stop()
            model.session.blockDragGesture?.cancelForLifecycle()
            guard environment.selectedDocumentID == model.documentID else { return }
            model.session.renderRecovery.deactivate(reason: "application-inactive")
            // App switching is not an editing dismissal. Keep responder/caret
            // and title focus intact without forcing focus when returning.
            model.session.cancelPendingPaste()
            documentScrollProxy.pendingCaretRevision = nil
        }
        .onReceive(model.session.caretUpdates) { update in
            if update == nil { documentScrollProxy.pendingCaretRevision = nil }
            else { queueCaretReveal() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            guard ownsEditorPresentation, !isBlockKeyboardSheetPresented else { return }
            isKeyboardVisible = true
            updateKeyboardFrame(notification)
            model.session.requestCaretVisibility()
            // Re-reveal after the keyboard finishes animating, so a just-placed caret the
            // keyboard now covers is lifted into view against the settled layout.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard ownsEditorPresentation, !isBlockKeyboardSheetPresented else { return }
                model.session.requestCaretVisibility()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard ownsEditorPresentation, !isBlockKeyboardSheetPresented else { return }
            updateKeyboardFrame(notification)
            queueCaretReveal()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { notification in
            guard !isBlockKeyboardSheetPresented, workspace != nil,
                  environment.selectedDocumentID == model.documentID else { return }
            updateKeyboardFrame(notification)
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
                reportedSelectionMode = .off
                dismissSelectionControls()
            }
        }
        .onReceive(model.session.$selectionMode) { mode in
            let nextMode = EditorSelectionMode(rawValue: mode) ?? .off
            guard reportedSelectionMode != nextMode else { return }
            #if DEBUG && os(iOS)
            PennedKeyboardTrace.record("ui.selectionMode", session: model.session,
                "old=\(reportedSelectionMode.rawValue) new=\(nextMode.rawValue)")
            #endif
            reportedSelectionMode = nextMode
            if nextMode == .off {
                selectedBlockCount = 0
                dismissSelectionControls()
            }
        }
        .onReceive(model.session.$formattingState) { state in
            if let target = selectionFormattingTarget, state.selectedBlocksStyle?.target != target {
                dismissSelectionFormatting()
            }
        }
        .onReceive(model.session.$isEditing) { isEditing in
            #if DEBUG && os(iOS)
            if isEditingDocument != isEditing {
                PennedKeyboardTrace.record("ui.editor.editing", session: model.session, "new=\(isEditing)")
            }
            #endif
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
            #if DEBUG && os(iOS)
            if presentationReady != ready {
                PennedKeyboardTrace.record("ui.editor.presentation", session: model.session, "ready=\(ready)")
            }
            #endif
            presentationReady = ready
            #if os(iOS)
            model.session.renderRecovery.record("readiness-change", ["presentationReady": ready])
            #endif
            if !ready { savedBodyHeight = 0 }
        }
        .onPreferenceChange(SavedDocumentBodyHeightPreference.self) { savedBodyHeight = $0 }
    }

    private var editorRequestContent: some View {
        editorSelectionContent
        .onReceive(model.$blockConversionRequest) { request in
            guard let request else { return }
            model.blockConversionRequest = nil
            guard ownsEditorPresentation, !isEditorLocked else { return }
            if request.target == "link" { presentLinkEditor(.insert) }
            else if request.target == "file" { presentFileImporter() }
        }
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
        .onReceive(model.$blockquoteColorRequest) { request in
            guard let request else { return }
            model.blockquoteColorRequest = nil
            guard environment.selectedDocumentID == model.documentID, presentationReady, !isEditorLocked else { return }
            selectedBlockquoteColor = Color(vellixHex: request.color)
            blockquoteColorRequest = request
        }
        .onReceive(model.propertyEditorRequests) { request in
            guard ownsEditorPresentation, !isEditorLocked else { return }
            dismissKeyboard()
            propertyEditorReturnTarget = request.resumeEditing ? (model.documentID, request.blockID) : nil
            propertyEditorRequest = request
        }
    }

    private var editorContent: some View {
        editorRequestContent
        .onReceive(model.$propertyURLRequest) { request in
            guard let request, let url = DocumentLinkURL.openable(request.url) else { return }
            model.propertyURLRequest = nil
            if ownsEditorPresentation { openURL(url) }
        }
        .onReceive(model.$appearance) { appearance in
            localAppearance = appearance
        }
        .onDisappear {
            #if DEBUG && os(iOS)
            PennedKeyboardTrace.record("ui.editor.disappear", session: model.session,
                "viewDoc=\(PennedKeyboardTrace.documentToken(model.documentID))", live: true)
            #endif
            #if os(iOS)
            blockSelectionScrollDriver.stop()
            // A replacement host can appear before the outgoing subtree disappears.
            guard !ownsEditorPresentation else {
                model.session.renderRecovery.record("editor-disappearance-ignored", ["reason": "document-still-owns-presentation"])
                return
            }
            model.session.renderRecovery.deactivate(reason: "editor-view-disappeared")
            #endif
            environment.documentPreviews.setEditorActive(model.documentID, active: false)
            model.session.pauseAttachmentPlayback()
            model.attachmentActionRequest = nil
            clearBlockquoteColorRequest()
            dismissBlockDeletion()
            editorBanner = nil
            persistTitle()
            dismissKeyboard()
            if environment.selectedDocumentID != model.documentID {
                model.session.resetTabsNavigation()
            }
            model.flushPendingSave()
        }
    }

    private var editorPrimaryPresentations: some View {
        editorContent
        .modifier(TagEditorIntegration(model: model, session: model.session, locked: isEditorLocked || !ownsEditorPresentation))
        .fileImporter(isPresented: editorPresentation($showFileImporter), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard ownsEditorPresentation, fileInsertionDocumentID == model.documentID, !isEditorLocked else { return }
            switch result {
            case .success(let urls): Task {
                await model.importAttachments(urls: urls, token: fileInsertionToken)
                model.session.cancelBlockConversion()
            }
            case .failure(let error):
                model.session.cancelBlockConversion()
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: editorPresentation($model.attachmentEditorRequest)) { request in
            AttachmentEditorSheet(request: request, session: model.session, editable: !isEditorLocked)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($collectionEditorRequest)) { request in
            collectionSheet(request)
        }
        .sheet(item: editorPresentation($model.washiTapeRequest)) { request in
            WashiTapeSettingsSheet(request: request, store: environment.attachmentStore) { path, photo, data, tapeSize in
                guard environment.selectedDocumentID == model.documentID, !isEditorLocked else {
                    throw VellixError.editorBridge("This document is no longer open for editing.")
                }
                try await model.saveWashiTape(request, imagePath: path, photo: photo, data: data, tapeSize: tapeSize)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        #if os(iOS)
        .sheet(item: editorPresentation($model.headingLabelSettingsRequest)) { request in
            HeadingLabelSettingsSheet(request: request, fallbackFont: model.appearance.fontStyle) { settings, text in
                guard environment.selectedDocumentID == model.documentID, !isEditorLocked else {
                    throw VellixError.editorBridge("This document is no longer open for editing.")
                }
                try await model.saveHeadingLabel(request, settings: settings, text: text)
            }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.iconCalloutSettingsRequest)) { request in
            IconCalloutSettingsSheet(request: request) { settings, text, data in
                guard environment.selectedDocumentID == model.documentID, !isEditorLocked else {
                    throw VellixError.editorBridge("This document is no longer open for editing.")
                }
                try await model.saveIconCallout(request, settings: settings, text: text, data: data)
            }
            .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.gridCardSettingsRequest)) { request in
            GridCardSettingsSheet(request: request) { settings in
                guard environment.selectedDocumentID == model.documentID, !isEditorLocked else {
                    throw VellixError.editorBridge("This document is no longer open for editing.")
                }
                try await model.saveGridCard(request, settings: settings)
            }
            .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.codeBlockEditorRequest)) { request in
            CodeBlockEditorSheet(request: request) { draft in
                model.session.previewCodeBlock(request, draft: draft, documentID: model.documentID)
            } onSave: { draft in
                guard environment.selectedDocumentID == model.documentID, !isEditorLocked else {
                    throw VellixError.editorBridge("This document is no longer open for editing.")
                }
                try await model.saveCodeBlock(request, draft: draft)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .presentationSizing(.page)
        }
        #endif
        .sheet(item: editorPresentation($model.listGridSettingsRequest)) { settings in
            ListGridSettingsSheet(settings: settings, documentID: model.documentID, session: model.session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.linkedCalendarEventRequest)) { request in
            LinkedCalendarEventDetailPresentation(request: request)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.existingEventPickerRequest)) { _ in
            ExistingEventPickerSheet(session: model.session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.weekStripSettingsRequest)) { request in
            WeekStripSettingsSheet(request: request, session: model.session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.moodBarSettingsRequest)) { request in
            MoodBarSettingsSheet(request: request, session: model.session)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.countdownSettingsRequest)) { request in
            CountdownSettingsSheet(request: request) { settings, data in
                guard environment.selectedDocumentID == model.documentID, !isEditorLocked else {
                    throw VellixError.editorBridge("This document is no longer open for editing.")
                }
                try await model.saveCountdown(request, settings: settings, data: data)
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.calculatorSettingsRequest)) { request in
            CalculatorSettingsSheet(request: request, session: model.session) { settings in
                guard environment.selectedDocumentID == model.documentID, !isEditorLocked else {
                    throw VellixError.editorBridge("This document is no longer open for editing.")
                }
                try await model.saveCalculator(request, settings: settings)
            }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.tabsSettingsRequest)) { settings in
            TabsSettingsSheet(settings: settings, documentID: model.documentID, session: model.session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.informationCardSettingsRequest)) { settings in
            InformationCardSettingsSheet(settings: settings, session: model.session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.minimalFieldsSettingsRequest)) { settings in
            MinimalFieldsSettingsSheet(settings: settings, documentID: model.documentID, session: model.session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.taskEditorRequest)) { request in
            TaskEditorSheet(model: model, notifications: environment.taskNotifications, request: request)
        }
        .sheet(item: editorPresentation($model.taskHistoryRequest)) { request in
            TaskHistorySheet(request: request)
        }
        .onChange(of: model.taskHistoryRequest?.id) { _, id in if id != nil && ownsEditorPresentation { dismissKeyboard() } }
        .sheet(item: editorPresentation($model.tableEditorRequest), onDismiss: { model.session.tableAction("close") }) { request in
            TableEditorSheet(model: model, request: request)
        }
    }

    private var editorAppearancePresentations: some View {
        editorPrimaryPresentations
        .sheet(item: editorPresentation($model.templateInsertionRequest)) { request in
            TemplateInsertionSheet(model: model, request: request)
        }
        .sheet(isPresented: editorPresentation($showAppearance)) {
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
        .sheet(item: editorPresentation($blockquoteColorRequest)) { request in
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
    }

    private var editorBlockPresentations: some View {
        editorAppearancePresentations
        .modifier(InlineTextColorPresentation(request: editorPresentation($textColorRequest), session: model.session))
        .sheet(item: editorPresentation($propertyEditorRequest), onDismiss: resumeEditingAfterProperty) { request in
            InlinePropertyEditorSheet(property: request.property,
                editingGuidance: templateMode && placeholderMode, onSave: { property in
                guard ownsEditorPresentation, !isEditorLocked else { return }
                model.session.updateInlineProperty(blockID: request.blockID, property: property)
            }, onDelete: {
                guard ownsEditorPresentation, !isEditorLocked else { return }
                model.session.deleteInlineProperty(blockID: request.blockID)
            })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.templateComponentRequest)) { request in
            TemplateComponentEditorSheet(request: request, session: model.session)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }

    private var editorUtilityPresentations: some View {
        editorBlockPresentations
        #if os(iOS)
        .sheet(item: editorPresentation(Binding(
            get: { linkRequest?.mode == .text ? nil : linkRequest },
            set: { if linkRequest?.mode != .text { linkRequest = $0 } }
        ))) { request in
            DocumentLinkEditorSheet(request: request) { url, kind, label in
                try await model.session.applyLink(request, url: url, kind: kind, label: label)
            }.onDisappear { model.session.endLinkEditing(request) }
        }
        .sheet(item: editorPresentation(Binding(
            get: { selectionMode == .off ? nil : linkLayoutRequest }, set: { linkLayoutRequest = $0 }
        ))) { link in
            DocumentLinkLayoutSheet(link: link) { layout in
                try await model.session.actOnLink(link, action: "layout", layout: layout)
            }
        }
        #endif
        .sheet(isPresented: editorPresentation($showSnapshots)) {
            SnapshotHistoryView(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: editorPresentation(Binding(
            get: { selectionMode != .off && showSelectedActions }, set: { showSelectedActions = $0 }
        )), onDismiss: {
            if let link = queuedLinkEdit {
                queuedLinkEdit = nil
                if selectionMode != .off { presentLinkEditor(.block, blockID: link.id) }
            }
        }) {
            SelectedBlockActionsSheet(
                link: model.session.formattingState.selectedLink,
                editLink: { queuedLinkEdit = $0 },
                linkAction: { link, action in performLinkAction(link, action: action) },
                copyAction: { copySelectedBlocks() },
                cutAction: { model.session.cutSelectedBlocks() },
                duplicateAction: { model.session.duplicateSelectedBlocks() },
                groupAction: { model.groupSelectedBlocksIntoChildPage() },
                deleteAction: { model.session.deleteSelectedBlocks() }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: editorPresentation($model.cardEditorRequest), onDismiss: { model.cancelCardInsertion() }) { request in
            PageCardEditorSheet(request: request, store: environment.attachmentStore, previews: environment.documentPreviews) { style, imageData in
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
            get: { ownsEditorPresentation && model.attachmentActionRequest != nil },
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
            get: { ownsEditorPresentation && blockDeletionRequest != nil },
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
            get: { ownsEditorPresentation && pageDeletionTarget != nil },
            set: { if !$0 { pageDeletionTarget = nil } }
        ), titleVisibility: .visible) {
            if let page = pageDeletionTarget {
                Button(page.cardStyle == nil ? "Show as Card" : "Card Style") {
                    guard !isEditorLocked else { return }
                    pageDeletionTarget = nil
                    model.editPageCard(page)
                }
                Button("Indent") {
                    guard !isEditorLocked else { return }
                    model.session.indentPageReference(documentID: page.id)
                    pageDeletionTarget = nil
                }
                Button("Outdent") {
                    guard !isEditorLocked else { return }
                    model.session.indentPageReference(documentID: page.id, outdent: true)
                    pageDeletionTarget = nil
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
            Text("Deleting moves this page and its nested pages to Trash. You can restore them later.")
        }
        .alert("Convert this text to placeholder guidance?", isPresented: Binding<Bool>(
            get: { ownsEditorPresentation && model.placeholderConversionToken != nil },
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
            get: { ownsEditorPresentation && model.tableEditorRequest == nil && model.taskEditorRequest == nil && (model.errorMessage != nil || model.session.bridgeErrorMessage != nil) },
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
        .sheet(item: editorPresentation($publishingDocument)) { document in PublishingSheet(document: document, queue: environment.publishing) }
        .alert("Editor", isPresented: editorErrorPresentation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? model.session.bridgeErrorMessage ?? "")
        }
        .vellixHideEditorNavigationBar(isActive: ownsEditorPresentation)
        #if os(iOS)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: copyHapticRevision)
        #endif
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
            documentScrollToTopButton(isCompact: isCompact)

            #if os(iOS)
            documentKeyboardToolbar
            #endif

            documentSlashMenu(proxy: proxy, isCompact: isCompact)

        }
        #if os(iOS)
        .allowsHitTesting(selectionFormattingTarget == nil && linkRequest?.mode != .text)
        .accessibilityHidden(selectionFormattingTarget != nil || linkRequest?.mode == .text)
        .overlay(alignment: .bottom) {
            if let target = selectionFormattingTarget {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.14).ignoresSafeArea()
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    SelectionStyleSheet(session: model.session, documentFont: appearance.fontStyle,
                                        selectionTarget: target, dismiss: dismissSelectionFormatting)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                        .transition(.offset(y: 240).combined(with: .opacity))
                }
            } else if let request = linkRequest, request.mode == .text {
                DocumentLinkEditorSheet(request: request, dismissPanel: {
                    if linkRequest?.id == request.id { linkRequest = nil }
                }) { url, kind, label in
                    try await model.session.applyLink(request, url: url, kind: kind, label: label)
                }
                .frame(height: min(204, max(1, proxy.size.height - 10)))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .id(request.id)
                .onDisappear { model.session.endLinkEditing(request) }
            }
        }
        #endif
        .coordinateSpace(name: DocumentEditorCoordinateSpace.workspace)
        .onChange(of: proxy.size) { _, _ in
            #if canImport(UIKit)
            if linkRequest?.mode != .text { model.session.requestCaretVisibility() }
            #endif
        }
    }

    private func documentScrollView(_ document: DocumentRecord, appearance: DocumentAppearance, size: CGSize, isCompact: Bool) -> some View {
        let scrollWidth: CGFloat? = workspace == nil ? nil : size.width
        let scrollHeight: CGFloat? = workspace == nil ? nil : size.height

        return ScrollView(showsIndicators: false) {
            documentScrollContent(document, appearance: appearance, size: size, isCompact: isCompact)
        }
        #if !canImport(UIKit)
        .scrollPosition($documentScrollPosition)
        #endif
        #if os(iOS)
        .scrollDismissesKeyboard(.never)
        #endif
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
        // Styled page height and the external toolbar scrolling clearance are independent.
        let styledMinimumHeight = max(0, size.height - topPadding)
        let styledWidth = min(max(0, size.width - 2 * horizontalPadding),
            workspace != nil ? 720 : (isCompact ? size.width : 900)) * 0.96

        return VStack(spacing: appearance.themeID == nil ? 0 : 30) {
            if appearance.themeID == nil {
                plainDocument(document, appearance: appearance, isCompact: isCompact, minimumHeight: minimumHeight)
            } else {
                themedDocument(document, appearance: appearance, isCompact: isCompact,
                    minimumHeight: styledMinimumHeight, bottomPadding: isCompact ? 4 : 8)
                    .frame(width: styledWidth)
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
        if showsKeyboardFormattingToolbar {
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
        if selectionMode != .off && selectedBlockCount > 0 && !isEditorLocked {
                SelectedBlocksToolbar(
                    session: model.session,
                    styleAction: presentSelectionFormatting,
                    settingsAction: { target in
                        guard !isEditorLocked, environment.selectedDocumentID == model.documentID,
                              model.session.formattingState.selectedBlockSettings == target else { return }
                        if target.kind == "documentLink" {
                            // Link editing validates and retains its selected block.
                            presentLinkEditor(.block, blockID: target.blockID)
                        } else {
                            model.session.requestSelectedBlockSettings(target)
                        }
                    },
                    layoutAction: { linkLayoutRequest = $0 },
                    actionsAction: { showSelectedActions = true },
                    copyAction: { copySelectedBlocks() },
                    cutAction: { model.session.cutSelectedBlocks() },
                    duplicateAction: { model.session.duplicateSelectedBlocks() },
                    groupAction: { model.groupSelectedBlocksIntoChildPage() },
                    deleteAction: { model.session.deleteSelectedBlocks() },
                    isCompact: isCompact
                )
                .padding(.horizontal, isCompact ? 14 : 34)
                .padding(.bottom, isCompact ? 18 : 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }

        if selectionMode == .off && selectedBlockCount == 0 && !isEditingDocument && !isEditorLocked &&
            !showsKeyboardFormattingToolbar && linkRequest?.mode != .text {
            EditorFloatingToolbar(
                session: model.session,
                appearanceAction: { showAppearance = true },
                templateGalleryAction: { model.session.insertBlock("templates") },
                isCompact: isCompact
            )
            .padding(.horizontal, isCompact ? 26 : 34)
            .padding(.bottom, isCompact ? 0 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    @ViewBuilder private func documentScrollToTopButton(isCompact: Bool) -> some View {
        if showsScrollToTopButton && ownsEditorPresentation {
            Button {
                guard ownsEditorPresentation else { return }
                #if canImport(UIKit)
                guard let scrollView = documentScrollProxy.scrollView else { return }
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x,
                                                   y: -scrollView.adjustedContentInset.top), animated: !reduceMotion)
                #else
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                    documentScrollPosition.scrollTo(edge: .top)
                }
                #endif
            } label: {
                LibraryIcon(name: "upwavy", size: 25)
                    .foregroundStyle(VellixSurface.controlInk)
                    .frame(width: 48, height: 48)
                    .pennedPhoneDarkChrome(cornerRadius: 48)
                    .overlay(Circle().strokeBorder(VellixSurface.controlInk.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scroll to top of document")
            .help("Scroll to top of document")
            .padding(.trailing, isCompact ? 18 : 34)
            .padding(.bottom, selectionMode != .off ? 112 : 82)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private var showsKeyboardFormattingToolbar: Bool {
        #if os(iOS)
        guard selectionMode == .off, !isEditorLocked, !isBlockKeyboardSheetPresented else { return false }
        if workspace != nil {
            return environment.selectedDocumentID == model.documentID && presentationReady && !isTitleFocused
                && (isEditingDocument || isKeyboardVisible)
        }
        return isEditingDocument && isKeyboardVisible
        #else
        return false
        #endif
    }

    #if os(iOS)
    @ViewBuilder private var documentKeyboardToolbar: some View {
        if workspace != nil {
            if environment.selectedDocumentID == model.documentID {
                PadFormattingKeyboardDock(content: keyboardFormattingToolbar().environment(\.colorScheme, colorScheme),
                                          isVisible: showsKeyboardFormattingToolbar)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(90)
            }
        } else if showsKeyboardFormattingToolbar {
            keyboardFormattingToolbar()
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
            templateMode: templateMode,
            canUseTemplateControls: canUseTemplateControls,
            canSaveTemplate: canUseTemplateControls && !model.isSavingTemplate
                && (model.templateNeedsSave || hasTitleChanges),
            isSavingTemplate: model.isSavingTemplate,
            sidebarAction: sidebarAction
        ) {
            guard ownsEditorPresentation, !model.session.isReturningFromDocument else { return }
            #if os(iOS)
            model.session.renderRecovery.record("back-request", ["targetParent": document.parentDocumentID ?? "-"])
            #endif
            model.session.isReturningFromDocument = true
            Task {
                defer { model.session.isReturningFromDocument = false }
                do {
                    try await model.captureAndSave()
                    guard ownsEditorPresentation else { return }
                    #if os(iOS)
                    model.session.renderRecovery.record("back-save-completed")
                    #endif
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
        }
    }

    #if os(iOS)
    private func keyboardFormattingToolbar() -> some View {
        let taskAction: (() -> Void)? = model.taskContext == nil ? nil : {
            model.openTaskScheduling()
        }
        let templateComponentAction: ((TemplateComponentKind) -> Void)? = model.document?.templateID == nil ? nil : { kind in
            model.templateComponentRequest = TemplateComponentRequest(definition: TemplateComponentDefinition(kind: kind))
        }
        let format = model.session.formatCurrentSelection

        return EditorKeyboardFormattingToolbar(
            session: model.session,
            textColorAction: { presentTextColorEditor() },
            textLinkAction: { presentLinkEditor(.text) },
            insertLinkAction: { presentLinkEditor(.insert) },
            boldAction: { format("bold", nil) },
            italicAction: { format("italic", nil) },
            underlineAction: { format("underline", nil) },
            strikeAction: { format("strike", nil) },
            codeAction: { format("code", nil) },
            alignLeftAction: { format("align", "left") },
            alignCenterAction: { format("align", "center") },
            alignRightAction: { format("align", "right") },
            outdentAction: { format("outdent", nil) },
            indentAction: { format("indent", nil) },
            checklistAction: { format("checkList", nil) },
            taskAction: taskAction,
            bulletListAction: { format("bulletList", nil) },
            numberListAction: { format("numberList", nil) },
            fileAction: { presentFileImporter() },
            insertBlockAction: { model.session.insertBlock($0) },
            insertDividerAction: { model.session.insertDivider($0) },
            pageBreakAction: { model.session.insertPageBreak() },
            templateComponentAction: templateComponentAction,
            addTabAction: { model.session.tabsAddToSelection() },
            dismissAction: {
                if workspace != nil { model.session.blur() }
                dismissKeyboard()
            }
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

    private func presentLinkEditor(_ mode: DocumentLinkRequest.Mode, blockID: String? = nil) {
        guard !preparingLink, linkRequest == nil, !isEditorLocked,
              environment.selectedDocumentID == model.documentID else { return }
        preparingLink = true
        Task {
            defer { preparingLink = false }
            do {
                let request = try await model.session.beginLinkEditing(mode, blockID: blockID)
                guard request.documentID == model.documentID, environment.selectedDocumentID == request.documentID,
                      !isEditorLocked else { model.session.endLinkEditing(request); return }
                if mode == .text { model.session.endWebEditingForSettings() }
                linkRequest = request
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func performLinkAction(_ link: SelectedDocumentLink, action: String) {
        Task {
            do { try await model.session.actOnLink(link, action: action) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    @ViewBuilder private func documentTitle(_ document: DocumentRecord, appearance: DocumentAppearance, isCompact: Bool) -> some View {
        if DocumentTaskPages.isDetail(document.id), let task = model.historyPageTask {
            TaskHistoryPageHeader(task: task, appearance: appearance, title: $titleText,
                saveTitle: { model.rename(title: $0) }, titleFocused: $isTitleFocused, titleSize: 24, locked: isEditorLocked)
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
                        .font(appearance.fontStyle.font(size: 24, weight: .bold))
                        .padding(.horizontal, 8).frame(minHeight: 44)
                        .background(Color(vellixHex: appearance.textColorHex).opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).fixedSize().accessibilityLabel("Open Calendar for " + day.title)
                titleInput("Title", text: Binding(get: { day.suffix(from: titleText) }, set: { titleText = $0.isEmpty ? day.title : day.title + " " + $0 }), appearance: appearance, isCompact: isCompact)
            } else {
                titleInput(document.title.isEmpty ? "" : "Untitled", text: $titleText, appearance: appearance, isCompact: isCompact)
            }
        }.foregroundStyle(Color(vellixHex: appearance.textColorHex))
        }
    }

    private func titleInput(_ prompt: String, text: Binding<String>, appearance: DocumentAppearance, isCompact: Bool) -> some View {
        TextField(prompt, text: text.singleLinePageTitle(onReturn: { isTitleFocused = false }), axis: .vertical)
            .accessibilityLabel(prompt.isEmpty ? "Page title" : prompt)
            .focused($isTitleFocused)
            .font(appearance.fontStyle.font(size: 24, weight: .black))
            .foregroundStyle(Color(vellixHex: appearance.textColorHex))
            .textFieldStyle(.plain).lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .submitLabel(.done)
            .frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(!isEditorLocked)
            .onSubmit { isTitleFocused = false; persistTitle(); environment.refresh() }
            .onKeyPress(.return) { isTitleFocused = false; persistTitle(); return .handled }
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
        minimumHeight: CGFloat,
        bottomPadding: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    if appearance.displaysCover {
                        coverView(document: document, appearance: appearance, isCompact: isCompact)
                            .padding(.bottom, 28)
                    }

                    documentTitle(document, appearance: appearance, isCompact: isCompact)

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
            // The styled page, not the WebView, owns the viewport minimum.
            .frame(minHeight: minimumHeight, alignment: .topLeading)
            .backgroundPreferenceValue(PageSheetEditorBoundsPreferenceKey.self) { editorBounds in
                pageSheetBackgrounds(
                    appearance: appearance,
                    isCompact: isCompact,
                    editorBounds: editorBounds,
                    isVisible: true,
                    minimumHeight: minimumHeight
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
            PageCardFlowLayout(smallCards: unplaced.map { $0.cardStyle?.size.fillsDocumentWidth == false }) {
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
                                        fillsCardSlot: !style.size.fillsDocumentWidth,
                                        attachmentStore: environment.attachmentStore, containingFontStyle: appearance.fontStyle, previews: environment.documentPreviews)
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
            .frame(maxWidth: .infinity, alignment: .leading)
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

            Rectangle()
                .fill(Color(vellixHex: appearance.textColorHex).opacity(appearance.themeID == nil ? 0.07 : 0.08))
                .frame(height: 1)
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
                            .offset(y: segment.y)
                    }
                }
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
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

    #if os(iOS)
    private func activateRendering(from previousID: String?) {
        model.session.renderRecovery.activate(documentID: model.documentID,
            parentID: model.document?.parentDocumentID, previousID: previousID,
            previousParentID: environment.editorCache.model(for: previousID)?.document?.parentDocumentID,
            scrollView: documentScrollProxy.scrollView)
    }
    #endif

    @ViewBuilder
    private func documentScrollFinder() -> some View {
        #if canImport(UIKit)
        DocumentScrollViewFinder(proxy: documentScrollProxy, session: model.session, webView: model.webViewStore.webView,
                                 editorIsActive: ownsEditorPresentation && !isEditorLocked)
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

    #if os(iOS)
    private func handleBlockSelectionDrag(_ drag: MobileBlockSelectionDrag) {
        guard drag.active else { blockSelectionScrollDriver.finish(token: drag.token); return }
        guard !isEditorLocked, environment.selectedDocumentID == model.documentID,
              model.session.selectionMode != "off", let scrollView = documentScrollProxy.scrollView else {
            blockSelectionScrollDriver.stop()
            return
        }
        let model = model, environment = environment
        blockSelectionScrollDriver.receive(drag, scrollView: scrollView, webView: model.webViewStore.webView) { [weak model, weak environment] in
            guard let model, let environment else { return false }
            return environment.selectedDocumentID == model.documentID && model.session.selectionMode != "off"
                && !model.session.isLoadingDocument && model.session.editingEnabled
                && model.session.renderedDocumentID == model.documentID
        }
    }
    #endif

    #if canImport(UIKit)
    private var isBlockKeyboardSheetPresented: Bool {
        // These sheets own their keyboard; there is no web caret to reveal.
        model.tabsSettingsRequest != nil || model.weekStripSettingsRequest != nil || model.moodBarSettingsRequest != nil || model.countdownSettingsRequest != nil || model.calculatorSettingsRequest != nil || model.existingEventPickerRequest != nil || model.listGridSettingsRequest != nil ||
            model.headingLabelSettingsRequest != nil || model.minimalFieldsSettingsRequest != nil ||
            model.informationCardSettingsRequest != nil ||
            model.gridCardSettingsRequest != nil || model.iconCalloutSettingsRequest != nil ||
            model.taskEditorRequest != nil || model.washiTapeRequest != nil ||
            propertyEditorRequest != nil || model.codeBlockEditorRequest != nil || linkRequest?.mode == .text
    }

    private func updateKeyboardFrame(_ notification: Notification) {
        if let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            keyboardFrame = value.cgRectValue
            if workspace != nil, let window = model.webViewStore.webView.window {
                // iPad keyboard changes can arrive without a matching will-show event.
                let frame = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
                let overlap = window.bounds.intersection(frame)
                isKeyboardVisible = !overlap.isNull && !overlap.isEmpty
            }
        }
    }

    private func queueCaretReveal() {
        // Only reveal once the keyboard is up. Scrolling/laying out during the focus-
        // acquiring tap cancels the WebView becoming first responder (tap-twice-to-type).
        guard let update = model.session.caretUpdate, model.session.isEditing, isKeyboardVisible,
              !isEditorLocked, selectionMode == .off, !isBlockKeyboardSheetPresented,
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
              !isBlockKeyboardSheetPresented, model.session.renderedDocumentID == model.documentID,
              environment.selectedDocumentID == model.documentID,
              let scrollView = documentScrollProxy.scrollView, let window = scrollView.window,
              model.webViewStore.webView.isDescendant(of: scrollView) else { return }
        guard !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else {
            documentScrollProxy.pendingCaretRevision = nil
            return
        }
        let webView = model.webViewStore.webView
        func targetOffset() -> CGFloat? {
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
            return TipTapCaretVisibility.targetOffset(caret: caret, viewport: viewport,
                current: scrollView.contentOffset.y, minimum: minimum, maximum: maximum)
        }
        guard targetOffset() != nil else {
            documentScrollProxy.pendingCaretRevision = nil
            return
        }
        // A visible caret needs neither an offset change nor a synchronous
        // layout pass. Recheck after layout only when we may need to scroll.
        scrollView.superview?.layoutIfNeeded()
        guard let target = targetOffset() else {
            documentScrollProxy.pendingCaretRevision = nil
            return
        }
        if abs(target - scrollView.contentOffset.y) > 1 {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
            if targetOffset() == nil { documentScrollProxy.pendingCaretRevision = nil }
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
                                #if os(iOS)
                                .overlay {
                                    MobileCollectionSelectionHighlight(session: model.session, blockID: region.id)
                                }
                                #endif
                                .offset(x: region.rect.minX, y: region.rect.minY)
                                .allowsHitTesting(presentationReady && selectionMode == .off && environment.selectedDocumentID == model.documentID)
                                .id(region.id + (snapshot.activeView?.id ?? ""))
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            #if os(iOS)
            // Reserve paint space outside the unchanged text column for rounded selection surfaces.
            .padding(.horizontal, -MobileBlockSelection.selectionGutter)
            #endif
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
        let menuWidth = max(1, min(state.width, proxy.size.width - 28))
        let x = min(
            proxy.size.width - menuWidth - 14,
            max(14, editorSurfaceFrame.minX + state.anchorX)
        )
        let top: CGFloat = 10
        var bottom = proxy.size.height - 10
        #if os(iOS)
        if isKeyboardVisible, !keyboardFrame.isNull, let window = model.webViewStore.webView.window {
            let keyboard = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let workspace = proxy.frame(in: .global)
            let menuBounds = CGRect(x: workspace.minX + x, y: workspace.minY,
                                    width: menuWidth, height: workspace.height)
            if menuBounds.intersects(keyboard) {
                bottom = min(bottom, keyboard.minY - workspace.minY - 10)
            }
        }
        if showsKeyboardFormattingToolbar {
            bottom -= EditorKeyboardFormattingToolbar.height + EditorKeyboardFormattingToolbar.bottomPadding
        }
        #endif
        let desiredHeight = 14 + CGFloat(min(state.items.count, 5)) * 62
        let below = max(top, editorSurfaceFrame.minY + state.anchorY)
        let above = min(bottom, editorSurfaceFrame.minY + (state.anchorAboveY ?? state.anchorY - 38))
        let placeAbove = bottom - below < desiredHeight && above - top > bottom - below
        let height = max(1, min(desiredHeight, placeAbove ? above - top : bottom - below))
        let y = max(top, min(bottom - height, placeAbove ? above - height : below))

        return TipTapSlashCommandMenu(
            state: state,
            isCompact: isCompact,
            maxHeight: height,
            chooseAction: { key in
                model.session.chooseSlashMenuItem(key)
            }
        )
        .frame(width: menuWidth, alignment: .topLeading)
        .offset(x: x, y: y)
    }

    private func coverView(document: DocumentRecord, appearance: DocumentAppearance, isCompact: Bool) -> some View {
        // The frame owns the cover's size; portrait artwork must not size the page.
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let localCover {
                    StoredAttachmentImage(relativePath: localCover, contentMode: .fill)
                } else {
                    ThemeCoverArt(theme: appearance.resolvedCoverTheme)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isCompact ? 8 : 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: isCompact ? 8 : 10, style: .continuous)
                    .stroke(VellixSurface.controlInk.opacity(0.08), lineWidth: 1)
            }
    }

    private func setSelectionMode(_ mode: EditorSelectionMode) {
        selectedStylePanel = nil
        if mode == .off {
            selectedBlockCount = 0
            reportedSelectionMode = .off
            dismissSelectionControls()
            model.session.clearBlockSelection()
        } else {
            model.session.setSelectionMode(mode.rawValue)
        }
    }

    private func presentSelectionFormatting() {
        guard let target = model.session.formattingState.selectedBlocksStyle?.target else { return }
        withAnimation(.easeOut(duration: 0.22)) { selectionFormattingTarget = target }
    }

    private func dismissSelectionFormatting() {
        withAnimation(.easeOut(duration: 0.22)) { selectionFormattingTarget = nil }
    }

    private func dismissSelectionControls() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            queuedLinkEdit = nil
            showSelectedActions = false
            linkLayoutRequest = nil
            selectedStylePanel = nil
            selectionFormattingTarget = nil
        }
        #if os(iOS)
        blockSelectionScrollDriver.stop()
        #endif
    }

    private func deactivateEditor() {
        propertyEditorReturnTarget = nil
        propertyEditorRequest = nil
        collectionEditorRequest = nil
        pageDeletionTarget = nil
        showFileImporter = false
        showAppearance = false
        showSnapshots = false
        publishingDocument = nil
        linkRequest = nil
        linkLayoutRequest = nil
        queuedLinkEdit = nil
        selectionFormattingTarget = nil
        clearBlockquoteColorRequest()
        #if os(iOS)
        model.session.cancelPendingPaste()
        #endif
        model.session.pauseAttachmentPlayback()
        persistTitle()
        dismissKeyboard()
        model.session.resetTabsNavigation()
        editorContentHeight = max(60, model.session.editorContentHeight)
        editorVisualContentBottom = max(
            0,
            model.session.editorVisualContentBottom
        )
        selectedBlockCount = 0
        isEditingDocument = false
        isEditorLocked = false
        showSelectedActions = false
        reportedSelectionMode = .off
        selectedStylePanel = nil
        slashMenuState = nil
        model.session.clearBlockSelection()
        model.session.setEditable(true)
        model.flushPendingSave()
        environment.refresh()
    }

    private func clearBlockquoteColorRequest() {
        blockquoteColorRequest = nil
        model.blockquoteColorRequest = nil
    }

    private func toggleEditorLock() {
        let nextValue = !isEditorLocked
        #if DEBUG && os(iOS)
        PennedKeyboardTrace.record("ui.editor.lock", session: model.session, "locked=\(nextValue)")
        #endif
        isEditorLocked = nextValue
        showSelectedActions = false
        linkRequest = nil
        linkLayoutRequest = nil
        queuedLinkEdit = nil
        selectionFormattingTarget = nil
        selectedStylePanel = nil
        selectedBlockCount = 0
        reportedSelectionMode = .off
        if nextValue {
            model.washiTapeRequest = nil
            model.iconCalloutSettingsRequest = nil
            dismissKeyboard()
        }
        model.session.clearBlockSelection()
        model.session.setEditable(!nextValue)
    }

    private func dismissKeyboard(file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        #if os(iOS)
        #if DEBUG
        PennedKeyboardTrace.record("ui.dismissKeyboard", session: model.session,
            "action=UIApplication.resignFirstResponder visible=\(isKeyboardVisible) at=\(file):\(line) \(function)", live: true)
        #endif
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
              ownsEditorPresentation,
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

    private func persistTitle() {
        guard hasTitleChanges else { return }
        model.rename(title: titleText)
    }

    private var hasTitleChanges: Bool {
        guard let document = model.document else { return false }
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty && !document.title.isEmpty ? "Untitled" : title) != document.title
    }

    private func copySelectedBlocks() {
        #if os(iOS)
        model.session.copySelectedBlocks { copied in
            guard copied, ownsEditorPresentation else { return }
            copyHapticRevision &+= 1
            showEditorBanner("Selected blocks were copied", icon: "copy")
        }
        #else
        model.session.copySelectedBlocks()
        #endif
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
        self.toolbar(isActive ? .hidden : .automatic, for: .navigationBar)
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
    var templateMode: Bool
    var canUseTemplateControls: Bool
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
                    .font(document.appearance.fontStyle.font(size: isCompact ? 16 : 22, weight: .black))
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
        if document.templateID != nil && templateMode {
            Button(action: placeholderModeAction) {
                editorAssetIcon("linedpages", padding: isCompact ? 2 : 4)
                    .foregroundStyle(placeholderMode ? VellixSurface.controlInk : Color.gray)
            }
            .disabled(isEditorLocked || !canUseTemplateControls)
            .accessibilityLabel("Placeholder Mode")
            .accessibilityValue(placeholderMode ? "On" : "Off")
            .help("Placeholder Mode")
            .contextMenu {
                Button("Convert Text to Guidance") { placeholderAction("convert") }.disabled(!placeholderMode)
                Button("Convert Guidance to Content") { placeholderAction("ordinary") }.disabled(!placeholderMode)
                Button("Clear Guidance") { placeholderAction("clear") }.disabled(!placeholderMode)
            }
        }
        if document.templateID != nil {
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
    var maxHeight: CGFloat
    var chooseAction: (String) -> Void

    var body: some View {
        ScrollView(showsIndicators: CGFloat(state.items.count) * 62 + 14 > maxHeight) {
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
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(VellixSurface.toolbar.opacity(0.96), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(VellixSurface.controlInk.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: VellixSurface.elevationShadow(opacity: 0.44), radius: 24, x: 0, y: 12)
    }
}

private struct SelectedBlocksToolbar: View {
    @ObservedObject var session: TipTapEditorSession
    var styleAction: () -> Void
    var settingsAction: (TipTapSelectedBlockSettings) -> Void
    var layoutAction: (SelectedDocumentLink) -> Void
    var actionsAction: () -> Void
    var copyAction: () -> Void
    var cutAction: () -> Void
    var duplicateAction: () -> Void
    var groupAction: () -> Void
    var deleteAction: () -> Void
    var isCompact: Bool

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    SelectedToolbarItem(title: "Style", assetName: nil, textIcon: "Aa",
                        tint: VellixSurface.formattingAccent, action: styleAction, isCompact: isCompact)
                    if let target = session.formattingState.selectedBlockSettings, let title = target.title {
                        item("Settings", "settingswavy") { settingsAction(target) }
                            .help(title)
                            .accessibilityLabel(title)
                    }
                    if let link = session.formattingState.selectedLink, link.isRich {
                        item("Layout", "gridboard", tint: VellixSurface.formattingAccent) { layoutAction(link) }
                    }
                    item("Group", "groupfill", tint: VellixSurface.groupingAccent, action: groupAction)
                    item("Actions", "sendbutton", action: actionsAction)
                    item("Copy", "copy", action: copyAction)
                    item("Cut", "prohibitedwavy", action: cutAction)
                    item("Duplicate", "threeboxes", action: duplicateAction)
                }.padding(.leading, 3)
            }
            Divider().frame(height: 32)
            SelectedToolbarItem(title: "Delete", assetName: "trash", textIcon: nil,
                tint: VellixSurface.destructiveAccessory, action: deleteAction, isCompact: isCompact, isDestructive: true)
                .padding(3)
        }
        .disabled(session.selectedBlockCount == 0)
        .frame(maxWidth: isCompact ? .infinity : 650)
        .frame(height: isCompact ? 73 : 82)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(VellixSurface.controlInk.opacity(0.16)) }
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func item(_ title: String, _ icon: String, tint: Color = VellixSurface.controlInk,
                      action: @escaping () -> Void) -> some View {
        SelectedToolbarItem(title: title, assetName: icon, textIcon: nil,
            tint: tint, action: action, isCompact: isCompact)
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
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .frame(height: 24)
                } else if let assetName {
                    Image(assetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 23, height: 24)
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(VellixSurface.secondaryControlInk(opacity: 0.65))
            }
            .foregroundStyle(tint)
            .frame(width: isCompact ? 64 : 76, height: isCompact ? 65 : 74)
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
                styleSquare("outdent", action: outdentAction)
                styleSquare("indent", action: indentAction)
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
                headingOption("Subheading", weight: .bold)
                headingOption("Paragraph", weight: .regular)
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
    @Environment(\.openURL) private var openURL
    let link: SelectedDocumentLink?
    var editLink: (SelectedDocumentLink) -> Void
    var linkAction: (SelectedDocumentLink, String) -> Void
    var copyAction: () -> Void
    var cutAction: () -> Void
    var duplicateAction: () -> Void
    var groupAction: () -> Void
    var deleteAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 0) {
                    if let link {
                        if link.isRich {
                            actionRow("Turn Into Text Link", assetName: "linedpages") { linkAction(link, "convert") }
                            actionRow("Reload Link Info", assetName: "clockwavy") { linkAction(link, "reload") }
                        } else if link.canConvertToRich {
                            actionRow("Turn Into Rich Link", assetName: "linkcircle") { linkAction(link, "convert") }
                        }
                        actionRow("Edit Link", assetName: "plainpencil") { editLink(link) }
                        actionRow("Copy Link", assetName: "link") { UIPasteboard.general.string = link.href }
                        if let url = DocumentLinkURL.openable(link.href) {
                            actionRow("Open Link", assetName: "sendbutton") { openURL(url) }
                        }
                        sheetDivider()
                    }
                    actionRow("Copy", assetName: "copy", action: copyAction)
                    actionRow("Cut", assetName: "prohibitedwavy", action: cutAction)
                    actionRow("Duplicate", assetName: "threeboxes", action: duplicateAction)
                    actionRow("Group into Sub Page", assetName: "groupfill", action: groupAction)
                    sheetDivider()
                    actionRow("Delete", assetName: "trash", destructive: true, action: deleteAction)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .pennedSheet(title: "Actions", close: { dismiss() })
    }

    private func actionRow(
        _ title: String,
        assetName: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.system(size: 16))
                Spacer()
            }
            .foregroundStyle(destructive ? VellixSurface.destructiveLabel : VellixSurface.controlInk.opacity(0.88))
            .frame(minHeight: 42).contentShape(Rectangle())
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
    @ObservedObject var session: TipTapEditorSession
    @State private var canPaste = false
    @State private var showsHistoryBar = false
    var appearanceAction: () -> Void
    var templateGalleryAction: () -> Void
    var isCompact: Bool

    private var editorAvailable: Bool { session.isReady && !session.isLoadingDocument && session.isPresentationReady }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if showsHistoryBar {
                historyBar
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity)
            } else {
                HStack {
                    HStack(spacing: isCompact ? 16 : 26) {
                        assetToolbarButton("paintbrush", title: "Document Appearance", action: appearanceAction)
                        assetToolbarButton("hashtagwavy", title: "Templates", action: templateGalleryAction)
                        assetToolbarButton("undo", title: "Undo, Paste and Redo", enabled: editorAvailable) {
                            refreshPasteAvailability()
                            showsHistoryBar = true
                        }
                    }
                    .padding(.horizontal, isCompact ? 18 : 30)
                    .frame(height: isCompact ? 54 : 74)
                    .background(.thinMaterial, in: Capsule())
                    .overlay { Capsule().stroke(VellixSurface.controlInk.opacity(0.13), lineWidth: 1) }

                    Spacer()
                }
            }
        }
        .shadow(color: VellixSurface.elevationShadow(opacity: 0.42), radius: 26, x: 0, y: 12)
        .onAppear(perform: refreshPasteAvailability)
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refreshPasteAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refreshPasteAvailability() }
        #elseif canImport(AppKit)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPasteAvailability() }
        #endif
    }

    private var historyBar: some View {
        VStack(spacing: 4) {
            Button { showsHistoryBar = false } label: {
                Capsule()
                    .fill(VellixSurface.controlInk.opacity(0.22))
                    .frame(width: 34, height: 4)
                    .frame(width: 44, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close History Controls")
            HStack(spacing: 0) {
                historyButton("undo", title: "Undo", enabled: editorAvailable && session.canUndo, action: session.undo)
                historyButton("paste", title: "Paste", enabled: editorAvailable && canPaste, action: session.paste)
                historyButton("redo", title: "Redo", enabled: editorAvailable && session.canRedo, action: session.redo)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .frame(height: isCompact ? 88 : 102)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: isCompact ? 24 : 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 24 : 28, style: .continuous)
                .stroke(VellixSurface.controlInk.opacity(0.13), lineWidth: 1)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { value in
            if value.translation.height > 18 { showsHistoryBar = false }
        })
        .accessibilityAction(.escape) { showsHistoryBar = false }
    }

    private func historyButton(_ assetName: String, title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                assetToolbarImage(assetName)
                Text(title)
                    .font(.system(size: isCompact ? 11 : 13, weight: .medium, design: .rounded))
                    .foregroundStyle(VellixSurface.secondaryControlInk(opacity: 0.72))
            }
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 62 : 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(title)
        .help(title)
    }

    private func refreshPasteAvailability() {
        #if canImport(UIKit)
        canPaste = TipTapEditorSession.hasPasteboardContent
        #elseif canImport(AppKit)
        canPaste = !(NSPasteboard.general.types ?? []).isEmpty
        #endif
    }

    private func assetToolbarButton(_ assetName: String, title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            assetToolbarImage(assetName)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(title)
        .help(title)
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
private struct PadFormattingKeyboardDock<Content: View>: UIViewControllerRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let content: Content
    let isVisible: Bool

    func makeUIViewController(context: Context) -> Controller { Controller(content: content) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.loadViewIfNeeded()
        controller.host.rootView = content
        controller.host.view.isHidden = !isVisible
        controller.host.view.isUserInteractionEnabled = isEnabled
    }

    final class Controller: UIViewController {
        let host: UIHostingController<Content>

        init(content: Content) {
            host = UIHostingController(rootView: content)
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { return nil }

        override func loadView() {
            view = PassThroughView()
            view.backgroundColor = .clear
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(host)
            host.safeAreaRegions = []
            let bar = host.view!
            bar.backgroundColor = .clear
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                bar.heightAnchor.constraint(equalToConstant: EditorKeyboardFormattingToolbar.height),
                bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -EditorKeyboardFormattingToolbar.bottomPadding)
            ])
            host.didMove(toParent: self)
        }
    }

    private final class PassThroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let target = super.hitTest(point, with: event)
            return target === self ? nil : target
        }
    }
}

private struct EditorKeyboardFormattingToolbar: View {
    static let height: CGFloat = 50
    static let bottomPadding: CGFloat = 6

    @ObservedObject var session: TipTapEditorSession
    var textColorAction: () -> Void
    var textLinkAction: () -> Void
    var insertLinkAction: () -> Void
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
    var fileAction: () -> Void
    var insertBlockAction: (String) -> Void
    var insertDividerAction: (VellixDividerStyle) -> Void
    var pageBreakAction: () -> Void
    var templateComponentAction: ((TemplateComponentKind) -> Void)?
    var addTabAction: (() -> Void)? = nil
    var dismissAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if session.formattingState.hasTextSelection {
                toolbarButton("Text Color", assetName: "paintbrush", selected: session.formattingState.textColor != nil, action: textColorAction)
                    .help("Text Color")
                divider
            }
            if let title = session.formattingState.blockSettingsTitle {
                toolbarButton(title, assetName: "settingswavy", action: session.requestBlockSettings)
                    .padding(.leading, 6)
                    .help(title)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    toolbarButton("Bold", assetName: "boldtext", selected: session.formattingState.bold, action: boldAction)
                    toolbarButton("Italic", assetName: "italics", selected: session.formattingState.italic, action: italicAction)
                    toolbarButton("Underline", assetName: "underline", selected: session.formattingState.underline, action: underlineAction)
                    toolbarButton("Strikethrough", assetName: "strikethrough", selected: session.formattingState.strike, action: strikeAction)
                    toolbarButton("Link", assetName: "link", selected: session.formattingState.textLinkActive, action: textLinkAction)
                        .disabled(!session.formattingState.canLinkText)
                        .help("Add or edit a link")
                    toolbarButton("Inline Code", assetName: "codewindow", selected: session.formattingState.code, action: codeAction)
                    divider
                    toolbarButton("Align Left", assetName: "leftalign", selected: session.formattingState.alignment == "left", action: alignLeftAction)
                    toolbarButton("Align Center", assetName: "centeralign", selected: session.formattingState.alignment == "center", action: alignCenterAction)
                    toolbarButton("Align Right", assetName: "rightalign", selected: session.formattingState.alignment == "right", action: alignRightAction)
                    divider
                    toolbarButton("Outdent", assetName: "outdent", action: outdentAction)
                    toolbarButton("Indent", assetName: "indent", action: indentAction)
                    divider
                    toolbarButton("Checklist", assetName: "checklist", selected: session.formattingState.checklist, action: checklistAction)
                    toolbarButton("Bullet List", assetName: "bulletlist", selected: session.formattingState.bulletList, action: bulletListAction)
                    toolbarButton("Numbered List", assetName: "numberlist", selected: session.formattingState.numberList, action: numberListAction)
                }
                .padding(.leading, session.formattingState.blockSettingsTitle != nil ? 2 : 6)
                .padding(.trailing, 2)
            }

            divider
            if let taskAction {
                toolbarButton("Checklist Task Scheduling", assetName: "clockfill", action: taskAction)
                divider
            }
            EditorInsertMenu(
                fileAction: fileAction,
                linkAction: insertLinkAction,
                insertBlockAction: insertBlockAction,
                insertDividerAction: insertDividerAction,
                pageBreakAction: pageBreakAction,
                templateComponentAction: templateComponentAction,
                addTabAction: addTabAction
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
    var fileAction: () -> Void
    var linkAction: () -> Void
    var insertBlockAction: (String) -> Void
    var insertDividerAction: (VellixDividerStyle) -> Void
    var pageBreakAction: () -> Void
    var templateComponentAction: ((TemplateComponentKind) -> Void)?
    var addTabAction: (() -> Void)? = nil

    var body: some View {
        Menu {
            if let templateComponentAction {
                Menu("Template Components") {
                    ForEach(TemplateComponentKind.allCases) { kind in
                        Button(kind.title) { templateComponentAction(kind) }
                    }
                }
            }
            Menu("Headings") {
                ForEach(1...4, id: \.self) { level in
                    Menu(DocumentTextStyleNames.heading(level)) {
                        Button("Text") { insertBlockAction("heading\(level)") }
                        Button("Label") { insertBlockAction("labelHeading\(level)") }
                    }
                }
            }
            Menu("Text Blocks") {
                Button("Paragraph") { insertBlockAction("paragraph") }
                Button("Caption") { insertBlockAction("caption") }
            }
            Menu("Content Blocks") {
                Menu("Callouts") {
                    Button("Icon") { insertBlockAction("iconCallout") }
                    Button("Plain") { insertBlockAction("plainCallout") }
                }
                Button("Blockquote") { insertBlockAction("quote") }
                Button("Table") { insertBlockAction("table") }
            }
            Menu("Links & Files") {
                Button("Link") { linkAction() }
                Button("File") { fileAction() }
            }
            Menu("Nested Content") {
                Button("Page") { insertBlockAction("nestedPage") }
                Button("Card") { insertBlockAction("pageCard") }
            }
            Button("Code Block") { insertBlockAction("codeBlock") }
            Menu("Widgets") {
                Button("Mood Bar") { insertBlockAction("moodBar") }
                Button("Countdown") { insertBlockAction("countdown") }
                Button("Calculator") { insertBlockAction("calculator") }
            }
            Menu("Other Blocks") {
                Button("List Grids") { insertBlockAction("listGrid") }
                Button("Fields") { insertBlockAction("fields") }
                Button("Tabs") { insertBlockAction("tabs") }
                Button("Infocards") { insertBlockAction("informationCard") }
                Button("Grid Cards") { insertBlockAction("gridCard") }
                Menu("Planner") {
                    Button("Calendar") { insertBlockAction("weekStrip") }
                    Button("Event") { insertBlockAction("existingEvent") }
                }
            }
            Button("Collection") { insertBlockAction("collection") }
            Menu("Toggle") {
                Button("Paragraph") { insertBlockAction("toggleListItem") }
                Button("Title") { insertBlockAction("toggleHeading1") }
                Button("Subtitle") { insertBlockAction("toggleHeading2") }
                Button("Heading") { insertBlockAction("toggleHeading3") }
                Button("Subheading") { insertBlockAction("toggleHeading4") }
            }
            Menu("Lists") {
                Button("Checklist") { insertBlockAction("checkListItem") }
                Button("Bullet List") { insertBlockAction("bulletListItem") }
                Button("Numbered List") { insertBlockAction("numberedListItem") }
            }
            Menu("Properties") {
                ForEach(InlinePropertyKind.allCases) { kind in
                    Button(kind.title) { insertBlockAction("property:\(kind.rawValue)") }
                }
            }
            Menu("Divider") {
                ForEach(VellixDividerStyle.allCases) { style in
                    Button(style.title) {
                        insertDividerAction(style)
                    }
                }
                Button("Page Break") { pageBreakAction() }
            }
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

struct ListGridSettingsSheet: View {
    let settings: TipTapListGridSettings
    let documentID: String
    let session: TipTapEditorSession
    @Environment(\.dismiss) private var dismiss

    @State private var cardBackground: Color
    @State private var cardBorder: Color
    @State private var leftBackground: Color
    @State private var rightBorder: Color
    @State private var leftFraction: Double
    @State private var appliedLeftFraction: Int
    @State private var dragStartFraction: Double?
    @State private var isApplyingLayout = false
    @State private var isApplyingRowStyle = false
    @State private var settingsError: String?
    @State private var rows: [TipTapListGridRow]

    init(settings: TipTapListGridSettings, documentID: String, session: TipTapEditorSession) {
        self.settings = settings
        self.documentID = documentID
        self.session = session
        _cardBackground = State(initialValue: Color(vellixHex: settings.cardBackground))
        _cardBorder = State(initialValue: Color(vellixHex: settings.cardBorder))
        _leftBackground = State(initialValue: Color(vellixHex: settings.leftBackground))
        _rightBorder = State(initialValue: Color(vellixHex: settings.rightBorder))
        _leftFraction = State(initialValue: Double(settings.leftFraction))
        _appliedLeftFraction = State(initialValue: settings.leftFraction)
        _rows = State(initialValue: settings.rows)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    appearanceSection
                    layoutSection
                    rowsSection
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .pennedSheet(title: "List Grid Settings", close: { dismiss() }) {
                #if os(iOS)
                // The sheet has no FocusState; the shared control resigns the active UIKit responder.
                PennedSheetKeyboardDismissButton {}
                #endif
            }
        }
        .alert("List Grid Settings", isPresented: Binding(get: { settingsError != nil }, set: { if !$0 { settingsError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(settingsError ?? "") }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance").font(.headline)
            colorControl("Card Background", $cardBackground, "cardBackground", settings.cardBackground)
            colorControl("Card Border", $cardBorder, "cardBorder", settings.cardBorder)
            colorControl("Left Box Background", $leftBackground, "leftBackground", settings.leftBackground)
            colorControl("Right Box Border", $rightBorder, "rightBorder", settings.rightBorder)
        }
    }

    private func colorControl(_ title: String, _ binding: Binding<Color>, _ target: String, _ fallback: String) -> some View {
        ColorPicker(title, selection: Binding(
            get: { binding.wrappedValue },
            set: { color in
                binding.wrappedValue = color
                session.listGridSetColor(blockID: settings.blockID, target: target,
                                         color: color.vellixHexString(fallback: fallback))
            }
        ), supportsOpacity: false)
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .pennedSheetField(cornerRadius: 14)
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Layout").font(.headline)
                Spacer()
                Button("Restore Default") {
                    applyLayout(nil)
                }
                .font(.subheadline)
                .disabled(isApplyingLayout)
            }
            HStack {
                Text("Label column")
                Spacer()
                Text("\(Int(leftFraction))%").foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let available = geometry.size.width
                let split = available * leftFraction / 100
                HStack(spacing: 0) {
                    Text("Label")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(width: split, height: 72)
                        .background(leftBackground)
                    Text("Value")
                        .font(.subheadline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .background(.white)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(VellixSurface.violet)
                        .frame(width: 12, height: 52)
                        .overlay(Capsule().stroke(.white, lineWidth: 2))
                        .offset(x: split - 6)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard !isApplyingLayout, available > 0 else { return }
                                if dragStartFraction == nil { dragStartFraction = leftFraction }
                                let initial = dragStartFraction ?? leftFraction
                                leftFraction = max(20, min(80, initial + value.translation.width / available * 100))
                            }
                            .onEnded { _ in
                                guard dragStartFraction != nil else { return }
                                dragStartFraction = nil
                                applyLayout(Int(leftFraction.rounded()))
                            })
                        .accessibilityLabel("Resize List Grid columns")
                }
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(cardBorder, lineWidth: 1))
            }
            .frame(height: 72)
        }
    }

    private func applyLayout(_ requested: Int?) {
        guard !isApplyingLayout else { return }
        isApplyingLayout = true
        leftFraction = Double(requested ?? settings.defaultLeftFraction)
        Task {
            defer { isApplyingLayout = false }
            do {
                appliedLeftFraction = try await session.listGridSetProportion(blockID: settings.blockID,
                    documentID: documentID, leftFraction: requested)
                leftFraction = Double(appliedLeftFraction)
            } catch {
                leftFraction = Double(appliedLeftFraction)
                settingsError = error.localizedDescription
            }
        }
    }

    private func applyRowStyle(_ style: TipTapListGridRowStyle, at index: Int) {
        guard !isApplyingRowStyle, rows.indices.contains(index), rows[index].style != style else { return }
        isApplyingRowStyle = true
        Task {
            defer { isApplyingRowStyle = false }
            do {
                try await session.listGridSetRowStyle(blockID: settings.blockID, documentID: documentID,
                    index: index, style: style)
                rows[index].style = style
            } catch { settingsError = error.localizedDescription }
        }
    }

    private var rowsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rows").font(.headline)
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                let rowName = row.label.isEmpty ? "Row \(index + 1)" : row.label
                HStack {
                    Text(rowName)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        ForEach(TipTapListGridRowStyle.allCases, id: \.self) { style in
                            Button {
                                applyRowStyle(style, at: index)
                            } label: {
                                if style == row.style { Label(style.title, systemImage: "checkmark") }
                                else { Text(style.title) }
                            }
                        }
                    } label: {
                        Image("paintdrop")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .frame(width: 28)
                            .contentShape(Rectangle())
                    }
                    .pennedIconMenuStyle()
                    .accessibilityLabel("Row style: \(rowName)")
                    .accessibilityValue(row.style.title)
                    Button(role: .destructive) {
                        guard !isApplyingRowStyle, rows.count > 1, rows.indices.contains(index) else { return }
                        session.listGridRemoveRow(blockID: settings.blockID, index: index)
                        rows.remove(at: index)
                    } label: {
                        Image("minuswavy")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .disabled(rows.count <= 1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .pennedSheetField(cornerRadius: 14)
            }
            Button {
                guard !isApplyingRowStyle else { return }
                session.listGridAddRow(blockID: settings.blockID)
                rows.append(TipTapListGridRow(label: "", value: ""))
            } label: {
                HStack(spacing: 10) {
                    Image("addwavy")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    Text("Add Row").font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .pennedSheetField(cornerRadius: 14)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .disabled(isApplyingRowStyle)
    }
}

// Native presentation destination for the Week Strip header gesture.
// The appearance controls are added in Step 12.
struct WeekStripSettingsSheet: View {
    let request: WeekStripSettingsRequest
    let session: TipTapEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var colors: [String: Color]
    @State private var values: [String: Int]
    @State private var selectedDateBehavior: String

    private static let colorFields: [(String, String, String)] = [
        ("Inactive Date Tab Color", "inactiveTabColor", "#303137"),
        ("Active Date Tab Color", "activeTabColor", "#9276dc"),
        ("Navigation Button Color", "navigationColor", "#7c8b80"),
        ("Container Border Color", "containerBorderColor", "#34343b"),
        ("Background Color", "backgroundColor", "#121316"),
        ("Content Text Color", "contentTextColor", "#f7f7fa"),
    ]
    private static let numericDefaults: [String: Int] = [
        "borderWidth": 1, "borderThickness": 1, "cornerRadius": 18,
        "fontSize": 14, "fontWeight": 700, "firstDayOfWeek": 0,
        "padding": 14, "spacing": 14,
    ]

    init(request: WeekStripSettingsRequest, session: TipTapEditorSession) {
        self.request = request
        self.session = session
        _colors = State(initialValue: Dictionary(uniqueKeysWithValues: Self.colorFields.map { _, key, fallback in
            (key, Color(vellixHex: request.settings[key] as? String ?? fallback))
        }))
        _values = State(initialValue: Self.numericDefaults.mapValues { $0 }.merging(
            request.settings.compactMapValues { ($0 as? NSNumber)?.intValue }) { _, saved in saved })
        _selectedDateBehavior = State(initialValue: request.settings["selectedDateBehavior"] as? String ?? "remember")
    }

    private func update(_ key: String, _ value: Any) {
        session.weekStripSetAttr(blockID: request.blockID, key: key, value: value)
    }

    private func colorControl(_ title: String, key: String, fallback: String) -> some View {
        ColorPicker(title, selection: Binding(
            get: { colors[key] ?? Color(vellixHex: fallback) },
            set: { color in
                colors[key] = color
                update(key, color.vellixHexString(fallback: fallback))
            }), supportsOpacity: false)
    }

    private func numberControl(_ title: String, key: String, range: ClosedRange<Int>, step: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(values[key] ?? 0)").foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(values[key] ?? 0) },
                set: { newValue in
                    let rounded = Int((newValue / Double(step)).rounded()) * step
                    values[key] = rounded
                    update(key, rounded)
                }), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Colors") {
                    ForEach(Self.colorFields.indices, id: \.self) { index in
                        let field = Self.colorFields[index]
                        colorControl(field.0, key: field.1, fallback: field.2)
                    }
                }
                Section("Border") {
                    numberControl("Border Width", key: "borderWidth", range: 0...20)
                    numberControl("Border Thickness", key: "borderThickness", range: 0...8)
                }
                Section("Corners") {
                    numberControl("Corner Radius", key: "cornerRadius", range: 0...48)
                }
                Section("Typography") {
                    numberControl("Font Size", key: "fontSize", range: 10...24)
                    numberControl("Font Weight", key: "fontWeight", range: 400...900, step: 100)
                }
                Section("Calendar") {
                    Picker("First Day of Week", selection: Binding(
                        get: { values["firstDayOfWeek"] ?? 0 },
                        set: { values["firstDayOfWeek"] = $0; update("firstDayOfWeek", $0) })) {
                        ForEach(0..<7, id: \.self) { day in
                            Text(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][day]).tag(day)
                        }
                    }
                    Picker("Selected Date Behavior", selection: Binding(
                        get: { selectedDateBehavior },
                        set: { selectedDateBehavior = $0; update("selectedDateBehavior", $0) })) {
                        Text("Remember Last Selected Date").tag("remember")
                        Text("Always Select Today").tag("today")
                    }
                }
                Section("Layout") {
                    numberControl("Padding", key: "padding", range: 0...32)
                    numberControl("Spacing", key: "spacing", range: 0...32)
                }
            }
            .pennedSheet(title: "Week Strip Settings", close: { dismiss() })
        }
    }
}

struct TabsSettingsSheet: View {
    private enum Field: Hashable {
        case title, subtitle, tab(String)
    }

    let settings: TipTapTabsSettings
    let documentID: String
    let session: TipTapEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // General
    @State private var showContainer: Bool
    @State private var showHeader: Bool
    @State private var title: String
    @State private var subtitle: String
    @State private var icon: String
    // Tabs
    @State private var tabs: [TipTapTabInfo]
    @State private var activeTab: String
    // Appearance
    @State private var tabBarStyle: String
    @State private var alignment: String
    @State private var dividerVisible: Bool
    @State private var activeTabBg: Color
    @State private var activeTabText: Color
    @State private var inactiveTabBg: Color
    @State private var inactiveTabText: Color
    @State private var indicatorColor: Color
    @State private var titleColor: Color
    @State private var subtitleColor: Color
    @State private var tabCornerRadius: Int
    @State private var tabSpacing: Int
    // Container
    @State private var containerBg: Color
    @State private var containerBorder: Color
    @State private var borderWidth: Int
    @State private var cornerRadius: Int
    @State private var padding: Int
    @State private var outerSpacing: Int
    @State private var shadow: Bool

    @State private var iconPickerPresented = false
    @State private var isBusy = false
    @State private var settingsError: String?
    @State private var pendingHeaderText: [String: String] = [:]
    @State private var pendingTabNames: [String: String] = [:]
    @FocusState private var focusedField: Field?

    private let styleOptions: [(String, String)] = [
        ("filled", "Filled"), ("underlined", "Underlined"), ("segmented", "Segmented"), ("minimal", "Minimal")
    ]
    private let alignmentOptions: [(String, String)] = [
        ("leading", "Left"), ("center", "Center"), ("trailing", "Right")
    ]

    init(settings: TipTapTabsSettings, documentID: String, session: TipTapEditorSession) {
        self.settings = settings
        self.documentID = documentID
        self.session = session
        _showContainer = State(initialValue: settings.showContainer)
        _showHeader = State(initialValue: settings.showHeader)
        _title = State(initialValue: settings.title)
        _subtitle = State(initialValue: settings.subtitle)
        _icon = State(initialValue: settings.icon)
        _tabs = State(initialValue: settings.tabs)
        _activeTab = State(initialValue: settings.activeTab)
        _tabBarStyle = State(initialValue: settings.tabBarStyle)
        _alignment = State(initialValue: settings.alignment)
        _dividerVisible = State(initialValue: settings.dividerVisible)
        _activeTabBg = State(initialValue: Color(vellixHex: settings.activeTabBg))
        _activeTabText = State(initialValue: Color(vellixHex: settings.activeTabText))
        _inactiveTabBg = State(initialValue: Color(vellixHex: settings.inactiveTabBg))
        _inactiveTabText = State(initialValue: Color(vellixHex: settings.inactiveTabText))
        _indicatorColor = State(initialValue: Color(vellixHex: settings.indicatorColor))
        _titleColor = State(initialValue: Color(vellixHex: settings.titleColor))
        _subtitleColor = State(initialValue: Color(vellixHex: settings.subtitleColor))
        _tabCornerRadius = State(initialValue: settings.tabCornerRadius)
        _tabSpacing = State(initialValue: settings.tabSpacing)
        _containerBg = State(initialValue: Color(vellixHex: settings.containerBg))
        _containerBorder = State(initialValue: Color(vellixHex: settings.containerBorder))
        _borderWidth = State(initialValue: settings.borderWidth)
        _cornerRadius = State(initialValue: settings.cornerRadius)
        _padding = State(initialValue: settings.padding)
        _outerSpacing = State(initialValue: settings.outerSpacing)
        _shadow = State(initialValue: settings.shadow)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    generalSection
                    tabsSection
                    appearanceSection
                    containerSection
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.never)
            .onSubmit { finishTextEditing() }
            .pennedSheet(title: "Tabs Settings", close: {
                finishTextEditing()
                dismiss()
            }) {
                #if os(iOS)
                PennedSheetKeyboardDismissButton { finishTextEditing() }
                #endif
            }
        }
        .onChange(of: focusedField) { previous, _ in
            if previous != nil { flushTextEdits() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushTextEdits() }
        }
        .onDisappear(perform: flushTextEdits)
        .sheet(isPresented: $iconPickerPresented) {
            VellixIconLibraryPicker(title: "Tab Header Icon", selectedIcon: icon) { selected in
                icon = selected.name
                session.tabsSetIcon(blockID: settings.blockID, icon: selected.name)
            }
        }
        .alert("Tabs Settings", isPresented: Binding(get: { settingsError != nil }, set: { if !$0 { settingsError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(settingsError ?? "") }
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General").font(.headline)
            TextField("Title", text: textBinding($title, "title"))
                .focused($focusedField, equals: .title)
                .submitLabel(.done)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).frame(minHeight: 52)
                .pennedSheetField(cornerRadius: 14)
            TextField("Description", text: textBinding($subtitle, "subtitle"))
                .focused($focusedField, equals: .subtitle)
                .submitLabel(.done)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).frame(minHeight: 52)
                .pennedSheetField(cornerRadius: 14)
            iconRow
            toggleRow("Show Header", $showHeader, "showHeader")
            toggleRow("Show Container", $showContainer, "showContainer")
        }
    }

    private var iconRow: some View {
        HStack(spacing: 12) {
            Text("Header Icon")
            Spacer()
            if !icon.isEmpty {
                LibraryIcon(name: icon, size: 22)
                    .foregroundStyle(indicatorColor)
            }
            Button(icon.isEmpty ? "Add" : "Change") {
                finishTextEditing()
                iconPickerPresented = true
            }
            .font(.subheadline)
            if !icon.isEmpty {
                Button(role: .destructive) {
                    icon = ""
                    session.tabsSetAttr(blockID: settings.blockID, key: "icon", value: "")
                } label: { Text("Remove").font(.subheadline) }
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 52)
        .pennedSheetField(cornerRadius: 14)
    }

    // MARK: Tabs

    private var tabsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tabs").font(.headline)
            Text("Tap the circle to set the default tab.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(tabs.enumerated()), id: \.element.tabID) { index, tab in
                tabRow(index: index, tab: tab)
            }
            Button {
                addTab()
            } label: {
                HStack(spacing: 10) {
                    Image("addwavy").resizable().scaledToFit().frame(width: 20, height: 20)
                    Text("Add Tab").font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity).frame(height: 48)
                .pennedSheetField(cornerRadius: 14)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .disabled(isBusy)
        }
    }

    private func tabRow(index: Int, tab: TipTapTabInfo) -> some View {
        HStack(spacing: 8) {
            Button {
                setDefault(tab.tabID)
            } label: {
                ZStack {
                    Circle().strokeBorder(VellixSurface.controlInk.opacity(0.4), lineWidth: 2)
                    if activeTab == tab.tabID { Circle().fill(VellixSurface.violet).padding(4) }
                }
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activeTab == tab.tabID ? "Default tab" : "Set as default tab")
            TextField("Tab \(index + 1)", text: renameBinding(tab.tabID))
                .focused($focusedField, equals: .tab(tab.tabID))
                .submitLabel(.done)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            iconButton("chevup", "Move up") { move(index, by: -1) }
                .disabled(index == 0)
            iconButton("chevdown", "Move down") { move(index, by: 1) }
                .disabled(index == tabs.count - 1)
            iconButton("copy", "Duplicate tab") { duplicate(tab.tabID) }
                .disabled(isBusy)
            iconButton("minuswavy", "Delete tab") { deleteTab(tab.tabID) }
                .disabled(tabs.count <= 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .pennedSheetField(cornerRadius: 14)
    }

    private func iconButton(_ asset: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(asset).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 18, height: 18).frame(width: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance").font(.headline)
            Picker("Tab Bar Style", selection: styleBinding) {
                ForEach(styleOptions, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            Picker("Alignment", selection: alignmentBinding) {
                ForEach(alignmentOptions, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            colorRow("Active Tab Background", $activeTabBg, "activeTabBg", settings.activeTabBg)
            colorRow("Active Tab Text", $activeTabText, "activeTabText", settings.activeTabText)
            colorRow("Inactive Tab Background", $inactiveTabBg, "inactiveTabBg", settings.inactiveTabBg)
            colorRow("Inactive Tab Text", $inactiveTabText, "inactiveTabText", settings.inactiveTabText)
            colorRow("Indicator", $indicatorColor, "indicatorColor", settings.indicatorColor)
            colorRow("Title Color", $titleColor, "titleColor", settings.titleColor)
            colorRow("Subtitle Color", $subtitleColor, "subtitleColor", settings.subtitleColor)
            stepperRow("Tab Corner Radius", $tabCornerRadius, "tabCornerRadius", 0...24)
            stepperRow("Tab Spacing", $tabSpacing, "tabSpacing", 0...32)
            toggleRow("Divider", $dividerVisible, "dividerVisible")
        }
    }

    // MARK: Container

    private var containerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Container").font(.headline)
            colorRow("Background", $containerBg, "containerBg", settings.containerBg)
            colorRow("Border", $containerBorder, "containerBorder", settings.containerBorder)
            stepperRow("Border Width", $borderWidth, "borderWidth", 0...8)
            stepperRow("Corner Radius", $cornerRadius, "cornerRadius", 0...40)
            stepperRow("Padding", $padding, "padding", 0...40)
            stepperRow("Outer Spacing", $outerSpacing, "outerSpacing", 0...40)
            toggleRow("Shadow", $shadow, "shadow")
        }
        .disabled(!showContainer)
        .opacity(showContainer ? 1 : 0.5)
    }

    // MARK: Reusable rows

    private func toggleRow(_ title: String, _ value: Binding<Bool>, _ key: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { value.wrappedValue },
            set: { newValue in
                value.wrappedValue = newValue
                session.tabsSetAttr(blockID: settings.blockID, key: key, value: newValue)
            }))
            .padding(.horizontal, 14).frame(minHeight: 52)
            .pennedSheetField(cornerRadius: 14)
    }

    private func stepperRow(_ title: String, _ value: Binding<Int>, _ key: String, _ range: ClosedRange<Int>) -> some View {
        Stepper(value: Binding(
            get: { value.wrappedValue },
            set: { newValue in
                value.wrappedValue = newValue
                session.tabsSetAttr(blockID: settings.blockID, key: key, value: newValue)
            }), in: range) {
            HStack { Text(title); Spacer(); Text("\(value.wrappedValue)").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 14).frame(minHeight: 52)
        .pennedSheetField(cornerRadius: 14)
    }

    private func colorRow(_ title: String, _ binding: Binding<Color>, _ key: String, _ fallback: String) -> some View {
        ColorPicker(title, selection: Binding(
            get: { binding.wrappedValue },
            set: { color in
                binding.wrappedValue = color
                session.tabsSetAttr(blockID: settings.blockID, key: key,
                                    value: color.vellixHexString(fallback: fallback))
            }), supportsOpacity: false)
            .padding(.horizontal, 14).frame(minHeight: 52)
            .pennedSheetField(cornerRadius: 14)
    }

    // MARK: Bindings

    private func textBinding(_ binding: Binding<String>, _ key: String) -> Binding<String> {
        Binding(get: { binding.wrappedValue },
                set: { newValue in
                    binding.wrappedValue = newValue
                    pendingHeaderText[key] = newValue
                })
    }

    private var styleBinding: Binding<String> {
        Binding(get: { tabBarStyle },
                set: { newValue in
                    tabBarStyle = newValue
                    session.tabsSetAttr(blockID: settings.blockID, key: "tabBarStyle", value: newValue)
                })
    }

    private var alignmentBinding: Binding<String> {
        Binding(get: { alignment },
                set: { newValue in
                    alignment = newValue
                    session.tabsSetAttr(blockID: settings.blockID, key: "alignment", value: newValue)
                })
    }

    private func renameBinding(_ tabID: String) -> Binding<String> {
        Binding(get: { tabs.first(where: { $0.tabID == tabID })?.name ?? "" },
                set: { newValue in
                    guard let index = tabs.firstIndex(where: { $0.tabID == tabID }) else { return }
                    tabs[index].name = newValue
                    pendingTabNames[tabID] = newValue
                })
    }

    // MARK: Actions

    private func finishTextEditing() {
        focusedField = nil
        flushTextEdits()
    }

    private func flushTextEdits() {
        guard !pendingHeaderText.isEmpty || !pendingTabNames.isEmpty else { return }
        session.tabsCommitText(blockID: settings.blockID, documentID: documentID,
                               headerText: pendingHeaderText, tabNames: pendingTabNames)
        pendingHeaderText.removeAll()
        pendingTabNames.removeAll()
    }

    private func setDefault(_ tabID: String) {
        flushTextEdits()
        activeTab = tabID
        session.tabsSetDefaultTab(blockID: settings.blockID, tabID: tabID)
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard tabs.indices.contains(index), tabs.indices.contains(target) else { return }
        flushTextEdits()
        tabs.swapAt(index, target)
        session.tabsReorderTabs(blockID: settings.blockID, order: tabs.map { $0.tabID })
    }

    private func addTab() {
        guard !isBusy else { return }
        flushTextEdits()
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                if let newID = try await session.tabsAddTab(blockID: settings.blockID, documentID: documentID) {
                    tabs.append(TipTapTabInfo(tabID: newID, name: "Tab \(tabs.count + 1)"))
                }
            } catch { settingsError = error.localizedDescription }
        }
    }

    private func duplicate(_ tabID: String) {
        guard !isBusy, let index = tabs.firstIndex(where: { $0.tabID == tabID }) else { return }
        flushTextEdits()
        isBusy = true
        let base = tabs[index].name.isEmpty ? "Tab" : tabs[index].name
        Task {
            defer { isBusy = false }
            do {
                if let newID = try await session.tabsDuplicateTab(blockID: settings.blockID, documentID: documentID, tabID: tabID) {
                    let insertAt = min(index + 1, tabs.count)
                    tabs.insert(TipTapTabInfo(tabID: newID, name: "\(base) copy"), at: insertAt)
                }
            } catch { settingsError = error.localizedDescription }
        }
    }

    private func deleteTab(_ tabID: String) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.tabID == tabID }) else { return }
        if focusedField == .tab(tabID) { focusedField = nil }
        flushTextEdits()
        let fallbackTabID = tabs[index + 1 < tabs.count ? index + 1 : index - 1].tabID
        session.tabsRemoveTab(blockID: settings.blockID, tabID: tabID)
        tabs.remove(at: index)
        if activeTab == tabID { activeTab = fallbackTabID }
    }
}

struct MinimalFieldsSettingsSheet: View {
    let settings: TipTapMinimalFieldsSettings
    let documentID: String
    let session: TipTapEditorSession
    @Environment(\.dismiss) private var dismiss

    // Appearance
    @State private var accentColor: Color
    @State private var accentWidth: Int
    @State private var titleColor: Color
    @State private var titleSize: Int
    @State private var labelColor: Color
    @State private var labelSize: Int
    @State private var showRecordTitles: Bool
    @State private var labelUppercase: Bool
    @State private var valueColor: Color
    @State private var valueSize: Int
    @State private var dividerColor: Color
    @State private var dividerVisible: Bool
    @State private var fieldSpacing: Int
    @State private var recordSpacing: Int
    @State private var outerSpacing: Int
    // Structure
    @State private var records: [TipTapMinimalRecord]
    @State private var isBusy = false
    @State private var settingsError: String?

    init(settings: TipTapMinimalFieldsSettings, documentID: String, session: TipTapEditorSession) {
        self.settings = settings
        self.documentID = documentID
        self.session = session
        _accentColor = State(initialValue: Color(vellixHex: settings.accentColor))
        _accentWidth = State(initialValue: settings.accentWidth)
        _titleColor = State(initialValue: Color(vellixHex: settings.titleColor))
        _titleSize = State(initialValue: settings.titleSize)
        _labelColor = State(initialValue: Color(vellixHex: settings.labelColor))
        _labelSize = State(initialValue: settings.labelSize)
        _showRecordTitles = State(initialValue: settings.showRecordTitles)
        _labelUppercase = State(initialValue: settings.labelUppercase)
        _valueColor = State(initialValue: Color(vellixHex: settings.valueColor))
        _valueSize = State(initialValue: settings.valueSize)
        _dividerColor = State(initialValue: Color(vellixHex: settings.dividerColor))
        _dividerVisible = State(initialValue: settings.dividerVisible)
        _fieldSpacing = State(initialValue: settings.fieldSpacing)
        _recordSpacing = State(initialValue: settings.recordSpacing)
        _outerSpacing = State(initialValue: settings.outerSpacing)
        _records = State(initialValue: settings.records)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    appearanceSection
                    recordsSection
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .pennedSheet(title: "Fields Settings", close: { dismiss() }) {
                #if os(iOS)
                PennedSheetKeyboardDismissButton {}
                #endif
            }
        }
        .alert("Fields Settings", isPresented: Binding(get: { settingsError != nil }, set: { if !$0 { settingsError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(settingsError ?? "") }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance").font(.headline)
            colorRow("Accent Line", $accentColor, "accentColor", settings.accentColor)
            stepperRow("Accent Width", $accentWidth, "accentWidth", 1...8)
            toggleRow("Show Record Titles", $showRecordTitles, "showRecordTitles")
            if showRecordTitles {
                colorRow("Title Color", $titleColor, "titleColor", settings.titleColor)
                stepperRow("Title Size", $titleSize, "titleSize", 14...32)
            }
            colorRow("Label Color", $labelColor, "labelColor", settings.labelColor)
            stepperRow("Label Size", $labelSize, "labelSize", 9...18)
            toggleRow("Uppercase Labels", $labelUppercase, "labelUppercase")
            colorRow("Value Color", $valueColor, "valueColor", settings.valueColor)
            stepperRow("Value Size", $valueSize, "valueSize", 11...22)
            colorRow("Divider Color", $dividerColor, "dividerColor", settings.dividerColor)
            toggleRow("Dividers", $dividerVisible, "dividerVisible")
            stepperRow("Field Spacing", $fieldSpacing, "fieldSpacing", 0...32)
            stepperRow("Record Spacing", $recordSpacing, "recordSpacing", 0...48)
            stepperRow("Outer Spacing", $outerSpacing, "outerSpacing", 0...40)
        }
    }

    // MARK: Records

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Records").font(.headline)
            VStack(spacing: 14) {
                ForEach(Array(records.enumerated()), id: \.element.recordID) { index, record in
                    recordCard(index: index, record: record)
                }
            }
            Button {
                addRecord()
            } label: {
                HStack(spacing: 10) {
                    Image("addwavy").resizable().scaledToFit().frame(width: 20, height: 20)
                    Text("Add Record").font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity).frame(height: 50)
                .pennedSheetField(cornerRadius: 16)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }

    private func recordCard(index: Int, record: TipTapMinimalRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: title + record controls
            HStack(spacing: 10) {
                Text(record.title.isEmpty ? "Record \(index + 1)" : record.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                recordControls(index: index, record: record)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            // Fields
            VStack(spacing: 8) {
                ForEach(Array(record.fields.enumerated()), id: \.element.fieldID) { fieldIndex, field in
                    fieldRow(record: record, field: field, fieldIndex: fieldIndex)
                }
                addFieldButton(record.recordID)
                    .padding(.top, 2)
            }
            .padding(16)
        }
        .pennedSheetField(cornerRadius: 18)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func fieldRow(record: TipTapMinimalRecord, field: TipTapMinimalFieldInfo, fieldIndex: Int) -> some View {
        HStack(spacing: 10) {
            Circle().fill(accentColor).frame(width: 6, height: 6)
            Text(field.label.isEmpty ? "Field \(fieldIndex + 1)" : field.label)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            fieldControls(record: record, field: field, fieldIndex: fieldIndex)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func recordControls(index: Int, record: TipTapMinimalRecord) -> some View {
        HStack(spacing: 2) {
            iconButton("chevup", "Move record up", disabled: index == 0) { moveRecord(index, by: -1) }
            iconButton("chevdown", "Move record down", disabled: index == records.count - 1) { moveRecord(index, by: 1) }
            iconButton("copy", "Duplicate record", disabled: isBusy) { duplicateRecord(record.recordID) }
            iconButton("minuswavy", "Delete record", disabled: records.count <= 1) { deleteRecord(record.recordID) }
        }
    }

    private func fieldControls(record: TipTapMinimalRecord, field: TipTapMinimalFieldInfo, fieldIndex: Int) -> some View {
        HStack(spacing: 2) {
            iconButton("chevup", "Move field up", disabled: fieldIndex == 0) { moveField(record.recordID, fieldIndex, by: -1) }
            iconButton("chevdown", "Move field down", disabled: fieldIndex == record.fields.count - 1) { moveField(record.recordID, fieldIndex, by: 1) }
            iconButton("copy", "Duplicate field", disabled: isBusy) { duplicateField(record.recordID, field.fieldID) }
            iconButton("minuswavy", "Delete field", disabled: record.fields.count <= 1) { deleteField(record.recordID, field.fieldID) }
        }
    }

    private func addFieldButton(_ recordID: String) -> some View {
        Button {
            addField(recordID)
        } label: {
            HStack(spacing: 8) {
                Image("addwavy").renderingMode(.template).resizable().scaledToFit().frame(width: 15, height: 15)
                Text("Add Field").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(accentColor)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private func iconButton(_ asset: String, _ label: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(asset).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 17, height: 17)
                .frame(width: 32, height: 32)
                .foregroundStyle(Color.primary.opacity(0.7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .accessibilityLabel(label)
    }

    // MARK: Reusable rows

    private func toggleRow(_ title: String, _ value: Binding<Bool>, _ key: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { value.wrappedValue },
            set: { newValue in
                value.wrappedValue = newValue
                session.minimalFieldsSetAttr(blockID: settings.blockID, key: key, value: newValue)
            }))
            .padding(.horizontal, 14).frame(minHeight: 52)
            .pennedSheetField(cornerRadius: 14)
    }

    private func stepperRow(_ title: String, _ value: Binding<Int>, _ key: String, _ range: ClosedRange<Int>) -> some View {
        Stepper(value: Binding(
            get: { value.wrappedValue },
            set: { newValue in
                value.wrappedValue = newValue
                session.minimalFieldsSetAttr(blockID: settings.blockID, key: key, value: newValue)
            }), in: range) {
            HStack { Text(title); Spacer(); Text("\(value.wrappedValue)").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 14).frame(minHeight: 52)
        .pennedSheetField(cornerRadius: 14)
    }

    private func colorRow(_ title: String, _ binding: Binding<Color>, _ key: String, _ fallback: String) -> some View {
        ColorPicker(title, selection: Binding(
            get: { binding.wrappedValue },
            set: { color in
                binding.wrappedValue = color
                session.minimalFieldsSetAttr(blockID: settings.blockID, key: key,
                                             value: color.vellixHexString(fallback: fallback))
            }), supportsOpacity: false)
            .padding(.horizontal, 14).frame(minHeight: 52)
            .pennedSheetField(cornerRadius: 14)
    }

    // MARK: Record actions

    private func moveRecord(_ index: Int, by offset: Int) {
        let target = index + offset
        guard records.indices.contains(index), records.indices.contains(target) else { return }
        records.swapAt(index, target)
        session.minimalFieldsReorderRecords(blockID: settings.blockID, order: records.map { $0.recordID })
    }

    private func addRecord() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                if let newID = try await session.minimalFieldsAddRecord(blockID: settings.blockID, documentID: documentID) {
                    records.append(TipTapMinimalRecord(recordID: newID, title: "Record \(records.count + 1)",
                        fields: [TipTapMinimalFieldInfo(fieldID: UUID().uuidString, label: "Label")]))
                }
            } catch { settingsError = error.localizedDescription }
        }
    }

    private func duplicateRecord(_ recordID: String) {
        guard !isBusy, let index = records.firstIndex(where: { $0.recordID == recordID }) else { return }
        isBusy = true
        let source = records[index]
        Task {
            defer { isBusy = false }
            do {
                if let newID = try await session.minimalFieldsDuplicateRecord(blockID: settings.blockID, documentID: documentID, recordID: recordID) {
                    records.insert(TipTapMinimalRecord(recordID: newID, title: source.title, fields: source.fields), at: min(index + 1, records.count))
                }
            } catch { settingsError = error.localizedDescription }
        }
    }

    private func deleteRecord(_ recordID: String) {
        guard records.count > 1, let index = records.firstIndex(where: { $0.recordID == recordID }) else { return }
        session.minimalFieldsRemoveRecord(blockID: settings.blockID, recordID: recordID)
        records.remove(at: index)
    }

    // MARK: Field actions

    private func moveField(_ recordID: String, _ index: Int, by offset: Int) {
        guard let r = records.firstIndex(where: { $0.recordID == recordID }) else { return }
        let target = index + offset
        guard records[r].fields.indices.contains(index), records[r].fields.indices.contains(target) else { return }
        records[r].fields.swapAt(index, target)
        session.minimalFieldsReorderFields(blockID: settings.blockID, recordID: recordID, order: records[r].fields.map { $0.fieldID })
    }

    private func addField(_ recordID: String) {
        guard !isBusy, let r = records.firstIndex(where: { $0.recordID == recordID }) else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                if let newID = try await session.minimalFieldsAddField(blockID: settings.blockID, documentID: documentID, recordID: recordID),
                   let idx = records.firstIndex(where: { $0.recordID == recordID }) {
                    records[idx].fields.append(TipTapMinimalFieldInfo(fieldID: newID, label: "Label"))
                }
            } catch { settingsError = error.localizedDescription }
        }
        _ = r
    }

    private func duplicateField(_ recordID: String, _ fieldID: String) {
        guard !isBusy, let r = records.firstIndex(where: { $0.recordID == recordID }),
              let f = records[r].fields.firstIndex(where: { $0.fieldID == fieldID }) else { return }
        isBusy = true
        let label = records[r].fields[f].label
        Task {
            defer { isBusy = false }
            do {
                if let newID = try await session.minimalFieldsDuplicateField(blockID: settings.blockID, documentID: documentID, recordID: recordID, fieldID: fieldID),
                   let idx = records.firstIndex(where: { $0.recordID == recordID }) {
                    let insertAt = min((records[idx].fields.firstIndex(where: { $0.fieldID == fieldID }) ?? records[idx].fields.count - 1) + 1, records[idx].fields.count)
                    records[idx].fields.insert(TipTapMinimalFieldInfo(fieldID: newID, label: label), at: insertAt)
                }
            } catch { settingsError = error.localizedDescription }
        }
    }

    private func deleteField(_ recordID: String, _ fieldID: String) {
        guard let r = records.firstIndex(where: { $0.recordID == recordID }),
              records[r].fields.count > 1,
              let f = records[r].fields.firstIndex(where: { $0.fieldID == fieldID }) else { return }
        session.minimalFieldsRemoveField(blockID: settings.blockID, recordID: recordID, fieldID: fieldID)
        records[r].fields.remove(at: f)
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
                                if let preview = try? TipTapContentAnalyzer.analyze(snapshot.tipTapJSON).previewText, !preview.isEmpty {
                                    Text(preview).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                                }
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
        .background {
            #if os(iOS)
            PadWorkspacePageBackground(fallback: VellixSurface.sidebar, style: .systemMaterial)
            #else
            VellixSurface.sidebar
            #endif
        }
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

// MARK: - Minimal Information Card settings

private struct InformationCardSettingsSheet: View {
    let settings: TipTapInformationCardSettings
    let session: TipTapEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var backgroundColor: Color
    @State private var borderColor: Color
    @State private var dividerColor: Color
    @State private var titleColor: Color
    @State private var textColor: Color
    @State private var cornerRadius: Int
    @State private var padding: Int
    @State private var showBorder: Bool
    @State private var showLabels: Bool
    @State private var collapsible: Bool
    @State private var borderThickness: Int
    @State private var hideTitle: Bool
    @State private var hideDescription: Bool
    @State private var hideDivider: Bool

    init(settings: TipTapInformationCardSettings, session: TipTapEditorSession) {
        self.settings = settings
        self.session = session
        _backgroundColor = State(initialValue: Color(vellixHex: settings.backgroundColor))
        _borderColor = State(initialValue: Color(vellixHex: settings.borderColor))
        _dividerColor = State(initialValue: Color(vellixHex: settings.dividerColor))
        _titleColor = State(initialValue: Color(vellixHex: settings.titleColor))
        _textColor = State(initialValue: Color(vellixHex: settings.textColor))
        _cornerRadius = State(initialValue: settings.cornerRadius)
        _padding = State(initialValue: settings.padding)
        _showBorder = State(initialValue: settings.showBorder)
        _showLabels = State(initialValue: settings.showLabels)
        _collapsible = State(initialValue: settings.collapsible)
        _borderThickness = State(initialValue: settings.borderThickness)
        _hideTitle = State(initialValue: settings.hideTitle)
        _hideDescription = State(initialValue: settings.hideDescription)
        _hideDivider = State(initialValue: settings.hideDivider)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Appearance").font(.headline)
                    colorRow("Background", $backgroundColor, "backgroundColor")
                    colorRow("Border Color", $borderColor, "borderColor")
                    colorRow("Divider Color", $dividerColor, "dividerColor")
                    colorRow("Title Color", $titleColor, "titleColor")
                    colorRow("Text Color", $textColor, "textColor")
                    Toggle("Hide Title", isOn: $hideTitle)
                        .onChange(of: hideTitle) { _, value in set("hideTitle", value) }
                    Toggle("Hide Description", isOn: $hideDescription)
                        .onChange(of: hideDescription) { _, value in set("hideDescription", value) }
                    Toggle("Hide Divider", isOn: $hideDivider)
                        .onChange(of: hideDivider) { _, value in set("hideDivider", value) }
                    Toggle("Show Labels", isOn: $showLabels)
                        .onChange(of: showLabels) { _, value in set("showLabels", value) }
                    Toggle("Collapsible", isOn: $collapsible)
                        .onChange(of: collapsible) { _, value in set("collapsible", value) }
                    Toggle("Show Border", isOn: $showBorder)
                        .onChange(of: showBorder) { _, value in set("showBorder", value) }
                    Stepper("Border Thickness: \(borderThickness)", value: $borderThickness, in: 1...12)
                        .onChange(of: borderThickness) { _, value in set("borderThickness", value) }
                    Stepper("Corner Radius: \(cornerRadius)", value: $cornerRadius, in: 0...32)
                        .onChange(of: cornerRadius) { _, value in set("cornerRadius", value) }
                    Stepper("Padding: \(padding)", value: $padding, in: 8...36)
                        .onChange(of: padding) { _, value in set("padding", value) }
                    Text("Edit the card title, description, labels and values directly in the document.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .pennedSheet(title: "Information Card Settings", close: { dismiss() }) {
                #if os(iOS)
                PennedSheetKeyboardDismissButton {}
                #endif
            }
        }
    }

    private func set(_ key: String, _ value: Any) {
        session.informationCardSetAttr(blockID: settings.blockID, key: key, value: value)
    }

    private func colorRow(_ title: String, _ value: Binding<Color>, _ key: String) -> some View {
        ColorPicker(title, selection: value, supportsOpacity: false)
            .onChange(of: value.wrappedValue) { _, newValue in
                set(key, newValue.vellixHexString(fallback: "#FFFFFF"))
            }
    }
}

struct ExistingEventPickerRequest: Identifiable {
    let id = UUID()
}

struct ExistingEventPickerSheet: View {
    let session: TipTapEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var events: [CalendarEvent] = []
    @State private var isLoading = true
    @State private var status: String?
    @State private var pageIndex = 0
    @State private var pageAnchor = Calendar.current.startOfDay(for: Date())
    @State private var didSelectEvent = false
    private let calendarService = AppleCalendarService()

    private var pageRange: DateInterval {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: pageAnchor)?.start
            ?? calendar.startOfDay(for: pageAnchor)
        let first = calendar.date(byAdding: .weekOfYear, value: pageIndex, to: start) ?? start
        let last = calendar.date(byAdding: .weekOfYear, value: 1, to: first)
            ?? first.addingTimeInterval(7 * 86_400)
        return DateInterval(start: first, end: last)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { pageIndex -= 1 } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous week")
                    Spacer(minLength: 0)
                    Text("\(pageRange.start.formatted(date: .abbreviated, time: .omitted)) – \(pageRange.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Button { pageIndex += 1 } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next week")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Group {
                    if isLoading { Spacer(); ProgressView("Loading events…"); Spacer() }
                    else if let status {
                        Spacer()
                        ContentUnavailableView(status, systemImage: "calendar")
                        Spacer()
                    } else {
                        List(events) { event in
                            Button {
                                didSelectEvent = true
                                session.insertLinkedCalendarEvent(event)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.title)
                                    Text(event.start.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Existing Event")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: pageIndex) { await loadPage() }
            .onDisappear { if !didSelectEvent { session.cancelExistingEventPicker() } }
        }
    }

    private func loadPage() async {
        isLoading = true
        status = nil
        events = []
        do {
            let currentAccess = await calendarService.access()
            let access = currentAccess == .notRequested
                ? try await calendarService.requestAccess() : currentAccess
            guard !Task.isCancelled else { return }
            guard access == .allowed else {
                status = "Calendar access is required to select an event."
                isLoading = false
                return
            }
            let range = pageRange
            let pageEvents = await calendarService.events(in: range)
                .filter { range.contains($0.start) }
                .sorted {
                    if $0.start != $1.start { return $0.start < $1.start }
                    if $0.title != $1.title { return $0.title < $1.title }
                    return $0.id < $1.id
                }
            guard !Task.isCancelled else { return }
            events = pageEvents
            if pageEvents.isEmpty { status = "No events this week." }
        } catch {
            guard !Task.isCancelled else { return }
            status = "Unable to load calendar events."
        }
        isLoading = false
    }
}

struct LinkedCalendarEventRequest: Identifiable {
    let id = UUID()
    let eventID: String
    let identity: CalendarEventIdentity
    let start: Date
}

struct LinkedCalendarEventDetailPresentation: View {
    let request: LinkedCalendarEventRequest
    @EnvironmentObject private var environment: AppEnvironment
    @State private var event: CalendarEvent?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let event {
                CalendarEventDetailSheet(event: event, model: environment.calendar)
            } else if unavailable {
                ContentUnavailableView("Event unavailable", systemImage: "calendar")
            } else {
                ProgressView("Opening event…")
            }
        }
        .task(id: request.id) {
            let service = AppleCalendarService()
            let calendar = Calendar.current
            let start = calendar.date(byAdding: .day, value: -7, to: request.start) ?? request.start
            let end = calendar.date(byAdding: .day, value: 8, to: request.start) ?? request.start.addingTimeInterval(8 * 86_400)
            let matches = await service.events(in: DateInterval(start: start, end: end))
            guard !Task.isCancelled else { return }
            guard let found = matches.first(where: { $0.identity.key == request.eventID })
                ?? matches.first(where: {
                    $0.identity.calendarID == request.identity.calendarID &&
                    $0.identity.localID == request.identity.localID &&
                    $0.identity.occurrenceKey == request.identity.occurrenceKey
                }) else {
                unavailable = true
                return
            }
            environment.calendar.select(found.start)
            environment.calendar.activate()
            await environment.calendar.refreshAndWait()
            guard !Task.isCancelled else { return }
            environment.calendar.selectedEvent = found
            event = found
        }
    }
}
