//
//  TipTapEditorSession.swift
//  Vellix
//

import Foundation
import Combine
import CoreGraphics
import os
import WebKit
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class PennedDocumentOpeningTiming {
    private static let logger = Logger(subsystem: "im.lystaria.Vellix", category: "PennedDocumentOpening")
    private static var sequence = 0
    private let started = ProcessInfo.processInfo.systemUptime
    private let request: Int
    private var phases = Set<String>()
    let trace: PennedDocumentOpenTrace?

    init(trace: PennedDocumentOpenTrace? = nil) {
        self.trace = trace
        Self.sequence += 1
        request = Self.sequence
        mark("tap")
    }

    func mark(_ phase: String, route: String = "") {
        guard phases.insert(phase).inserted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        Self.logger.notice("[Penned Open] request=\(self.request, privacy: .public) phase=\(phase, privacy: .public) route=\(route, privacy: .public) uptimeMS=\(Int64(now * 1_000), privacy: .public) elapsedMS=\(Int((now - self.started) * 1_000), privacy: .public)")
    }
}

@MainActor
final class TipTapEditorSession: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isLoadingDocument = false
    @Published private(set) var isPresentationReady = false
    private var presentation = DocumentPresentationState()
    private var presentationTask: Task<Void, Never>?
    private var presentationInputsRevision = 0
    private var preparedInputsRevision: Int?
    private var confirmingFrameGeneration: Int?
    private var pendingNativePresentationHeights: [String: (viewID: String, height: CGFloat)] = [:]
    private var currentAppearance: DocumentAppearance?
    private(set) var applicationColorScheme: ColorScheme = .dark
    private var pageReferenceColorScheme: ColorScheme = .dark
    private var pageReferenceFontStyle: DocumentFontStyle?
    private var pageReferenceSnapshotKeys: [String: String] = [:]
    private var pagePreviewObservation: AnyCancellable?
    weak var documentPreviewCache: DocumentPreviewCache? {
        didSet {
            pagePreviewObservation = documentPreviewCache?.$contentRevision.dropFirst().sink { [weak self] _ in
                guard let self else { return }
                self.setPageReferences(self.pageRecords)
            }
        }
    }
    var preparesInteractivePresentation = true
    var isStandbyRuntime = false
    var openingTiming: PennedDocumentOpeningTiming?
    var openingTrace: PennedDocumentOpenTrace? { openingTiming?.trace }
    private var openingLoadTrace: PennedDocumentOpenTrace?
    private var openingFrameTrace: PennedDocumentOpenTrace?
    private var openingWebTrace: (generation: Int, trace: PennedDocumentOpenTrace)?
    private lazy var openingSessionID = UUID()
    private var openingDiagnosticStates: [String: String] = [:]
    #if DEBUG && os(iOS)
    private var openingVisibilityRequested = false
    #endif
    #if os(iOS)
    private var pasteRequestID = 0
    #endif
    private var observedInteractionEnabled = false
    var presentationDiagnostics: String {
        "generation=\(presentation.generation) webPrepared=\(presentation.webPrepared) contentReady=\(presentation.isContentReady) snapshotPending=\(confirmingFrameGeneration != nil) nativePending=\(pendingNativePresentationHeights.count)"
    }
    @Published var saveState: TipTapSaveState = .idle
    @Published var bridgeErrorMessage: String?
    @Published var editorContentHeight: CGFloat = 320
    @Published var editorVisualContentBottom: CGFloat = 320
    @Published var selectedBlockCount = 0
    @Published var selectionMode = "off"
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    #if os(iOS)
    @Published private(set) var selectedCollectionBlockIDs: Set<String> = []
    let blockSelectionDragUpdates = PassthroughSubject<MobileBlockSelectionDrag, Never>()
    #endif
    @Published var isEditing = false
    @Published private(set) var formattingState = TipTapFormattingState()
    @Published private(set) var textConversionState = TipTapTextConversionState()
    @Published private(set) var isConvertingSelectedText = false
    private(set) var caretUpdate: TipTapCaretUpdate?
    let caretUpdates = PassthroughSubject<TipTapCaretUpdate?, Never>()
    @Published var slashMenuState: TipTapSlashMenuState?
    @Published var tagRequest: InlineTagRequest?
    @Published var pageBreakRegions: [TipTapPageBreakRegion] = []
    @Published private(set) var collectionRegions: [TipTapCollectionRegion] = []
    @Published private(set) var renderedDocumentID: String?
    @Published private(set) var placeholderMode = false
    @Published private(set) var templateEditing = false
    private var editingContext: (documentID: String, templateID: String?)?
    private(set) var editingEnabled = true

    var onEvent: ((TipTapEditorEvent) -> Void)?
    // Duplicated/pasted page cards ask the owner to clone their page into an
    // independent copy; pairs carry {blockId, sourceDocumentID}.
    var onClonePageReferences: (([[String: String]]) -> Void)?
    var onBlockDropTransfer: (([String: Any]) async throws -> Void)?
    var onValidateBlockDrop: ((String, [String]) async -> Bool)?
    #if os(iOS)
    weak var blockDragGesture: MobileBlockDragGesture?
    let blockReorderDidLift = PassthroughSubject<Void, Never>()

    func recordBlockDrag(_ event: String, token: String, details: String = "") {
        logger.notice("[Penned Drag] ts=\(Int(Date().timeIntervalSince1970 * 1000)) document=\(self.loadedDocumentID ?? "-", privacy: .public) token=\(token, privacy: .public) event=\(event, privacy: .public) \(details, privacy: .public)")
    }
    #endif
    var ownsEditorPresentation: (() -> Bool)?
    var isReturningFromDocument = false
    var acceptsEditorPresentationRequests: Bool {
        isReady && !isLoadingDocument && loadedDocumentID != nil && !isReturningFromDocument &&
            ownsEditorPresentation?() == true
    }
    var documentForRecovery: (() -> (id: String, json: String)?)?

    private weak var webView: WKWebView?
    var tagNavigationWebView: WKWebView? { webView }
    #if os(iOS)
    lazy var renderRecovery = TipTapRenderRecovery(session: self)
    var renderingDocumentID: String? { loadedDocumentID ?? pendingDocument?.id ?? recoveryDocument?.id }
    #endif
    private var loadedDocumentID: String?
    private var pendingDocument: (id: String, json: String)?
    private var recoveryDocument: (id: String, json: String)?
    private var preservesRecoveryPayload = false
    private var loadGeneration = 0
    private var textColorContext: (token: String, documentID: String, generation: Int)?
    private var pendingAppearance: DocumentAppearance?
    private var awaitingRenderedDocumentID: String?
    private var registeredIconAssets = Set<String>()
    private var pageRecords: [DocumentRecord] = []
    private var collectionPayloads: [[String: Any]] = []
    var attachmentStore: AttachmentStore?
    var attachmentResolver: ((String, String) throws -> [EditorAttachment])?
    private(set) var attachmentFiles: [EditorAttachment] = []
    private(set) var attachmentGeneration = 0
    private var attachmentDocumentID: String?
    private var pageReferencePayload: [[String: Any]] = []
    private let logger = Logger(subsystem: "im.lystaria.Vellix", category: "TipTapBridge")
    private var startupStartTime: CFAbsoluteTime?

    #if DEBUG && os(iOS)
    var keyboardTraceState: String {
        let document = PennedKeyboardTrace.documentToken(loadedDocumentID ?? pendingDocument?.id ?? editingContext?.documentID)
        let mode = ["off", "single", "multi"].contains(selectionMode) ? selectionMode : "other"
        return "doc=\(document) gen=\(loadGeneration) editing=\(isEditing) editable=\(editingEnabled) ready=\(isReady) loading=\(isLoadingDocument) presented=\(isPresentationReady) mode=\(mode) blocks=\(selectedBlockCount)"
    }
    #endif

    private func startupElapsedMS() -> Int {
        guard let startupStartTime else { return -1 }
        return Int((CFAbsoluteTimeGetCurrent() - startupStartTime) * 1000)
    }

    func beginOpening(_ timing: PennedDocumentOpeningTiming) {
        timing.trace?.event("session-opening-start",
            "previousLoadRequest=\(openingLoadTrace?.requestID?.uuidString ?? "-") frameProducerRequest=\(openingFrameTrace?.requestID?.uuidString ?? "-") \(openingReadinessState(for: timing.trace?.documentID ?? ""))")
        openingDiagnosticStates.removeAll(keepingCapacity: true)
        #if DEBUG && os(iOS)
        openingVisibilityRequested = false
        #endif
        openingTiming = timing
        observedInteractionEnabled = false
    }

    func openingReadinessState(for documentID: String) -> String {
        let bounds = webView?.bounds
        return "session=\(openingSessionID) bridgeReady=\(isReady) loading=\(isLoadingDocument) hasLoadedDocument=\(hasLoadedDocument(documentID)) presentationReady=\(isPresentationReady) bridgeErrorMessage=\(bridgeErrorMessage == nil ? "none" : "present") loadedDocument=\(loadedDocumentID ?? "-") queuedDocument=\(pendingDocument?.id ?? "-") renderedDocument=\(renderedDocumentID ?? "-") loadGeneration=\(loadGeneration) presentationGeneration=\(presentation.generation) interactive=\(preparesInteractivePresentation) taskInFlight=\(presentationTask != nil) webPrepared=\(presentation.webPrepared) contentReady=\(presentation.isContentReady) inputRevision=\(presentationInputsRevision) preparedInputRevision=\(preparedInputsRevision.map { String($0) } ?? "-") webView=\(webView != nil) bounds=\(bounds.map { "\($0.width)x\($0.height)" } ?? "-") boundsNonzero=\((bounds?.width ?? 0) > 0 && (bounds?.height ?? 0) > 0) snapshotGeneration=\(confirmingFrameGeneration.map { String($0) } ?? "-") nativeResizes=\(pendingNativePresentationHeights.count) frameProducerRequest=\(openingFrameTrace?.requestID?.uuidString ?? "-")"
    }

    private func openingStateOnce(_ event: String, key: String, _ fields: @autoclosure () -> String) {
        guard let trace = openingTrace, openingDiagnosticStates[event] != key else { return }
        openingDiagnosticStates[event] = key
        trace.event(event, fields())
    }

    #if DEBUG && os(iOS)
    func traceOpeningSurface(eligible: Bool) {
        openingVisibilityRequested = eligible
        guard eligible, let trace = openingTrace else { return }
        trace.event("editor-surface-eligible", openingReadinessState(for: trace.documentID))
        // Read the UIKit host after the SwiftUI visibility update, without forcing layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.openingTrace?.requestID == trace.requestID else { return }
            self.traceOpeningContentVisibility()
        }
    }

    private func traceOpeningContentVisibility() {
        guard openingVisibilityRequested, let trace = openingTrace,
              openingDiagnosticStates["editor-content-visible"] == nil else { return }
        let rendered = renderedDocumentID == trace.documentID
        guard isPresentationReady, rendered, let webView, let window = webView.window else {
            openingStateOnce("editor-content-visibility-blocked", key: "\(isPresentationReady):\(rendered):\(webView?.window != nil)",
                             "renderedMatches=\(rendered) hasWindow=\(webView?.window != nil) \(openingReadinessState(for: trace.documentID))")
            return
        }
        var ancestor: UIView? = webView
        var hidden = false
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 || (view.layer.presentation()?.opacity ?? 1) <= 0.01 {
                hidden = true
                break
            }
            ancestor = view.superview
        }
        let intersectsWindow = !webView.bounds.isEmpty && webView.convert(webView.bounds, to: window).intersects(window.bounds)
        if !hidden && intersectsWindow {
            openingStateOnce("editor-content-visible", key: "visible", "evidence=ready-matching-rendered-document-in-visible-window \(openingReadinessState(for: trace.documentID))")
        } else {
            openingStateOnce("editor-content-visibility-blocked", key: "\(hidden):\(intersectsWindow)",
                             "hiddenAncestor=\(hidden) intersectsWindow=\(intersectsWindow) \(openingReadinessState(for: trace.documentID))")
        }
    }
    #endif

    func noteInteractivePresentation() {
        observedInteractionEnabled = true
        openingTiming?.mark("interaction-enabled")
    }

    func attach(webView: WKWebView) {
        guard self.webView !== webView else {
            logger.info("🧭 TRACE TipTapEditorSession.attach ignored same webView")
            return
        }

        #if DEBUG && os(iOS)
        PennedKeyboardTrace.record("session.attach", session: self, webView: webView,
            "previousWK=\(PennedKeyboardTrace.identity(self.webView))", live: true)
        #endif
        startupStartTime = CFAbsoluteTimeGetCurrent()
        logger.info("⏱️ STARTUP +0ms session attach new webView pending=\(self.pendingDocument?.id ?? "nil", privacy: .public)")
        self.webView = webView
        formattingState = TipTapFormattingState()
        resetPresentation(documentID: pendingDocument?.id)
        isReady = false
        loadedDocumentID = nil
        renderedDocumentID = nil
        pageBreakRegions = []
        collectionRegions = []
        registeredIconAssets.removeAll()
        if let pendingDocument {
            load(documentID: pendingDocument.id, canonicalJSON: pendingDocument.json, force: true)
        }
    }

    func detach(webView: WKWebView) {
        guard self.webView === webView else {
            logger.info("🧭 TRACE TipTapEditorSession.detach ignored stale webView")
            return
        }

        #if DEBUG && os(iOS)
        PennedKeyboardTrace.record("session.detach", session: self, webView: webView, live: true)
        #endif
        logger.info("🧭 TRACE TipTapEditorSession.detach active webView")
        pauseAttachmentPlayback()
        self.webView = nil
        formattingState = TipTapFormattingState()
        resetPresentation(documentID: nil)
        collectionRegions = []
        isReady = false
        loadedDocumentID = nil
        awaitingRenderedDocumentID = nil
        registeredIconAssets.removeAll()
    }

    func markNavigationStarted() {
        openingTrace?.event("web-navigation-reset", openingReadinessState(for: openingTrace?.documentID ?? ""))
        #if DEBUG && os(iOS)
        PennedKeyboardTrace.record("session.navigationReset", session: self, live: true)
        #endif
        // A retained WKWebView can navigate again after its content process exits.
        // Requeue the model's latest text before clearing the old bridge state.
        preservesRecoveryPayload = preservesRecoveryPayload || loadedDocumentID != nil
        pendingDocument = documentForRecovery?() ?? pendingDocument ?? recoveryDocument
        loadGeneration += 1
        slashMenuState = nil
        tagRequest = nil
        formattingState = TipTapFormattingState()
        resetPresentation(documentID: pendingDocument?.id ?? loadedDocumentID)
        logger.info("🧭 TRACE TipTapEditorSession.markNavigationStarted")
        isReady = false
        isLoadingDocument = pendingDocument != nil
        loadedDocumentID = nil
        renderedDocumentID = nil
        awaitingRenderedDocumentID = nil
        pageBreakRegions = []
        collectionRegions = []
        setCaretUpdate(nil)
        registeredIconAssets.removeAll()
    }

    func load(documentID: String, canonicalJSON: String, force: Bool = false) {
        if editingContext?.documentID != documentID {
            configureDocumentContext(documentID: documentID, templateID: nil)
        }
        // SwiftUI checks this on every WebView update; no-op checks must not publish state or send bridge commands.
        if !force {
            if isReady, webView != nil, loadedDocumentID == documentID {
                if openingTrace != nil {
                    openingStateOnce("load-no-op", key: "loaded:\(loadGeneration):\(bridgeErrorMessage != nil)",
                                     "reason=same-loaded-document \(openingReadinessState(for: documentID))")
                }
                return
            }
            if (!isReady || webView == nil), let pendingDocument, pendingDocument.id == documentID,
               pendingDocument.json == canonicalJSON || preservesRecoveryPayload {
                if openingTrace != nil {
                    openingStateOnce("load-no-op", key: "queued:\(loadGeneration)",
                                     "reason=same-queued-document preservesRecovery=\(preservesRecoveryPayload) \(openingReadinessState(for: documentID))")
                }
                return
            }
        }
        #if DEBUG && os(iOS)
        PennedKeyboardTrace.record("session.load", session: self,
            "targetDoc=\(PennedKeyboardTrace.documentToken(documentID)) force=\(force)", live: true)
        #endif
        if PennedSyncTrace.documentID == documentID {
            PennedSyncTrace.record("editor.load", "force=\(force) ready=\(isReady) \(PennedSyncTrace.body(canonicalJSON))")
        }
        preservesRecoveryPayload = false
        loadGeneration += 1
        let generation = loadGeneration
        let openTrace = openingTrace
        openingLoadTrace = openTrace
        let loadStarted = openTrace?.event("editor-load-start", "force=\(force) \(openingReadinessState(for: documentID))")
        openingTiming?.mark("load-start", route: isReady ? "bridge-ready" : "bridge-starting")
        recoveryDocument = (documentID, canonicalJSON)
        tagRequest = nil
        logger.info("📄 TRACE load request id=\(documentID, privacy: .public) ready=\(self.isReady) force=\(force) loaded=\(self.loadedDocumentID ?? "nil", privacy: .public) bytes=\(canonicalJSON.count)")
        guard isReady, webView != nil else {
            formattingState = TipTapFormattingState()
            logger.info("📄 TRACE load queued id=\(documentID, privacy: .public)")
            pendingDocument = (documentID, canonicalJSON)
            isLoadingDocument = true
            resetPresentation(documentID: documentID)
            awaitingRenderedDocumentID = documentID
            setRenderedDocumentID(nil)
            openTrace?.event("editor-load-queued", openingReadinessState(for: documentID), since: loadStarted)
            return
        }

        logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms load sending id=\(documentID, privacy: .public)")
        logger.info("✨ TRACE CALLOUT native-load-before-setContent id=\(documentID, privacy: .public) callouts=\(self.calloutTraceSummary(fromCanonicalJSON: canonicalJSON), privacy: .public)")
        isLoadingDocument = true
        formattingState = TipTapFormattingState()
        resetPresentation(documentID: documentID)
        collectionRegions = []
        setCaretUpdate(nil)
        pendingDocument = nil
        loadedDocumentID = documentID
        awaitingRenderedDocumentID = documentID
        setRenderedDocumentID(nil)
        refreshAttachments(documentID: documentID, json: canonicalJSON)
        openingTiming?.mark("attachments-resolved")
        logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms icon registration start")
        let iconsStarted = openTrace?.event("load-icon-registration-start")
        registerIconAssets(editorIconNames(fromCanonicalJSON: canonicalJSON)) { [weak self] in
            guard let self, self.loadGeneration == generation, self.isReady else {
                openTrace?.event("load-callback-discarded", "callback=icon-registration expectedGeneration=\(generation) actualGeneration=\(self?.loadGeneration ?? -1) sessionAlive=\(self != nil) bridgeReady=\(self?.isReady == true)", since: iconsStarted)
                return
            }
            openTrace?.event("load-icon-registration-completed", since: iconsStarted)
            self.openingTiming?.mark("document-icons-registered")
            self.logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms icon registration complete")
            self.logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms setContent send")
            let contentStarted = openTrace?.event("set-content-start", self.openingReadinessState(for: documentID))
            var command = TipTapEditorCommand.loadDocument(canonicalJSON: canonicalJSON)
            if openTrace != nil { command.args["openingLoadDiagnosticGeneration"] = generation }
            self.send(command) { [weak self] result in
                guard let self, self.loadGeneration == generation, self.isReady else {
                    openTrace?.event("load-callback-discarded", "callback=set-content expectedGeneration=\(generation) actualGeneration=\(self?.loadGeneration ?? -1) sessionAlive=\(self != nil) bridgeReady=\(self?.isReady == true)", since: contentStarted)
                    return
                }
                self.logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms setContent completion")
                if case .failure(let error) = result {
                    openTrace?.event("set-content-failed", "error=\(PennedDocumentOpenTrace.errorCode(error))", since: contentStarted)
                    self.finishDocumentLoad(result, generation: generation, trace: openTrace, started: loadStarted)
                    return
                }
                openTrace?.event("set-content-acknowledged", "generation=\(generation)", since: contentStarted)
                // setContent resets TipTap's selection mode/editability. Restore the
                // native lock state before exposing the newly loaded document.
                let editableStarted = openTrace?.event("set-editability-start", "enabled=\(self.editingEnabled)")
                self.send(TipTapEditorCommand.setEditable(self.editingEnabled)) { [weak self] result in
                    openTrace?.event("set-editability-completed", "sessionAlive=\(self != nil) expectedGeneration=\(generation) actualGeneration=\(self?.loadGeneration ?? -1)", since: editableStarted)
                    self?.finishDocumentLoad(result, generation: generation, trace: openTrace, started: loadStarted)
                }
            }
        }
    }

    private func finishDocumentLoad(_ result: Result<Void, Error>, generation: Int, trace: PennedDocumentOpenTrace?, started: TimeInterval?) {
        #if DEBUG && os(iOS)
        PennedKeyboardTrace.record("session.loadCompletion", session: self,
            "requestedGen=\(generation) stale=\(loadGeneration != generation || !isReady)")
        #endif
        guard loadGeneration == generation, isReady else {
            trace?.event("load-callback-discarded", "callback=finish-load expectedGeneration=\(generation) actualGeneration=\(loadGeneration) bridgeReady=\(isReady)", since: started)
            logger.info("VELLIX-OPEN finishDocumentLoad SKIP loadGen=\(self.loadGeneration) gen=\(generation) isReady=\(self.isReady)")
            return
        }
        isLoadingDocument = false
        if case .failure(let error) = result {
            pendingDocument = documentForRecovery?() ?? recoveryDocument
            loadedDocumentID = nil
            bridgeErrorMessage = error.localizedDescription
            trace?.event("editor-load-failed", "error=\(PennedDocumentOpenTrace.errorCode(error))", since: started)
            logger.error("VELLIX-OPEN finishDocumentLoad FAIL error=\(error.localizedDescription, privacy: .public)")
            return
        }
        logger.info("VELLIX-OPEN finishDocumentLoad OK docID=\(self.loadedDocumentID ?? "nil", privacy: .public) -> preparePresentation")
        openingTiming?.mark("content-and-editability-acknowledged")
        trace?.event("document-loaded", openingReadinessState(for: trace?.documentID ?? ""), since: started)
        preparePresentation()
    }

    func refreshAttachments(documentID: String, json: String) {
        if attachmentDocumentID != documentID {
            attachmentGeneration += 1
            attachmentDocumentID = documentID
            attachmentFiles = []
        }
        do { attachmentFiles = try attachmentResolver?(documentID, json) ?? [] }
        catch { attachmentFiles = []; attachmentGeneration += 1; bridgeErrorMessage = error.localizedDescription }
        if isReady { send(TipTapEditorCommand("setAttachments", args: ["files": attachmentFiles.map(\.object)])) }
    }

    func pauseAttachmentPlayback() {
        if isReady { send(TipTapEditorCommand("attachmentPauseAll")) }
    }

    func finishAttachmentClipboard(token: String, success: Bool) {
        send(TipTapEditorCommand("attachmentClipboardResult", args: ["token": token, "success": success]))
    }

    func attachmentCommand(_ name: String, args: [String: Any] = [:]) async throws -> Any? {
        guard isReady, let webView else { throw VellixError.editorBridge("The editor is not ready.") }
        return try await webView.callAsyncJavaScript("return window.tiptapCommand(name, args);",
            arguments: ["name": name, "args": args], in: nil, contentWorld: .page)
    }

    func tagCommand(_ name: String, args: [String: Any] = [:]) async throws -> Any? {
        guard isReady, let webView else { throw VellixError.editorBridge("The editor is not ready.") }
        return try await webView.callAsyncJavaScript("return window.tiptapCommand(name, args);",
            arguments: ["name": name, "args": args], in: nil, contentWorld: .page)
    }

    func requestSnapshot() {
        send(TipTapEditorCommand.requestSnapshot())
    }

    func taskCommand(_ name: String, context: DocumentTaskContext, values: [String: Any] = [:]) {
        var args = values
        args["blockId"] = context.blockID
        if let task = context.metadata { args["taskID"] = task.id }
        send(TipTapEditorCommand(name, args: args))
    }

    func refreshTaskHistory(_ json: String) {
        send(TipTapEditorCommand("taskHistoryRefresh", args: ["document": TipTapContentAnalyzer.documentObject(from: json)]))
    }

    func configureTask(_ context: DocumentTaskContext, configuration: [String: Any]) async throws {
        guard isReady, let webView, let task = context.metadata else { throw DocumentTaskError.missingTask }
        let args: [String: Any] = ["blockId": context.blockID, "taskID": task.id, "configuration": configuration]
        let result = try await webView.callAsyncJavaScript("return await window.tiptapCommand('taskConfigure', args);",
            arguments: ["args": args], in: nil, contentWorld: .page)
        guard result as? Bool == true else { throw DocumentTaskError.missingTask }
    }

    func configureDocumentContext(documentID: String, templateID: String?) {
        if editingContext?.documentID != documentID || editingContext?.templateID != templateID {
            placeholderMode = false
        }
        editingContext = (documentID, templateID)
        templateEditing = templateID != nil
        if !templateEditing { placeholderMode = false }
        guard isReady else { return }
        send(TipTapEditorCommand("setTemplateEditing", args: ["enabled": templateEditing,
            "documentID": documentID, "templateID": templateID.map { $0 as Any } ?? NSNull(), "placeholderMode": placeholderMode]))
    }

    func togglePlaceholderMode() {
        guard templateEditing, isReady, !isLoadingDocument, editingEnabled else { return }
        placeholderMode.toggle()
        send(TipTapEditorCommand("setPlaceholderMode", args: ["active": placeholderMode]))
    }

    func placeholderAction(_ action: String, token: String? = nil) {
        guard templateEditing, placeholderMode, isReady, !isLoadingDocument, editingEnabled else { return }
        var args: [String: Any] = ["action": action]
        if let token { args["token"] = token }
        send(TipTapEditorCommand("placeholderAction", args: args))
    }

    func tableAction(_ action: String, tableID: String? = nil, values: [String: Any] = [:]) {
        var args = values
        args["action"] = action
        if let tableID { args["tableID"] = tableID }
        send(TipTapEditorCommand("tableAction", args: args))
    }

    func saveTemplateComponent(_ definition: TemplateComponentDefinition, blockID: String?) {
        guard templateEditing else { return }
        var args: [String: Any] = ["definition": definition.object]
        if let blockID { args["blockID"] = blockID }
        send(TipTapEditorCommand("templateComponentSave", args: args))
    }

    func templateComponentAction(_ action: String, blockID: String, direction: Int = 0) {
        guard templateEditing else { return }
        send(TipTapEditorCommand("templateComponent" + action, args: ["blockID": blockID, "direction": direction]))
    }

    func cancelPlaceholderConversion() {
        send(TipTapEditorCommand("cancelPlaceholderConversion"))
        if placeholderMode { togglePlaceholderMode() }
    }

    func hasLoadedDocument(_ documentID: String) -> Bool {
        isReady && !isLoadingDocument && loadedDocumentID == documentID && bridgeErrorMessage == nil
    }

    func resumeRetainedPresentation(for documentID: String) {
        // A loaded editor can retain an error from a prior operation. Retry
        // presentation without re-injecting JSON over its live document.
        guard isReady, !isLoadingDocument, loadedDocumentID == documentID, webView != nil,
              bridgeErrorMessage != nil else { return }
        openingTrace?.event("retained-presentation-error-cleared", openingReadinessState(for: documentID))
        bridgeErrorMessage = nil
        if !isPresentationReady {
            if presentation.isContentReady, preparedInputsRevision == presentationInputsRevision {
                confirmPresentationIfReady()
            } else {
                preparePresentation()
            }
        }
    }

    func currentJSON(suspendingEditing: Bool = false, preservingBlockSelection: Bool = false,
                     file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) async throws -> String? {
        guard isReady, !isLoadingDocument, let loadedDocumentID, let webView else { return nil }
        let generation = loadGeneration
        #if DEBUG && os(iOS)
        let trace = PennedKeyboardTrace.record("bridge.snapshot.begin", session: self, webView: webView,
            "suspend=\(suspendingEditing) preserveSelection=\(preservingBlockSelection) at=\(file):\(line) \(function)",
            live: suspendingEditing)
        var bridgeReturned = false
        defer {
            if let trace {
                PennedKeyboardTrace.record("bridge.snapshot.end", session: self, webView: webView,
                    "sent_seq=\(trace) returned=\(bridgeReturned) requestGen=\(generation)")
            }
        }
        #endif
        let result = try await webView.callAsyncJavaScript("if (suspend) await window.tiptapCommand('setEditable', {editable: false, preservingBlockSelection}); return await window.tiptapCommand('getDocument', {});",
            arguments: ["suspend": suspendingEditing, "preservingBlockSelection": preservingBlockSelection], in: nil, contentWorld: .page)
        #if DEBUG && os(iOS)
        bridgeReturned = true
        #endif
        guard loadGeneration == generation, isReady, !isLoadingDocument else { return nil }
        let json = try TipTapContentAnalyzer.normalizePayloadToJSON(result)
        recoveryDocument = (loadedDocumentID, json)
        return json
    }

    func focus(file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        send(TipTapEditorCommand.focusEditor(), file: file, line: line, function: function)
    }

    func blur(file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        send(TipTapEditorCommand("blur"), file: file, line: line, function: function)
    }
    /// Resign the actual WKWebView editing responder before presenting a
    /// native sheet. A JS blur alone does not reliably dismiss WKContentView's
    /// software keyboard when WebKit is processing a long-press.
    func endWebEditingForSettings(file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        #if os(iOS)
        #if DEBUG
        PennedKeyboardTrace.record("ui.endEditing", session: self,
            "action=WKWebView.endEditing+resignFirstResponder at=\(file):\(line) \(function)", live: true)
        #endif
        webView?.endEditing(true)
        webView?.resignFirstResponder()
        #elseif os(macOS)
        webView?.window?.makeFirstResponder(nil)
        #endif
    }


    func focusDocumentEnd(file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        send(TipTapEditorCommand.focusDocumentEnd(), file: file, line: line, function: function)
    }

    func requestCaretVisibility() {
        guard isReady, isEditing, !isLoadingDocument else { return }
        send(TipTapEditorCommand("reportCaret"))
    }

    private func setCaretUpdate(_ update: TipTapCaretUpdate?) {
        // Caret events should not rebuild the WKWebView on every keystroke.
        caretUpdate = update
        caretUpdates.send(update)
    }

    func setEditable(_ editable: Bool, preservingBlockSelection: Bool = false,
                     file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        editingEnabled = editable
        if !editable && (!preservingBlockSelection || selectionMode == "off") { textConversionState = TipTapTextConversionState() }
        send(TipTapEditorCommand.setEditable(editable, preservingBlockSelection: preservingBlockSelection),
             file: file, line: line, function: function)
    }

    func setTheme(_ theme: String) {
        send(TipTapEditorCommand.setTheme(theme))
    }

    func setAppearance(_ appearance: DocumentAppearance) {
        currentAppearance = appearance
        setPageReferences(pageRecords)
        if stagePresentationInputChange() { return }
        guard isReady, webView != nil else {
            logger.info("🎨 TRACE setAppearance queued ready=\(self.isReady)")
            pendingAppearance = appearance
            return
        }

        logger.info("🎨 TRACE setAppearance send text=\(appearance.textColorHex, privacy: .public) font=\(appearance.fontStyle.cssFamily, privacy: .public)")
        pendingAppearance = nil
        send(TipTapEditorCommand.setAppearance(appearance.resolved(for: applicationColorScheme), interfaceScheme: applicationColorScheme)) { [weak self] _ in self?.preparePresentation() }
    }

    func setApplicationColorScheme(_ scheme: ColorScheme) {
        guard applicationColorScheme != scheme else { return }
        applicationColorScheme = scheme
        if let currentAppearance { setAppearance(currentAppearance) }
        else { setPageReferences(pageRecords) }
    }

    func setPageReferences(_ records: [DocumentRecord]) {
        let font: DocumentFontStyle? = currentAppearance?.fontStyle == .hachiMaruPop ? .hachiMaruPop : nil
        let keys = Dictionary(uniqueKeysWithValues: records.map { ($0.id, documentPreviewCache?.cardPresentationKey(for: $0, colorScheme: applicationColorScheme) ?? "") })
        guard records != pageRecords || keys != pageReferenceSnapshotKeys || pageReferenceColorScheme != applicationColorScheme || pageReferenceFontStyle != font else { return }
        let schemeChanged = pageReferenceColorScheme != applicationColorScheme
        let fontChanged = pageReferenceFontStyle != font
        pageReferenceColorScheme = applicationColorScheme
        pageReferenceFontStyle = font
        let previous = Dictionary(uniqueKeysWithValues: pageRecords.map { ($0.id, $0) })
        let presentations = Dictionary(uniqueKeysWithValues: pageReferencePayload.compactMap { payload -> (String, [String: Any])? in
            guard let id = payload["documentID"] as? String else { return nil }
            return (id, payload)
        })
        pageReferencePayload = records.map { record in
            if previous[record.id] == record, keys[record.id] == pageReferenceSnapshotKeys[record.id], !fontChanged, !(schemeChanged && record.appearance.isThemeDependent), let cached = presentations[record.id] { return cached }
            return PageReferencePresentation.bridgeObject(record, attachmentStore: attachmentStore, colorScheme: applicationColorScheme, containingFontStyle: font, previews: documentPreviewCache)
        }
        pageReferenceSnapshotKeys = keys
        pageRecords = records
        if !stagePresentationInputChange(), isReady { sendPageReferences() }
    }

    private var stagesInitialPresentation: Bool {
        preparesInteractivePresentation && !isPresentationReady
    }

    private func stagePresentationInputChange() -> Bool {
        guard stagesInitialPresentation else { return false }
        presentationInputsRevision &+= 1
        if presentation.isContentReady {
            confirmingFrameGeneration = nil
            preparePresentation()
        }
        return true
    }

    private func sendPageReferences() {
        send(TipTapEditorCommand("setPageReferences", args: ["pages": pageReferencePayload])) { [weak self] _ in self?.preparePresentation() }
    }

    func setCollections(_ payloads: [[String: Any]], preparingForDisplay: Bool = false) {
        // Do NOT tear down an editor whose live content is already presentation-ready.
        // The visible viewport is refreshed separately on return; readiness is not a
        // guarantee that hidden WebKit tiles remain painted. Re-running the off-screen snapshot
        // "proof of pixels" handshake for a warm model is unnecessary, and it deadlocks on iPad:
        // the editor is still at opacity 0 in the deck during the open (selectedDocumentID only
        // flips once it is marked ready), so takeSnapshot never calls back and the open hangs to
        // the 12s timeout ("This page could not be prepared"). Pushing the updated collections to
        // JS below re-renders the live editor in place, which is all a warm re-show needs.
        _ = preparingForDisplay
        guard !NSArray(array: collectionPayloads).isEqual(to: payloads) else { return }
        collectionPayloads = payloads
        if !stagePresentationInputChange(), isReady { sendCollections() }
    }

    private func sendCollections() {
        let icons = Set(collectionPayloads.flatMap { ($0["fields"] as? [[String: Any]] ?? []).compactMap { $0["icon"] as? String } })
        registerIconAssets(icons) { [weak self] in
            guard let self else { return }
            self.send(TipTapEditorCommand("setCollections", args: ["collections": self.collectionPayloads]))
        }
    }

    func resolveCollection(blockID: String, collectionID: String, documentID: String) async throws {
        guard isReady, let webView else { throw VellixError.editorBridge("The editor is not ready.") }
        let args = ["blockID": blockID, "collectionID": collectionID, "documentID": documentID]
        let result = try await webView.callAsyncJavaScript("return window.tiptapCommand('resolveCollection', args);",
            arguments: ["args": args], in: nil, contentWorld: .page)
        guard result as? Bool == true else { throw VellixError.editorBridge("The collection insertion point no longer exists.") }
    }

    func resizeNativeCollection(blockID: String, viewID: String, height: CGFloat) {
        guard height.isFinite, height >= 120, height <= CGFloat(CollectionViewConfiguration.kanbanMaxHeight) else { return }
        send(TipTapEditorCommand("setNativeCollectionHeight", args: ["blockID": blockID, "viewID": viewID, "height": height]))
    }

    func nativeCollectionDidLayout(blockID: String, viewID: String, height: CGFloat, needsResize: Bool) {
        if openingTrace != nil, !isPresentationReady {
            openingStateOnce("native-collection-layout", key: "\(presentation.generation):\(needsResize)",
                             "needsResize=\(needsResize) requiredForReadiness=false \(openingReadinessState(for: openingTrace?.documentID ?? ""))")
        }
        if needsResize {
            pendingNativePresentationHeights[blockID] = (viewID, height)
            resizeNativeCollection(blockID: blockID, viewID: viewID, height: height)
            return
        }
        presentation.nativeDidLayout(blockID: blockID, viewID: viewID)
        confirmPresentationIfReady()
    }

    private func confirmPresentationIfReady() {
        logger.info("VELLIX-OPEN confirm contentReady=\(self.presentation.isContentReady) nativePending=\(self.pendingNativePresentationHeights.count) bounds=\(self.webView.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "nil") presReady=\(self.isPresentationReady)")
        guard !isPresentationReady, presentation.isContentReady, preparedInputsRevision == presentationInputsRevision,
              let webView, webView.bounds.width > 0, webView.bounds.height > 0 else {
            if let trace = openingTrace, !isPresentationReady {
                let hasBounds = (self.webView?.bounds.width ?? 0) > 0 && (self.webView?.bounds.height ?? 0) > 0
                let reason = !presentation.isContentReady ? "javascript-layout-not-ready" :
                    preparedInputsRevision != presentationInputsRevision ? "input-revision-mismatch" :
                    self.webView == nil ? "webview-unattached" : "webview-bounds-zero"
                openingStateOnce("frame-check-blocked",
                                 key: "\(presentation.generation):\(presentation.isContentReady):\(preparedInputsRevision == presentationInputsRevision):\(self.webView != nil):\(hasBounds)",
                                 "reason=\(reason) fallbackArmedForCurrentGeneration=\(confirmingFrameGeneration == presentation.generation) \(openingReadinessState(for: trace.documentID))")
            }
            return
        }
        let generation = presentation.generation
        guard confirmingFrameGeneration != generation else {
            if openingTrace != nil {
                openingStateOnce("frame-check-in-flight", key: String(generation), "generation=\(generation)")
            }
            return
        }
        confirmingFrameGeneration = generation
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: min(240, webView.bounds.height))
        configuration.snapshotWidth = NSNumber(value: Double(min(160, webView.bounds.width)))
        configuration.afterScreenUpdates = true
        openingTiming?.mark("frame-check-start")
        let trace = openingTrace
        let started = trace?.event("snapshot-start", "afterScreenUpdates=true \(openingReadinessState(for: trace?.documentID ?? ""))")
        // A JS layout frame is not proof that WebKit has produced displayable pixels.
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            trace?.event("snapshot-returned", "imageAvailable=\(image != nil) error=\(PennedDocumentOpenTrace.errorCode(error))", since: started)
            guard let self, self.presentation.generation == generation, self.confirmingFrameGeneration == generation else {
                trace?.event("frame-callback-discarded", "callback=snapshot sessionAlive=\(self != nil) expectedGeneration=\(generation) actualGeneration=\(self?.presentation.generation ?? -1) confirmingGeneration=\(self?.confirmingFrameGeneration ?? -1)", since: started)
                return
            }
            self.logger.info("VELLIX-OPEN snapshot RETURNED image=\(image != nil) error=\(error?.localizedDescription ?? "none", privacy: .public)")
            guard image != nil else {
                // The web layout and bounds already passed. Let the existing fallback
                // confirm this generation even if WebKit returns no image.
                trace?.event("snapshot-unavailable", "reason=\(error == nil ? "no-image" : "webkit-error") fallbackArmed=true", since: started)
                return
            }
            self.confirmingFrameGeneration = nil
            self.presentation.framePresented(generation: generation)
            self.openingFrameTrace = trace
            self.isPresentationReady = self.presentation.isReady
            trace?.event("frame-confirmed", "route=snapshot currentOpeningRequest=\(self.openingTrace?.requestID?.uuidString ?? "-") \(self.openingReadinessState(for: trace?.documentID ?? ""))", since: started)
            self.openingTiming?.mark("presentation-ready", route: "snapshot")
            if self.preparesInteractivePresentation, self.isPresentationReady { self.noteInteractivePresentation() }
        }
        // WKWebView.takeSnapshot(afterScreenUpdates:) can silently never call back when the
        // web view isn't on-screen yet (it is still at opacity 0 in the editor deck while it
        // prepares). Don't let that hang the open: the JS layout frame already confirms the
        // content is laid out, so present anyway if the snapshot hasn't returned promptly.
        let armed = trace?.event("layout-fallback-armed", "delayMS=750 generation=\(generation)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            trace?.event("layout-fallback-fired", "generation=\(generation)", since: armed)
            guard let self, self.confirmingFrameGeneration == generation,
                  self.presentation.generation == generation, !self.isPresentationReady,
                  self.presentation.isContentReady else {
                trace?.event("layout-fallback-skipped", "sessionAlive=\(self != nil) expectedGeneration=\(generation) actualGeneration=\(self?.presentation.generation ?? -1) confirmingGeneration=\(self?.confirmingFrameGeneration ?? -1) alreadyReady=\(self?.isPresentationReady == true) contentReady=\(self?.presentation.isContentReady == true)", since: armed)
                return
            }
            self.confirmingFrameGeneration = nil
            self.presentation.framePresented(generation: generation)
            self.openingFrameTrace = trace
            self.isPresentationReady = self.presentation.isReady
            trace?.event("frame-confirmed", "route=layout-fallback currentOpeningRequest=\(self.openingTrace?.requestID?.uuidString ?? "-") \(self.openingReadinessState(for: trace?.documentID ?? ""))", since: started)
            self.openingTiming?.mark("presentation-ready", route: "layout-fallback")
            if self.preparesInteractivePresentation, self.isPresentationReady { self.noteInteractivePresentation() }
        }
    }

    func editorDidLayout() {
        if let trace = openingTrace, !isPresentationReady {
            let hasBounds = (webView?.bounds.width ?? 0) > 0 && (webView?.bounds.height ?? 0) > 0
            openingStateOnce("native-webview-layout", key: "\(presentation.generation):\(hasBounds)", openingReadinessState(for: trace.documentID))
        }
        confirmPresentationIfReady()
        #if DEBUG && os(iOS)
        traceOpeningContentVisibility()
        #endif
    }

    private func resetPresentation(documentID: String?) {
        openingTrace?.event("presentation-reset", "target=\(documentID ?? "-") generation=\(presentation.generation) cancelsPreparation=\(presentationTask != nil)")
        openingFrameTrace = nil
        canUndo = false
        canRedo = false
        textConversionState = TipTapTextConversionState()
        isConvertingSelectedText = false
        presentationTask?.cancel()
        presentationTask = nil
        preparedInputsRevision = nil
        confirmingFrameGeneration = nil
        presentation.begin(documentID: documentID)
        pendingNativePresentationHeights = [:]
        isPresentationReady = false
    }

    private func preparePresentation() {
        logger.info("VELLIX-OPEN preparePresentation enter interactive=\(self.preparesInteractivePresentation) isReady=\(self.isReady) loading=\(self.isLoadingDocument) presReady=\(self.isPresentationReady) hasWebView=\(self.webView != nil) docID=\(self.loadedDocumentID ?? "nil", privacy: .public)")
        guard preparesInteractivePresentation, isReady, !isLoadingDocument, !isPresentationReady,
              presentationTask == nil, (!presentation.isContentReady || preparedInputsRevision != presentationInputsRevision),
              let webView, let documentID = loadedDocumentID else {
            if let trace = openingTrace, !isPresentationReady {
                let reason = !preparesInteractivePresentation ? "not-interactive" :
                    !isReady ? "bridge-not-ready" : isLoadingDocument ? "document-loading" :
                    presentationTask != nil ? "preparation-in-flight" :
                    presentation.isContentReady && preparedInputsRevision == presentationInputsRevision ? "inputs-already-prepared" :
                    self.webView == nil ? "webview-unattached" : "loaded-document-missing"
                openingStateOnce("presentation-preparation-blocked",
                                 key: "\(presentation.generation):\(reason)",
                                 "reason=\(reason) \(openingReadinessState(for: trace.documentID))")
            }
            logger.info("VELLIX-OPEN preparePresentation GUARD-FAIL (did not run)")
            return
        }
        let generation = presentation.startPreparation()
        let inputsRevision = presentationInputsRevision
        let trace = openingTrace
        let started = trace?.event("presentation-preparation-start", openingReadinessState(for: documentID))
        openingTiming?.mark("layout-start")
        var args: [String: Any] = ["collections": collectionPayloads, "pages": pageReferencePayload, "files": attachmentFiles.map(\.object),
            "appearance": currentAppearance.map { TipTapEditorCommand.setAppearance($0.resolved(for: applicationColorScheme), interfaceScheme: applicationColorScheme).args } ?? [:]]
        if let trace {
            args["openingDiagnosticGeneration"] = generation
            openingWebTrace = (generation, trace)
        }
        let presentationArgs = args
        let icons = Set(collectionPayloads.flatMap { ($0["fields"] as? [[String: Any]] ?? []).compactMap { $0["icon"] as? String } })
        presentationTask = Task { [weak self, weak webView] in
            guard let self, let webView else {
                trace?.event("presentation-callback-discarded", "callback=task-start sessionAlive=\(self != nil) webViewAlive=\(webView != nil)", since: started)
                return
            }
            let iconsStarted = trace?.event("presentation-icon-registration-start")
            await withCheckedContinuation { continuation in self.registerIconAssets(icons) { continuation.resume() } }
            trace?.event("presentation-icon-registration-completed", since: iconsStarted)
            guard !Task.isCancelled, self.loadedDocumentID == documentID else {
                trace?.event("presentation-callback-discarded", "callback=icon-registration taskCancelled=\(Task.isCancelled) documentMatches=\(self.loadedDocumentID == documentID)", since: started)
                return
            }
            let jsStarted = trace?.event("javascript-presentation-start", "generation=\(generation) inputRevision=\(inputsRevision)")
            do {
                let rawResult = try await webView.callAsyncJavaScript("return await window.tiptapCommand('preparePresentation', args);",
                    arguments: ["args": presentationArgs], in: nil, contentWorld: .page)
                let result = rawResult as? [String: Any] ?? [:]
                trace?.event("javascript-presentation-returned", "generation=\(generation) layoutPayload=\(result["nativeViews"] is [[String: String]]) webMilestones=\(result["openingDiagnostic"] as? Bool == true)", since: jsStarted)
                guard !Task.isCancelled, self.loadedDocumentID == documentID,
                      self.presentation.generation == generation else {
                    trace?.event("presentation-callback-discarded", "callback=javascript taskCancelled=\(Task.isCancelled) documentMatches=\(self.loadedDocumentID == documentID) expectedGeneration=\(generation) actualGeneration=\(self.presentation.generation)", since: jsStarted)
                    return
                }
                self.presentationTask = nil
                if self.presentationInputsRevision != inputsRevision {
                    trace?.event("presentation-inputs-changed", "expectedRevision=\(inputsRevision) actualRevision=\(self.presentationInputsRevision)", since: started)
                    self.preparePresentation()
                    return
                }
                var nativeViews: [String: String] = [:]
                for region in result["nativeViews"] as? [[String: String]] ?? [] {
                    if let block = region["blockID"], let view = region["viewID"] { nativeViews[block] = view }
                }
                self.pendingNativePresentationHeights = self.pendingNativePresentationHeights.filter {
                    nativeViews[$0.key] == $0.value.viewID
                }
                self.preparedInputsRevision = inputsRevision
                self.presentation.prepared(generation: generation, nativeViews: nativeViews)
                self.setRenderedDocumentID(documentID)
                trace?.event("javascript-layout-acknowledged", "nativeRegions=\(nativeViews.count) \(self.openingReadinessState(for: documentID))", since: started)
                self.openingTiming?.mark("layout-ready")
                self.logger.info("VELLIX-OPEN prepared nativeViews=\(nativeViews.count) contentReady=\(self.presentation.isContentReady)")
                self.confirmPresentationIfReady()
            } catch {
                trace?.event("javascript-presentation-failed", "taskCancelled=\(Task.isCancelled) error=\(PennedDocumentOpenTrace.errorCode(error))", since: jsStarted)
                guard !Task.isCancelled else { return }
                self.presentationTask = nil
                self.logger.error("VELLIX-OPEN preparePresentation JS ERROR=\(error.localizedDescription, privacy: .public)")
                self.bridgeErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelCollectionInsertion(_ blockID: String) {
        send(TipTapEditorCommand("resolveCollection", args: ["blockID": blockID, "collectionID": ""]))
    }

    func resolvePageReference(blockID: String, documentID: String?) {
        send(TipTapEditorCommand("resolvePageReference", args: ["blockId": blockID, "documentId": documentID ?? ""]))
    }

    func applyClonedPageReference(blockID: String, documentID: String?) {
        // Like resolvePageReference but never auto-opens the page: used when a
        // duplicated/pasted card is repointed at its freshly cloned copy.
        send(TipTapEditorCommand("applyClonedPageReference", args: ["blockId": blockID, "documentId": documentID ?? ""]))
    }

    func insertDivider(_ style: VellixDividerStyle) {
        send(TipTapEditorCommand.insertDivider(style))
    }

    func insertPageBreak() {
        send(TipTapEditorCommand.insertPageBreak())
    }

    func insertBlock(_ blockType: String) {
        if blockType == "tabs" { print("🧩 TABS SESSION: insertBlock reached, ready=\(isReady), webView=\(webView != nil)") }
        guard !["heading5", "heading6", "toggleHeading5", "toggleHeading6"].contains(blockType) else { return }
        send(TipTapEditorCommand.insertBlock(blockType))
    }

    func setSelectedBlockType(_ blockType: String, level: Int? = nil, color: String? = nil, selectionTarget: String? = nil) {
        guard canApplySelectionStyle(to: selectionTarget),
              !["heading5", "heading6", "toggleHeading5", "toggleHeading6"].contains(blockType) else { return }
        if ["heading", "toggleListItem"].contains(blockType), let level, !(1...4).contains(level) { return }
        send(TipTapEditorCommand.setSelectedBlockType(blockType, level: level, color: color, selectionTarget: selectionTarget))
    }

    func indentSelectedBlocks() {
        send(TipTapEditorCommand.indentSelectedBlocks())
    }

    func outdentSelectedBlocks() {
        send(TipTapEditorCommand.outdentSelectedBlocks())
    }

    func indentPageReference(documentID: String, outdent: Bool = false) {
        send(TipTapEditorCommand("indentPageReference", args: ["documentID": documentID, "outdent": outdent]))
    }

    func setSelectedCalloutColor(_ color: String) {
        send(TipTapEditorCommand.setSelectedCalloutColor(color))
    }

    func formatSelectedBlocks(action: String, value: String? = nil, selectionTarget: String? = nil) {
        guard canApplySelectionStyle(to: selectionTarget) else { return }
        send(TipTapEditorCommand.formatSelectedBlocks(action: action, value: value, selectionTarget: selectionTarget))
    }

    private func canApplySelectionStyle(to target: String?) -> Bool {
        guard let target else { return true }
        return isReady && !isLoadingDocument && editingEnabled && selectionMode != "off"
            && formattingState.selectedBlocksStyle?.target == target
    }

    func toggleTextMark(_ mark: String) {
        send(TipTapEditorCommand.toggleTextMark(mark))
    }

    func formatCurrentSelection(action: String, value: String? = nil) {
        send(TipTapEditorCommand.formatCurrentSelection(action: action, value: value))
    }

    func convertSelectedText(to target: String, token: String) {
        guard isReady, !isLoadingDocument, editingEnabled, selectionMode == "off",
              !isConvertingSelectedText, textConversionState.token == token,
              textConversionState.targets.contains(target), let documentID = loadedDocumentID else { return }
        let generation = loadGeneration
        isConvertingSelectedText = true
        let apply: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { if self.loadGeneration == generation { self.isConvertingSelectedText = false } }
                guard self.loadedDocumentID == documentID, self.loadGeneration == generation,
                      self.isReady, !self.isLoadingDocument, self.editingEnabled,
                      self.selectionMode == "off", self.textConversionState.token == token else { return }
                do {
                    let applied = try await self.attachmentCommand("convertSelectedText",
                        args: ["target": target, "token": token]) as? Bool
                    guard self.loadedDocumentID == documentID, self.loadGeneration == generation else { return }
                    guard applied == true else {
                        self.bridgeErrorMessage = "This text selection cannot be converted to that block type."
                        return
                    }
                    self.requestSnapshot()
                } catch {
                    guard self.loadedDocumentID == documentID, self.loadGeneration == generation else { return }
                    self.bridgeErrorMessage = error.localizedDescription
                }
            }
        }
        apply()
    }

    func cancelBlockConversion() {
        send(TipTapEditorCommand("cancelBlockConversion"))
    }

    func beginLinkEditing(_ mode: DocumentLinkRequest.Mode, blockID: String? = nil) async throws -> DocumentLinkRequest {
        guard let documentID = loadedDocumentID, linkContextIsCurrent(documentID, loadGeneration) else { throw staleLink() }
        let generation = loadGeneration
        var args: [String: Any] = ["mode": mode.rawValue]
        args["blockID"] = blockID
        guard let result = try await attachmentCommand("linksBegin", args: args) as? [String: Any],
              let token = result["token"] as? String, linkContextIsCurrent(documentID, generation) else { throw staleLink() }
        return DocumentLinkRequest(id: token, documentID: documentID, generation: generation, mode: mode,
            href: result["href"] as? String ?? "", existing: result["existing"] as? Bool == true,
            isRich: result["kind"] as? String == "rich")
    }

    func applyLink(_ request: DocumentLinkRequest, url: URL?, kind: LinkInsertionKind, label: String) async throws {
        guard linkContextIsCurrent(request.documentID, request.generation) else { throw staleLink() }
        var args: [String: Any] = ["token": request.id, "remove": url == nil, "kind": kind.rawValue, "label": label]
        if let url {
            args["href"] = url.absoluteString
            if (request.isRich || (request.mode == .insert && kind == .rich)), url.absoluteString != request.href {
                args["metadata"] = try? await fetchLinkMetadata(url, documentID: request.documentID, generation: request.generation)
            }
        }
        guard linkContextIsCurrent(request.documentID, request.generation),
              try await attachmentCommand("linksApply", args: args) as? Bool == true,
              linkContextIsCurrent(request.documentID, request.generation) else { throw staleLink() }
    }

    func endLinkEditing(_ request: DocumentLinkRequest) {
        guard linkContextIsCurrent(request.documentID, request.generation) else { return }
        send(TipTapEditorCommand("linksEnd", args: ["token": request.id]))
    }

    func actOnLink(_ link: SelectedDocumentLink, action: String, layout: RichLinkLayout? = nil) async throws {
        guard let documentID = loadedDocumentID, linkContextIsCurrent(documentID, loadGeneration),
              formattingState.selectedLink?.id == link.id else { throw staleLink() }
        let generation = loadGeneration
        var args: [String: Any] = ["blockID": link.id, "href": link.href, "action": action, "kind": link.isRich ? "rich" : "text"]
        args["layout"] = layout?.rawValue
        if let url = DocumentLinkURL.web(link.href) {
            if action == "reload" {
                guard let metadata = try await fetchLinkMetadata(url, documentID: documentID, generation: generation) else {
                    throw VellixError.editorBridge("The site did not return preview information.")
                }
                args["metadata"] = metadata
            } else if action == "convert" && !link.isRich && !link.hasMetadata {
                args["metadata"] = try? await fetchLinkMetadata(url, documentID: documentID, generation: generation)
            }
        }
        guard linkContextIsCurrent(documentID, generation),
              try await attachmentCommand("linksSelected", args: args) as? Bool == true,
              linkContextIsCurrent(documentID, generation) else { throw staleLink() }
    }

    private func fetchLinkMetadata(_ url: URL, documentID: String, generation: Int) async throws -> [String: Any]? {
        guard let page = try await DocumentLinkMetadataSource.fetch(url) else { return nil }
        guard linkContextIsCurrent(documentID, generation) else { throw staleLink() }
        return try await attachmentCommand("linksMetadata", args: ["html": page.html, "href": page.href]) as? [String: Any]
    }

    private func linkContextIsCurrent(_ documentID: String, _ generation: Int) -> Bool {
        isReady && !isLoadingDocument && editingEnabled && loadedDocumentID == documentID && loadGeneration == generation
    }

    private func staleLink() -> VellixError { .editorBridge("This link selection changed. Select the link or text again.") }

    func beginTextColorEditing() async throws -> InlineTextColorEditorRequest? {
        guard isReady, !isLoadingDocument, editingEnabled, formattingState.hasTextSelection,
              let documentID = loadedDocumentID else { return nil }
        let generation = loadGeneration
        guard let value = try await attachmentCommand("textColorBegin") as? [String: Any],
              let token = value["token"] as? String, let text = value["text"] as? String,
              loadedDocumentID == documentID, loadGeneration == generation, editingEnabled else { return nil }
        textColorContext = (token, documentID, generation)
        return InlineTextColorEditorRequest(id: token, documentID: documentID, selectedText: text,
            initialColor: InlineTextColor.decode(value["style"]))
    }

    func applyTextColor(_ color: InlineTextColor?, request: InlineTextColorEditorRequest) async throws {
        guard textColorContext?.token == request.id, loadedDocumentID == request.documentID,
              textColorContext?.generation == loadGeneration, editingEnabled, !isLoadingDocument else {
            throw VellixError.editorBridge("This text selection is no longer available.")
        }
        let generation = loadGeneration
        let applied = try await attachmentCommand("textColorApply", args: ["token": request.id,
            "style": color.map { $0.bridgeValue as Any } ?? NSNull()]) as? Bool
        guard applied == true, generation == loadGeneration, loadedDocumentID == request.documentID else {
            throw VellixError.editorBridge("This text selection changed. Select the text again.")
        }
    }

    func endTextColorEditing(restoreFocus: Bool = true) {
        guard let context = textColorContext else { return }
        textColorContext = nil
        guard context.documentID == loadedDocumentID, context.generation == loadGeneration,
              isReady, !isLoadingDocument else { return }
        send(TipTapEditorCommand("textColorEnd", args: ["token": context.token, "restoreFocus": restoreFocus && editingEnabled]))
    }

    func updateCalloutColor(blockID: String, color: String) {
        send(TipTapEditorCommand.updateCalloutColor(blockID: blockID, color: color))
    }

    func listGridRequestSelectedSettings() {
        guard isReady, editingEnabled, !isLoadingDocument, selectionMode == "off",
              formattingState.canOpenListGridSettings else { return }
        send(TipTapEditorCommand("listGridRequestSelectedSettings"))
    }

    func requestBlockSettings() {
        guard isReady, editingEnabled, !isLoadingDocument, selectionMode == "off" else { return }
        if formattingState.blockSettingsKind == nil {
            listGridRequestSelectedSettings()
        } else {
            send(TipTapEditorCommand("requestBlockSettings"))
        }
    }

    func requestSelectedBlockSettings(_ target: TipTapSelectedBlockSettings) {
        guard isReady, editingEnabled, !isLoadingDocument, selectionMode != "off",
              let loadedDocumentID, renderedDocumentID == loadedDocumentID,
              formattingState.selectedBlockSettings == target else { return }
        send(TipTapEditorCommand("requestSelectedBlockSettings", args: [
            "kind": target.kind, "blockID": target.blockID, "selectionTarget": target.selectionTarget,
        ]))
    }

    func previewCodeBlock(_ request: CodeBlockEditorRequest, draft: CodeBlockConfiguration?, documentID: String) {
        guard isReady, !isLoadingDocument, loadedDocumentID == documentID else { return }
        send(CodeBlockBridge.preview(request, draft: draft))
    }

    func commitGridCard(_ request: GridCardSettingsRequest, settings: GridCardSettings, documentID: String) async throws -> String {
        guard isReady, !isLoadingDocument, editingEnabled, loadedDocumentID == documentID, let webView else {
            throw VellixError.editorBridge("This document is no longer open for editing.")
        }
        let generation = loadGeneration
        let result = try await request.commit(settings, in: webView)
        guard loadGeneration == generation, loadedDocumentID == documentID, let snapshot = result as? [String: Any] else {
            throw VellixError.editorBridge("This Grid Card changed or was removed. Reopen its settings to continue.")
        }
        return try TipTapContentAnalyzer.normalizePayloadToJSON(snapshot)
    }

    func commitIconCallout(_ request: IconCalloutSettingsRequest, settings: IconCalloutSettings,
                           text: String?, documentID: String) async throws -> String {
        guard isReady, !isLoadingDocument, editingEnabled, loadedDocumentID == documentID, let webView else {
            throw VellixError.editorBridge("This document is no longer open for editing.")
        }
        let generation = loadGeneration
        let result = try await request.commit(settings, text: text, in: webView)
        guard loadGeneration == generation, loadedDocumentID == documentID, let snapshot = result as? [String: Any] else {
            throw VellixError.editorBridge("This callout changed or was removed. Reopen its settings to continue.")
        }
        return try TipTapContentAnalyzer.normalizePayloadToJSON(snapshot)
    }

    func commitWashiTape(_ request: WashiTapeRequest, imagePath: String?, photo: CardRemotePhoto?, tapeSize: WashiTapeSize, documentID: String) async throws -> String {
        guard isReady, !isLoadingDocument, editingEnabled, loadedDocumentID == documentID, let webView else {
            throw VellixError.editorBridge("This document is no longer open for editing.")
        }
        let generation = loadGeneration
        let result = try await request.commit(imagePath: imagePath, photo: photo, tapeSize: tapeSize, in: webView)
        guard loadGeneration == generation, loadedDocumentID == documentID, let snapshot = result as? [String: Any] else {
            throw VellixError.editorBridge("This Washi Tape changed or was removed. Reopen its settings to continue.")
        }
        return try TipTapContentAnalyzer.normalizePayloadToJSON(snapshot)
    }

    func commitHeadingLabel(_ request: HeadingLabelRequest, settings: HeadingLabelSettings, text: String, documentID: String) async throws -> String {
        guard isReady, !isLoadingDocument, editingEnabled, loadedDocumentID == documentID, let webView else {
            throw VellixError.editorBridge("This document is no longer open for editing.")
        }
        let generation = loadGeneration
        let result = try await request.commit(settings, text: text, in: webView)
        guard loadGeneration == generation, loadedDocumentID == documentID, let snapshot = result as? [String: Any] else {
            throw VellixError.editorBridge("This heading changed or was removed. Reopen its settings to continue.")
        }
        return try TipTapContentAnalyzer.normalizePayloadToJSON(snapshot)
    }

    func commitCodeBlock(_ request: CodeBlockEditorRequest, draft: CodeBlockConfiguration, documentID: String) async throws -> String {
        guard isReady, !isLoadingDocument, editingEnabled, loadedDocumentID == documentID, let webView else {
            throw VellixError.editorBridge("This document is no longer open for editing.")
        }
        let generation = loadGeneration
        let result = try await CodeBlockBridge.commit(request, draft: draft, in: webView)
        guard loadGeneration == generation, loadedDocumentID == documentID, let json = result as? [String: Any] else {
            throw VellixError.editorBridge("This Code Block changed or was removed. Copy your draft before closing, then reopen the block.")
        }
        return try TipTapContentAnalyzer.normalizePayloadToJSON(json)
    }

    func listGridSetColor(blockID: String, target: String, color: String) {
        send(TipTapEditorCommand("listGridSetColor", args: ["blockId": blockID, "target": target, "color": color]))
    }

    func listGridSetProportion(blockID: String, documentID: String, leftFraction: Int?) async throws -> Int {
        let name = leftFraction == nil ? "listGridRestoreProportion" : "listGridSetProportion"
        let values: [String: Any] = leftFraction.map { ["leftFraction": $0] } ?? [:]
        let result = try await listGridSettingsCommand(name, blockID: blockID, documentID: documentID, values: values)
        guard let applied = result as? Int, (20...80).contains(applied) else {
            throw VellixError.editorBridge("The List Grid column width could not be applied.")
        }
        return applied
    }

    func listGridSetRowStyle(blockID: String, documentID: String, index: Int, style: TipTapListGridRowStyle) async throws {
        let result = try await listGridSettingsCommand("listGridSetRowStyle", blockID: blockID, documentID: documentID,
            values: ["index": index, "rowStyle": style.rawValue])
        guard result as? Bool == true else {
            throw VellixError.editorBridge("The List Grid row style could not be applied.")
        }
    }

    private func listGridSettingsCommand(_ name: String, blockID: String, documentID: String,
                                         values: [String: Any]) async throws -> Any? {
        guard isReady, editingEnabled, !isLoadingDocument, renderedDocumentID == documentID,
              loadedDocumentID == documentID, let webView else {
            throw VellixError.editorBridge("The List Grid is no longer open for editing.")
        }
        let generation = loadGeneration
        var args = values
        args["blockId"] = blockID
        let result = try await webView.callAsyncJavaScript("return await window.tiptapCommand(name, args);",
            arguments: ["name": name, "args": args], in: nil, contentWorld: .page)
        guard generation == loadGeneration, renderedDocumentID == documentID else {
            throw VellixError.editorBridge("The List Grid is no longer open for editing.")
        }
        return result
    }

    func listGridAddRow(blockID: String) {
        send(TipTapEditorCommand("listGridAddRow", args: ["blockId": blockID]))
    }

    func listGridRemoveRow(blockID: String, index: Int) {
        send(TipTapEditorCommand("listGridRemoveRow", args: ["blockId": blockID, "index": index]))
    }

    // MARK: Tabs block

    func resetTabsNavigation() {
        guard isReady, !isLoadingDocument else { return }
        send(TipTapEditorCommand("tabsResetNavigation"))
    }

    /// Generic appearance/structure setter. `value` is a hex string, Int, Bool,
    /// or option string; the JS side sanitizes it per attribute.
    func cancelExistingEventPicker() {
        send(TipTapEditorCommand("cancelExistingEventPicker"))
    }

    func beginExistingEventConversion(blockSelection: Bool) {
        send(TipTapEditorCommand("beginExistingEventConversion", args: ["blockSelection": blockSelection]))
    }

    func insertLinkedCalendarEvent(_ event: CalendarEvent) {
        guard let identityData = try? JSONEncoder().encode(event.identity),
              let identity = try? JSONSerialization.jsonObject(with: identityData) as? [String: Any] else { return }
        send(TipTapEditorCommand("insertLinkedCalendarEvent", args: [
            "eventID": event.identity.key,
            "eventIdentity": identity,
            "title": event.title,
            "calendarTitle": event.calendarTitle,
            "start": ISO8601DateFormatter().string(from: event.start),
            "end": ISO8601DateFormatter().string(from: event.end),
            "isAllDay": event.isAllDay,
            "timeZoneID": event.timeZoneID ?? TimeZone.current.identifier,
        ]))
    }

    func markLinkedCalendarEventUnavailable(eventID: String) {
        send(TipTapEditorCommand("refreshLinkedCalendarEvent", args: [
            "eventID": eventID, "available": false,
        ]))
    }

    func refreshLinkedCalendarEvent(_ event: CalendarEvent, referenceID: String? = nil) {
        send(TipTapEditorCommand("refreshLinkedCalendarEvent", args: [
            "eventID": referenceID ?? event.identity.key,
            "available": true,
            "title": event.title,
            "calendarTitle": event.calendarTitle,
            "start": ISO8601DateFormatter().string(from: event.start),
            "end": ISO8601DateFormatter().string(from: event.end),
            "isAllDay": event.isAllDay,
            "timeZoneID": event.timeZoneID ?? TimeZone.current.identifier,
        ]))
    }

    func weekStripSetAttr(blockID: String, key: String, value: Any) {
        send(TipTapEditorCommand("weekStripSetAttr", args: ["blockId": blockID, "key": key, "value": value]))
    }

    func tabsSetAttr(blockID: String, key: String, value: Any) {
        send(TipTapEditorCommand("tabsSetAttr", args: ["blockId": blockID, "key": key, "value": value]))
    }

    func tabsSetIcon(blockID: String, icon: String) {
        let icon = normalizedIconName(icon)
        registerIconAsset(icon) { [weak self] in
            self?.send(TipTapEditorCommand("tabsSetAttr", args: ["blockId": blockID, "key": "icon", "value": icon]))
        }
    }

    func tabsSetDefaultTab(blockID: String, tabID: String) {
        send(TipTapEditorCommand("tabsSetDefaultTab", args: ["blockId": blockID, "tabId": tabID]))
    }

    /// Add a tab to the tabs block that currently contains the selection
    /// (used by the keyboard add-menu, where no block id is in hand).
    func tabsAddToSelection() {
        send(TipTapEditorCommand("tabsAddToSelection"))
    }

    /// Adds a tab and resolves to the new tab's id, so the settings sheet can
    /// keep its local tab list in sync.
    @discardableResult
    func tabsAddTab(blockID: String, documentID: String, name: String? = nil) async throws -> String? {
        var values: [String: Any] = [:]
        if let name, !name.isEmpty { values["name"] = name }
        return try await tabsCommand("tabsAddTab", blockID: blockID, documentID: documentID, values: values) as? String
    }

    func tabsCommitText(blockID: String, documentID: String,
                        headerText: [String: String], tabNames: [String: String]) {
        guard isReady, editingEnabled, !isLoadingDocument,
              renderedDocumentID == documentID, loadedDocumentID == documentID else { return }
        for (key, text) in headerText { tabsSetAttr(blockID: blockID, key: key, value: text) }
        for (tabID, name) in tabNames { tabsRenameTab(blockID: blockID, tabID: tabID, name: name) }
    }

    func tabsRenameTab(blockID: String, tabID: String, name: String) {
        send(TipTapEditorCommand("tabsRenameTab", args: ["blockId": blockID, "tabId": tabID, "name": name]))
    }

    /// Duplicates a tab and resolves to the clone's id.
    @discardableResult
    func tabsDuplicateTab(blockID: String, documentID: String, tabID: String) async throws -> String? {
        try await tabsCommand("tabsDuplicateTab", blockID: blockID, documentID: documentID,
                              values: ["tabId": tabID]) as? String
    }

    private func tabsCommand(_ name: String, blockID: String, documentID: String,
                             values: [String: Any]) async throws -> Any? {
        guard isReady, editingEnabled, !isLoadingDocument, renderedDocumentID == documentID,
              loadedDocumentID == documentID, let webView else {
            throw VellixError.editorBridge("The tabs block is no longer open for editing.")
        }
        let generation = loadGeneration
        var args = values
        args["blockId"] = blockID
        let result = try await webView.callAsyncJavaScript("return await window.tiptapCommand(name, args);",
            arguments: ["name": name, "args": args], in: nil, contentWorld: .page)
        guard generation == loadGeneration, renderedDocumentID == documentID else {
            throw VellixError.editorBridge("The tabs block is no longer open for editing.")
        }
        return result
    }

    func tabsRemoveTab(blockID: String, tabID: String) {
        send(TipTapEditorCommand("tabsRemoveTab", args: ["blockId": blockID, "tabId": tabID]))
    }

    func tabsReorderTabs(blockID: String, order: [String]) {
        send(TipTapEditorCommand("tabsReorderTabs", args: ["blockId": blockID, "order": order]))
    }

    func informationCardSetAttr(blockID: String, key: String, value: Any) {
        send(TipTapEditorCommand("informationCardSetAttr", args: ["blockId": blockID, "key": key, "value": value]))
    }

    // MARK: Minimal Fields block

    /// Generic appearance setter; `value` is a hex string, Int or Bool, sanitized JS-side.
    func minimalFieldsSetAttr(blockID: String, key: String, value: Any) {
        send(TipTapEditorCommand("minimalFieldsSetAttr", args: ["blockId": blockID, "key": key, "value": value]))
    }

    func minimalFieldsRemoveRecord(blockID: String, recordID: String) {
        send(TipTapEditorCommand("minimalFieldsRemoveRecord", args: ["blockId": blockID, "recordId": recordID]))
    }

    func minimalFieldsReorderRecords(blockID: String, order: [String]) {
        send(TipTapEditorCommand("minimalFieldsReorderRecords", args: ["blockId": blockID, "order": order]))
    }

    func minimalFieldsRemoveField(blockID: String, recordID: String, fieldID: String) {
        send(TipTapEditorCommand("minimalFieldsRemoveField", args: ["blockId": blockID, "recordId": recordID, "fieldId": fieldID]))
    }

    func minimalFieldsReorderFields(blockID: String, recordID: String, order: [String]) {
        send(TipTapEditorCommand("minimalFieldsReorderFields", args: ["blockId": blockID, "recordId": recordID, "order": order]))
    }

    /// Adds a record and resolves to its new id so the settings sheet stays in sync.
    @discardableResult
    func minimalFieldsAddRecord(blockID: String, documentID: String) async throws -> String? {
        try await minimalFieldsCommand("minimalFieldsAddRecord", blockID: blockID, documentID: documentID, values: [:]) as? String
    }

    @discardableResult
    func minimalFieldsDuplicateRecord(blockID: String, documentID: String, recordID: String) async throws -> String? {
        try await minimalFieldsCommand("minimalFieldsDuplicateRecord", blockID: blockID, documentID: documentID,
                                       values: ["recordId": recordID]) as? String
    }

    @discardableResult
    func minimalFieldsAddField(blockID: String, documentID: String, recordID: String) async throws -> String? {
        try await minimalFieldsCommand("minimalFieldsAddField", blockID: blockID, documentID: documentID,
                                       values: ["recordId": recordID]) as? String
    }

    @discardableResult
    func minimalFieldsDuplicateField(blockID: String, documentID: String, recordID: String, fieldID: String) async throws -> String? {
        try await minimalFieldsCommand("minimalFieldsDuplicateField", blockID: blockID, documentID: documentID,
                                       values: ["recordId": recordID, "fieldId": fieldID]) as? String
    }

    private func minimalFieldsCommand(_ name: String, blockID: String, documentID: String,
                                      values: [String: Any]) async throws -> Any? {
        guard isReady, editingEnabled, !isLoadingDocument, renderedDocumentID == documentID,
              loadedDocumentID == documentID, let webView else {
            throw VellixError.editorBridge("The Minimal Fields block is no longer open for editing.")
        }
        let generation = loadGeneration
        var args = values
        args["blockId"] = blockID
        let result = try await webView.callAsyncJavaScript("return await window.tiptapCommand(name, args);",
            arguments: ["name": name, "args": args], in: nil, contentWorld: .page)
        guard generation == loadGeneration, renderedDocumentID == documentID else {
            throw VellixError.editorBridge("The Minimal Fields block is no longer open for editing.")
        }
        return result
    }

    func updateBlockquoteColor(blockID: String, color: String) {
        send(TipTapEditorCommand.updateBlockquoteColor(blockID: blockID, color: color))
    }

    func updateInlineProperty(blockID: String, property: InlinePropertyDefinition) {
        do {
            send(try TipTapEditorCommand.updateInlineProperty(blockID: blockID, property: property))
        } catch {
            onEvent?(.editorError(error.localizedDescription))
        }
    }

    func deleteInlineProperty(blockID: String) {
        send(TipTapEditorCommand.deleteInlineProperty(blockID: blockID))
    }

    func focusAfterInlineProperty(blockID: String) {
        send(TipTapEditorCommand("focusAfterInlineProperty", args: ["blockId": blockID]))
    }

    func deleteSelectedBlocks() {
        send(TipTapEditorCommand.deleteSelectedBlocks())
    }

    func deleteBlock(requestToken: String) {
        send(TipTapEditorCommand("deleteBlock", args: ["token": requestToken]))
    }

    func dismissBlockActions(requestToken: String) {
        send(TipTapEditorCommand("dismissBlockActions", args: ["token": requestToken]))
    }

    func copySelectedBlocks(completion: ((Bool) -> Void)? = nil) {
        guard isReady, !isLoadingDocument, selectedBlockCount > 0, selectionMode != "off",
              acceptsEditorPresentationRequests else { completion?(false); return }
        let documentID = loadedDocumentID
        let generation = loadGeneration
        Task { [weak self] in
            guard let self else { completion?(false); return }
            let copied: Bool
            do {
                let result = try await self.attachmentCommand("copySelectedBlocks")
                copied = result as? Bool == true
            } catch {
                copied = false
            }
            guard self.loadedDocumentID == documentID, self.loadGeneration == generation,
                  self.acceptsEditorPresentationRequests else { completion?(false); return }
            completion?(copied)
        }
    }

    func cutSelectedBlocks() {
        send(TipTapEditorCommand.cutSelectedBlocks())
    }

    func duplicateSelectedBlocks() {
        send(TipTapEditorCommand.duplicateSelectedBlocks())
    }

    func requestSelectedBlocksForSubpage() {
        send(TipTapEditorCommand.requestSelectedBlocksForSubpage())
    }

    func placeGroupedPage(token: String, documentID: String, parentID: String) async throws -> Bool {
        guard isReady, !isLoadingDocument, renderedDocumentID == parentID, let webView else { return false }
        let result = try await webView.callAsyncJavaScript("return await window.tiptapCommand('placeGroupedPage', args);",
            arguments: ["args": ["token": token, "documentId": documentID]], in: nil, contentWorld: .page)
        return result as? Bool == true
    }

    func selectAllBlocks() {
        send(TipTapEditorCommand.selectAllBlocks())
    }

    func setSelectionMode(_ mode: String) {
        send(TipTapEditorCommand.setSelectionMode(mode))
    }

    func clearBlockSelection() {
        send(TipTapEditorCommand.clearBlockSelection())
    }

    func chooseSlashMenuItem(_ key: String) {
        send(TipTapEditorCommand.chooseSlashMenuItem(key))
    }

    func dismissSlashMenu() {
        send(TipTapEditorCommand("dismissSlashMenu"))
    }

    func updateEditorContentGeometry(height: CGFloat, visualContentBottom: CGFloat) {
        // The full height retains TipTap's trailing caret paragraph for hit
        // testing. The visual bottom stops at the last meaningful rendered
        // block so native page sheets do not expose that interaction-only area.
        guard height.isFinite, visualContentBottom.isFinite else { return }
        let clamped = max(40, height)
        let clampedVisualBottom = max(0, min(visualContentBottom, clamped))
        if abs(editorContentHeight - clamped) > 1 {
            logger.info("📏 TRACE height apply old=\(self.editorContentHeight) incoming=\(height) clamped=\(clamped)")
            editorContentHeight = clamped
        }
        if abs(editorVisualContentBottom - clampedVisualBottom) > 1 {
            logger.info("📏 TRACE visual bottom apply old=\(self.editorVisualContentBottom) incoming=\(visualContentBottom) clamped=\(clampedVisualBottom)")
            editorVisualContentBottom = clampedVisualBottom
        }
    }

    func undo() {
        #if os(iOS)
        cancelPendingPaste()
        #endif
        send(TipTapEditorCommand.undo())
    }

    func redo() {
        #if os(iOS)
        cancelPendingPaste()
        #endif
        send(TipTapEditorCommand.redo())
    }

    func paste() {
        guard let webView, isReady, isPresentationReady, !isLoadingDocument,
              editingEnabled, selectionMode == "off" else { return }
        let generation = loadGeneration
        #if canImport(UIKit)
        guard webView.window?.windowScene?.activationState == .foregroundActive, Self.hasPasteboardContent else { return }
        cancelPendingPaste()
        let request = pasteRequestID
        // Prefer Penned's lossless block format when it is present. Ordinary
        // external clipboard content still follows the existing WebKit path.
        let pennedBlockType = "im.lystaria.penned.blocks+json"
        if let data = UIPasteboard.general.data(forPasteboardType: pennedBlockType),
           let nativeJSON = String(data: data, encoding: .utf8) {
            webView.callAsyncJavaScript(
                "return await window.tiptapCommand('pastePennedBlocks', { nativeJSON: nativeJSON });",
                arguments: ["nativeJSON": nativeJSON], in: nil, in: .page
            ) { [weak self, weak webView] result in
                guard let self, let webView, self.pasteRequestID == request,
                      self.loadGeneration == generation, self.isReady,
                      !self.isLoadingDocument, self.editingEnabled,
                      self.selectionMode == "off",
                      webView.window?.windowScene?.activationState == .foregroundActive else { return }
                if case .success(let pasted) = result, pasted as? Bool == true { return }
                // A stale or incompatible Penned payload must not block the
                // interoperable HTML/plain-text representations on the board.
                self.logger.debug("Native Penned block paste unavailable; trying standard paste.")
                if self.performPaste(in: webView) { return }
                webView.callAsyncJavaScript("return await window.tiptapCommand('mobilePreparePaste');",
                    arguments: [:], in: nil, in: .page) { [weak self, weak webView] prepared in
                    guard let self, let webView, self.pasteRequestID == request,
                          self.loadGeneration == generation, self.isReady,
                          !self.isLoadingDocument, self.editingEnabled,
                          self.selectionMode == "off",
                          webView.window?.windowScene?.activationState == .foregroundActive,
                          case .success(let focused) = prepared, focused as? Bool == true else { return }
                    _ = self.performPaste(in: webView)
                }
            }
            return
        }
        if performPaste(in: webView) { return }
        webView.callAsyncJavaScript("return await window.tiptapCommand('mobilePreparePaste');",
            arguments: [:], in: nil, in: .page) { [weak self, weak webView] result in
            guard let self, let webView, self.pasteRequestID == request, self.loadGeneration == generation,
                  self.isReady, !self.isLoadingDocument, self.editingEnabled,
                  self.selectionMode == "off", webView.window?.windowScene?.activationState == .foregroundActive else { return }
            guard case .success(let focused) = result, focused as? Bool == true,
                  Self.hasPasteboardContent, self.performPaste(in: webView) else {
                self.logger.debug("Paste skipped: editor responder or clipboard not available.")
                return
            }
        }
        #elseif canImport(AppKit)
        send(TipTapEditorCommand.focusEditor()) { [weak self, weak webView] result in
            guard let self, let webView, self.loadGeneration == generation,
                  self.editingEnabled, !self.isLoadingDocument else { return }
            if case .failure(let error) = result { self.bridgeErrorMessage = error.localizedDescription; return }
            guard let responder = webView.window?.firstResponder,
                  NSApp.sendAction(#selector(NSText.paste(_:)), to: responder, from: nil) else {
                self.bridgeErrorMessage = "Paste is not available for the current clipboard content."
                return
            }
        }
        #endif
    }

    #if canImport(UIKit)
    static var hasPasteboardContent: Bool {
        let clipboard = UIPasteboard.general
        return clipboard.hasStrings || clipboard.hasImages || clipboard.hasURLs ||
            clipboard.types.contains("im.lystaria.penned.blocks+json") ||
            clipboard.types.contains(UTType.html.identifier) || clipboard.types.contains(UTType.fileURL.identifier)
    }

    func cancelPendingPaste() {
        pasteRequestID &+= 1
    }

    func suspendWebInput() {
        cancelPendingPaste()
        endWebEditingForSettings()
        if isReady { send(TipTapEditorCommand("mobileSuspendInput")) }
        isEditing = false
        setCaretUpdate(nil)
    }

    private func performPaste(in webView: WKWebView) -> Bool {
        let action = #selector(UIResponderStandardEditActions.paste(_:))
        guard let responder = pasteResponder(in: webView),
              responder.canPerformAction(action, withSender: nil) else { return false }
        return UIApplication.shared.sendAction(action, to: responder, from: nil, for: nil)
    }

    private func pasteResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let responder = pasteResponder(in: child) { return responder }
        }
        return nil
    }
    #endif

    func handleRawMessage(_ body: Any) {
        do {
            guard
                let dictionary = body as? [String: Any],
                let kind = dictionary["kind"] as? String
            else {
                throw VellixError.editorBridge("The editor sent an invalid TipTap message.")
            }

            let payload = dictionary["payload"] as? [String: Any] ?? [:]
            if kind == "openingDiagnostic" {
                if let phase = payload["phase"] as? String, let generation = payload["generation"] as? Int {
                    switch phase {
                    case "tiptap-set-content-returned" where generation == loadGeneration:
                        openingLoadTrace?.event(phase, "loadGeneration=\(generation)")
                    case "fonts-wait-start", "fonts-wait-completed", "image-decode-start", "image-decode-completed":
                        if let origin = openingWebTrace, generation == origin.generation {
                            origin.trace.event(phase, "presentationGeneration=\(origin.generation) currentGeneration=\(presentation.generation) count=\(payload["count"] as? Int ?? -1) fontsLoading=\(payload["fontsLoading"] as? Bool == true) browserMS=\(payload["browserMS"] as? Int ?? -1)")
                        }
                    default: break
                    }
                }
                return
            }
            #if os(iOS)
            if kind == "blockDragSelectionClaimed" {
                if let token = payload["token"] as? String { blockDragGesture?.relinquishToSelection(token: token) }
                return
            }
            if kind == "blockDropValidate" {
                guard let token = payload["token"] as? String,
                      let destinationID = payload["destinationID"] as? String else { return }
                let generation = loadGeneration
                Task { [weak self] in
                    guard let self, let webView = self.webView else { return }
                    let allowed: Bool
                    if self.acceptsEditorPresentationRequests && self.editingEnabled {
                        allowed = await self.onValidateBlockDrop?(destinationID, payload["pageIDs"] as? [String] ?? []) ?? false
                    } else { allowed = false }
                    guard self.loadGeneration == generation else { return }
                    self.recordBlockDrag(allowed ? "page-validation-accepted" : "page-validation-rejected", token: token)
                    _ = try? await webView.callAsyncJavaScript(
                        "return window.PennedBlockDragAndDrop?.native('validatePage', args);",
                        arguments: ["args": ["token": token, "destinationID": destinationID, "allowed": allowed]],
                        in: nil, contentWorld: .page)
                }
                return
            }
            if kind == "blockDragHaptic" {
                if let token = payload["token"] as? String, let destination = payload["destination"] as? String {
                    blockDragGesture?.reachedDestination(token: token, destination: destination)
                }
                return
            }
            if kind == "reminderTaskDiagnostic" {
                let fields = ["event", "target", "dom", "row", "selected", "token"]
                let details = fields.compactMap { field -> String? in
                    guard let value = payload[field] as? String else { return nil }
                    return "\(field)=\(value)"
                }.joined(separator: " ")
                logger.notice("⏰ [PENNED-RTASK] \(details, privacy: .public)")
                return
            }
            if kind == "blockDragDiagnostic" {
                if let event = payload["event"] as? String {
                    // Fixed scalar allowlist: no document text, HTML, titles or arbitrary payloads.
                    let fields = ["contactID", "browserTS", "elapsedMS", "owner", "previous", "source", "sourceID", "blockType",
                                  "selected", "reorderable", "accepted", "reason", "count", "depth", "position", "identifier",
                                  "dx", "userSelect", "blockUserSelect", "effective", "prevented", "holdMS", "phase", "committed", "errorType", "frames"]
                    let details = fields.compactMap { field -> String? in
                        guard let value = payload[field], value is String || value is NSNumber else { return nil }
                        return "\(field)=\(value)"
                    }.joined(separator: " ")
                    recordBlockDrag(event, token: payload["token"] as? String ?? "-",
                                    details: details)
                }
                return
            }
            if kind == "blockDropTransfer" {
                guard let token = payload["token"] as? String, UUID(uuidString: token) != nil else { return }
                let generation = loadGeneration
                let documentID = loadedDocumentID
                Task { [weak self] in
                    guard let self, let webView = self.webView else { return }
                    var response: [String: Any] = ["token": token, "success": false]
                    do {
                        guard self.acceptsEditorPresentationRequests, self.editingEnabled,
                              let perform = self.onBlockDropTransfer else {
                            throw VellixError.editorBridge("This document is no longer active.")
                        }
                        try await perform(payload)
                        response["success"] = true
                    } catch {
                        response["message"] = error.localizedDescription
                        self.recordBlockDrag("transfer-failed", token: token)
                    }
                    guard self.loadGeneration == generation, self.loadedDocumentID == documentID else { return }
                    do {
                        let acknowledged = try await webView.callAsyncJavaScript(
                            "return window.PennedBlockDragAndDrop?.native('resolveTransfer', args);",
                            arguments: ["args": response], in: nil, contentWorld: .page)
                        if response["success"] as? Bool == true, acknowledged as? Bool != true {
                            self.recoverCommittedBlockDrop(documentID: documentID, token: token)
                        }
                    } catch {
                        self.recordBlockDrag("transfer-acknowledgment-failed", token: token)
                        if response["success"] as? Bool == true { self.recoverCommittedBlockDrop(documentID: documentID, token: token) }
                    }
                }
                return
            }
            if kind == "blockSelectionState" {
                guard let count = payload["count"] as? Int, let reportedMode = payload["mode"] as? String else { return }
                let mode = count > 0 && ["single", "multi"].contains(reportedMode) ? reportedMode : "off"
                if selectionMode != mode { handle(.selectionModeChanged(mode)) }
                handle(.blockSelectionChanged(mode == "off" ? 0 : count))
                return
            }
            if kind == "blockSelectionDrag" {
                if let drag = MobileBlockSelectionDrag(payload: payload) { blockSelectionDragUpdates.send(drag) }
                return
            }
            if kind == "mobileHistoryAvailability" {
                let undo = payload["canUndo"] as? Bool ?? false
                let redo = payload["canRedo"] as? Bool ?? false
                if canUndo != undo { canUndo = undo }
                if canRedo != redo { canRedo = redo }
                return
            }
            if kind == "blockSelectionSurfaces" {
                let ids: [String] = selectionMode == "off" ? [] : (payload["collectionBlockIDs"] as? [String] ?? [])
                let selected = Set(ids)
                if selectedCollectionBlockIDs != selected { selectedCollectionBlockIDs = selected }
                return
            }
            #endif
            if kind == "editorSmartPaste" {
                // The editor intercepts its own paste so a lossless Penned slice on
                // the native pasteboard survives WebKit's clipboard sanitizer. This
                // reconstructs it when present and otherwise re-issues a normal paste.
                paste()
                return
            }
            if kind == "clonePageReferences" {
                // A duplicated/pasted page card must own an independent page, not
                // share the original. Hand the {blockId, sourceDocumentID} pairs to
                // the owner, which clones each source page and repoints the card.
                let pairs = (payload["pairs"] as? [[String: Any]])?.compactMap { pair -> [String: String]? in
                    guard let blockID = pair["blockId"] as? String, !blockID.isEmpty,
                          let source = pair["sourceDocumentID"] as? String, !source.isEmpty else { return nil }
                    return ["blockId": blockID, "sourceDocumentID": source]
                } ?? []
                if !pairs.isEmpty { onClonePageReferences?(pairs) }
                return
            }
            if kind == "diag" {
                let message = payload["message"] as? String ?? ""
                logger.info("VELLIX-DIAG \(message, privacy: .public)")
                return
            }
            let event = try TipTapEditorEvent(kind: kind, payload: payload)
            handle(event)
        } catch {
            bridgeErrorMessage = error.localizedDescription
            logger.error("Invalid editor event: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ event: TipTapEditorEvent) {
        switch event {
        case .tagRequest(let request):
            guard ownsEditorPresentation == nil || acceptsEditorPresentationRequests else { return }
            tagRequest = request
        case .editorReady(let blockCount):
            logger.info("VELLIX-OPEN editorReady blocks=\(blockCount)")
            logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms editor ready blockCount=\(blockCount)")
            isReady = true
            openingTrace?.event("tiptap-bridge-ready", openingReadinessState(for: openingTrace?.documentID ?? ""))
            if isStandbyRuntime {
                PennedDiagnostics.markStartup("editor-standby.ready")
                return
            }
            openingTiming?.mark("editor-bridge-ready")
            if let context = editingContext {
                configureDocumentContext(documentID: context.documentID, templateID: context.templateID)
            }
            if !preparesInteractivePresentation {
                sendPageReferences()
                sendCollections()
            }
        selectedBlockCount = 0
        selectionMode = "off"
        #if os(iOS)
        selectedCollectionBlockIDs = []
        #endif
        isEditing = false
        slashMenuState = nil
        pageBreakRegions = []
        collectionRegions = []
        if let pendingDocument {
                load(documentID: pendingDocument.id, canonicalJSON: pendingDocument.json, force: true)
            } else if let loadedDocumentID {
                setRenderedDocumentID(loadedDocumentID)
            } else {
                setRenderedDocumentID(nil)
            }
            if let pendingAppearance {
                setAppearance(pendingAppearance)
            }

        case .documentTextChanged(let json), .documentChanged(let json), .documentSnapshot(let json):
            if let watched = PennedSyncTrace.documentID,
               (loadedDocumentID ?? pendingDocument?.id ?? recoveryDocument?.id) == watched {
                let kind: String
                if case .documentSnapshot = event { kind = "editor.bridgeSnapshot" } else { kind = "editor.bridgeUpdate" }
                PennedSyncTrace.record(kind,
                    "accepted=\(isReady && !isLoadingDocument && loadedDocumentID != nil) loading=\(isLoadingDocument) editing=\(isEditing) \(PennedSyncTrace.body(json))")
            }
            guard isReady, !isLoadingDocument, let loadedDocumentID else {
                logger.debug("Suppressed programmatic editor change")
                return
            }
            if observedInteractionEnabled, case .documentTextChanged = event {
                openingTiming?.mark("first-text-bridge-event")
            }
            recoveryDocument = (loadedDocumentID, json)
            onEvent?(event)

        case .editorError(let message):
            logger.info("🚨 TRACE EVENT editorError message=\(message, privacy: .public)")
            bridgeErrorMessage = message
            onEvent?(event)

        case .contentHeightChanged(let height, let visualContentBottom):
            logger.info("📏 TRACE EVENT contentHeightChanged height=\(height) visualBottom=\(visualContentBottom)")
            updateEditorContentGeometry(
                height: height,
                visualContentBottom: visualContentBottom
            )
            if let awaitingRenderedDocumentID,
               awaitingRenderedDocumentID == loadedDocumentID {
                logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms first rendered document height id=\(awaitingRenderedDocumentID, privacy: .public)")
                setRenderedDocumentID(awaitingRenderedDocumentID)
                self.awaitingRenderedDocumentID = nil
            }
            onEvent?(event)

        case .pageBreakRegionsChanged(let regions):
            logger.info("📄 TRACE EVENT pageBreakRegionsChanged count=\(regions.count)")
            pageBreakRegions = regions
            onEvent?(event)

        case .collectionRegionsChanged(let regions):
            collectionRegions = regions
            for region in regions {
                if let pending = pendingNativePresentationHeights[region.id], abs(region.rect.height - pending.height) <= 1 {
                    presentation.nativeDidLayout(blockID: region.id, viewID: pending.viewID)
                    pendingNativePresentationHeights[region.id] = nil
                }
            }
            confirmPresentationIfReady()

        case .caretChanged(let update):
            guard isEditing, !isLoadingDocument, selectionMode == "off" else { return }
            setCaretUpdate(update)

        case .blockSelectionChanged(let count):
            logger.info("🔘 TRACE EVENT blockSelectionChanged count=\(count) previous=\(self.selectedBlockCount)")
            guard selectedBlockCount != count || (count == 0 && selectionMode != "off") else {
                return
            }
            selectedBlockCount = count
            if count > 0 {
                isEditing = false
                slashMenuState = nil
            } else if selectionMode != "off" {
                selectionMode = "off"
                textConversionState = TipTapTextConversionState()
                #if os(iOS)
                selectedCollectionBlockIDs = []
                #endif
                send(TipTapEditorCommand("clearBlockSelectionIfEmpty"))
            }
            onEvent?(event)

        case .selectionModeChanged(let mode):
            logger.info("🔘 TRACE EVENT selectionModeChanged mode=\(mode, privacy: .public) previous=\(self.selectionMode, privacy: .public)")
            if selectionMode != mode { textConversionState = TipTapTextConversionState() }
            selectionMode = mode
            if mode == "off" {
                selectedBlockCount = 0
                #if os(iOS)
                selectedCollectionBlockIDs = []
                #endif
                slashMenuState = nil
            }
            onEvent?(event)

        case .focusChanged(let focused):
            logger.info("🎯 TRACE EVENT focusChanged focused=\(focused)")
            isEditing = focused
            if !focused { setCaretUpdate(nil) }
            onEvent?(event)

        case .formattingStateChanged(let state):
            if formattingState != state { formattingState = state }

        case .textConversionStateChanged(let state):
            var current = TipTapTextConversionState()
            if isReady && !isLoadingDocument && editingEnabled {
                if selectionMode == "off" {
                    current = state
                } else {
                    // Block conversion has no text bookmark. Keep only its divider choices.
                    current.targets = Set(state.targets.filter { $0.hasPrefix("divider:") })
                }
            }
            if textConversionState != current { textConversionState = current }

        case .requestHaptic(let style):
            logger.info("🫨 TRACE EVENT requestHaptic style=\(style, privacy: .public)")
            triggerHaptic(style: style)

        case .statisticsChanged:
            logger.info("📊 TRACE EVENT statisticsChanged")
            onEvent?(event)

        case .requestBlockConversion, .requestGridCardSettings, .requestIconCalloutSettings, .requestHeadingLabelSettings, .requestWashiTapeSettings,
             .requestPageCardSettings, .requestBlockquoteColorPicker,
             .requestTemplates, .requestAttachment, .requestAttachmentActions, .requestCollection,
             .requestTemplateComponent, .requestInlinePropertyEditor, .requestNestedPage, .requestPageCard,
             .requestBlockDeletion, .requestPlaceholderConversion, .requestListGridSettings, .requestTabsSettings, .requestWeekStripSettings, .requestExistingEventPicker, .openLinkedCalendarEvent,
             .requestMinimalFieldsSettings, .requestInformationCardSettings, .requestCodeBlockEditor,
             .requestTableCreation, .requestTableMenu, .requestTaskMenu:
            guard acceptsEditorPresentationRequests, editingEnabled else { return }
            onEvent?(event)

        case .requestPropertyURL, .requestOpenPage, .requestPageActions:
            guard acceptsEditorPresentationRequests else { return }
            onEvent?(event)

        case .requestCalloutColorPicker:
            break

        case .attachmentClipboard, .importAttachments:
            onEvent?(event)

        case .tableDocumentSnapshot, .taskDocumentSnapshot:
            guard isReady, !isLoadingDocument, loadedDocumentID != nil else { return }
            onEvent?(event)

        case .tableStateChanged, .tableFormulaPreview, .tableClipboard, .taskStateChanged, .requestTaskCompletion:
            onEvent?(event)

        case .slashMenuChanged(let state):
            logger.info("⌘ TRACE EVENT slashMenuChanged visible=\(state != nil) count=\(state?.items.count ?? 0)")
            if state != nil, isLoadingDocument || !editingEnabled || selectionMode != "off" { return }
            slashMenuState = state
            onEvent?(event)

        case .selectedBlocksForSubpage:
            logger.info("📦 TRACE EVENT selectedBlocksForSubpage")
            onEvent?(event)

        case .unknown(let type):
            logger.info("❓ TRACE EVENT unknown type=\(type, privacy: .public)")
            onEvent?(event)
        }
    }

    private func triggerHaptic(style: String) {
        #if os(iOS)
        let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case "medium":
            feedbackStyle = .medium
        case "heavy":
            feedbackStyle = .heavy
        case "rigid":
            feedbackStyle = .rigid
        case "soft":
            feedbackStyle = .soft
        default:
            feedbackStyle = .light
        }
        let generator = UIImpactFeedbackGenerator(style: feedbackStyle)
        generator.impactOccurred()
        #endif
    }

    #if os(iOS)
    private func recoverCommittedBlockDrop(documentID: String?, token: String) {
        guard let documentID, loadedDocumentID == documentID,
              let saved = documentForRecovery?(), saved.id == documentID else { return }
        // Persistence succeeded but the web process did not apply its reply.
        // Reload the committed checkpoint, never autosave the pre-transfer body.
        recordBlockDrag("transfer-checkpoint-recovery", token: token)
        load(documentID: documentID, canonicalJSON: saved.json, force: true)
    }

    func applyExternalBlockDrop(_ record: DocumentRecord) async -> Bool {
        guard loadedDocumentID == record.id, isReady, !isLoadingDocument, let webView,
              let data = record.tipTapJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return window.PennedBlockDragAndDrop?.applyExternal(args) ?? false;",
                arguments: ["args": ["document": object]], in: nil, contentWorld: .page)
            return result as? Bool == true
        } catch { recordBlockDrag("destination-prefix-bridge-failed", token: "-"); return false }
    }
    #endif

    private func registerIconAssets(_ icons: Set<String>, completion: @escaping () -> Void) {
        let pendingIcons = Array(Set(icons.map(normalizedIconName))).filter { !registeredIconAssets.contains($0) }
        guard !pendingIcons.isEmpty else {
            completion()
            return
        }

        let generationStart = CFAbsoluteTimeGetCurrent()
        logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms icon base64 generation start count=\(pendingIcons.count)")

        var assets: [String: String] = [:]
        for icon in pendingIcons {
            let iconStart = CFAbsoluteTimeGetCurrent()
            guard let dataURL = TipTapEditorIconRenderer.dataURL(for: icon) else {
                logger.info("✨ TRACE ICON bulk skipped icon=\(icon, privacy: .public) reason=data-url-unavailable")
                continue
            }
            let iconMS = Int((CFAbsoluteTimeGetCurrent() - iconStart) * 1000)
            logger.info("⏱️ STARTUP icon base64 generated icon=\(icon, privacy: .public) ms=\(iconMS) bytes=\(dataURL.count)")
            assets[icon] = dataURL
        }

        let generationMS = Int((CFAbsoluteTimeGetCurrent() - generationStart) * 1000)
        logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms icon base64 generation complete ms=\(generationMS) assets=\(assets.count)")

        guard !assets.isEmpty else {
            completion()
            return
        }

        let bridgeStart = CFAbsoluteTimeGetCurrent()
        logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms icon bulk bridge send start count=\(assets.count)")
        send(TipTapEditorCommand.registerIconAssets(assets)) { [weak self] result in
            guard let self else {
                completion()
                return
            }

            let bridgeMS = Int((CFAbsoluteTimeGetCurrent() - bridgeStart) * 1000)
            self.logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms icon bulk bridge send complete ms=\(bridgeMS)")

            if case .success = result {
                assets.keys.forEach { self.registeredIconAssets.insert($0) }
                self.logger.info("✨ TRACE ICON bulk success count=\(assets.count)")
            } else if case .failure(let error) = result {
                self.logger.error("✨ TRACE ICON bulk failed count=\(assets.count) error=\(error.localizedDescription, privacy: .public)")
            }

            completion()
        }
    }

    private func editorIconNames(fromCanonicalJSON canonicalJSON: String) -> Set<String> {
        var icons = calloutIconNames(fromCanonicalJSON: canonicalJSON)
        [
            "h1",
            "h2",
            "h3",
            "h4",
            "h5",
            "linedpages",
            "addwavy",
            "imagesign",
            "chevleft",
            "chevright",
            "chevdown",
            "chevup",
            "indent",
            "outdent",
            "sparkle",
            "quote",
            "checkwavy",
            "xmarkwavy",
            "listcircle",
            "numcal",
            "linesbmark",
            "codewindow",
            "minuswavy",
            "pagefold",
            "dotswavy",
            "ellipsis",
            "play",
            "pausewavy",
            "sf:speaker.wave.2.fill",
            "sf:speaker.slash.fill",
            "clockfill",
            "clockwavy",
            "repeatfill",
            "link",
            "linkcircle"
        ].forEach { icons.insert($0) }
        return icons
    }

    private func registerIconAsset(_ icon: String, completion: @escaping () -> Void) {
        let icon = normalizedIconName(icon)
        guard let dataURL = TipTapEditorIconRenderer.dataURL(for: icon) else {
            logger.info("✨ TRACE ICON register skipped icon=\(icon, privacy: .public) reason=data-url-unavailable")
            completion()
            return
        }

        send(TipTapEditorCommand.registerIconAsset(icon: icon, src: dataURL)) { [weak self] result in
            guard let self else {
                completion()
                return
            }

            if case .success = result {
                self.registeredIconAssets.insert(icon)
                self.logger.info("✨ TRACE ICON register success icon=\(icon, privacy: .public) bytes=\(dataURL.count)")
            } else if case .failure(let error) = result {
                self.logger.error("✨ TRACE ICON register failed icon=\(icon, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }

            completion()
        }
    }

    private func calloutIconNames(fromCanonicalJSON canonicalJSON: String) -> Set<String> {
        guard
            let data = canonicalJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return [DEFAULT_CALLOUT_ICON]
        }

        var icons = Set<String>()

        func visit(_ node: Any) {
            if let nodes = node as? [Any] {
                nodes.forEach(visit)
                return
            }

            guard let dictionary = node as? [String: Any] else {
                return
            }

            if ["callout", "gridCard", "iconCallout"].contains(dictionary["type"] as? String ?? "") {
                let attrs = dictionary["attrs"] as? [String: Any] ?? [:]
                icons.insert(normalizedIconName(attrs["icon"] as? String))
            }
            if dictionary["type"] as? String == "heading", let attrs = dictionary["attrs"] as? [String: Any],
               let label = HeadingLabelSettings.configuration(attrs), label.enabled, label.iconEnabled {
                icons.insert(label.icon)
            }

            if let content = dictionary["content"] {
                visit(content)
            }
        }

        visit(object)
        icons.insert(DEFAULT_CALLOUT_ICON)
        return icons
    }

    private var DEFAULT_CALLOUT_ICON: String {
        "sparkle"
    }

    private func normalizedIconName(_ icon: String?) -> String {
        let value = icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? DEFAULT_CALLOUT_ICON : value
    }

    private func send(
        _ command: TipTapEditorCommand,
        file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        #if DEBUG && os(iOS)
        let trace = PennedKeyboardTrace.record("bridge.out", session: self,
            "command=\(command.name) at=\(file):\(line) \(function)" +
                (command.name == "setEditable" ? " editableArg=\(command.args["editable"] as? Bool == true) preserveSelection=\(command.args["preservingBlockSelection"] as? Bool == true)" : ""),
            live: ["blur", "focus", "focusDocumentEnd", "setEditable", "setContent", "setSelectionMode"].contains(command.name))
        #endif
        if command.name == "insertBlock", command.args["blockType"] as? String == "tabs" {
            print("🧩 TABS BRIDGE: sending command to WKWebView")
        }
        logger.info("📤 TRACE TIPTAP OUT command=\(command.name, privacy: .public) args=\(self.payloadSummary(command.args), privacy: .public)")
        let openingCommandTrace = openingLoadTrace.flatMap { command.args["openingLoadDiagnosticGeneration"] == nil ? nil : $0 }
        guard let webView else {
            openingCommandTrace?.event("set-content-not-sent", "reason=webview-unattached")
            #if DEBUG && os(iOS)
            if let trace { PennedKeyboardTrace.record("bridge.out.skipped", session: self, "sent_seq=\(trace) reason=unattached") }
            #endif
            completion?(.failure(VellixError.editorBridge("The editor web view is not attached.")))
            return
        }

        // tiptapCommand is async. Evaluating `void tiptapCommand(...)` acknowledges
        // scheduling, not completion, and could expose/capture an empty startup body.
        // Diagnose Tabs insertion without altering its transaction or document data.
        // The ordinary bridge discards JavaScript's return value; for Tabs, capture
        // the actual result and document state before and after the command.
        let script: String
        if command.name == "insertBlock", command.args["blockType"] as? String == "tabs" {
            script = """
            const editor = window.editor;
            const before = editor?.state?.doc;
            const beforeSize = before?.content?.size ?? -1;
            const beforeBlocks = before?.childCount ?? -1;
            const beforeJSON = before?.toJSON?.();
            const countTabs = doc => { let n = 0; doc?.descendants?.(node => { if (node.type.name === 'tabs') n++; }); return n; };
            const beforeTabs = countTabs(before);
            try {
              const accepted = await window.tiptapCommand(name, args);
              const after = editor?.state?.doc;
              return { accepted: accepted === true, returned: String(accepted), beforeSize, afterSize: after?.content?.size ?? -1, beforeBlocks, afterBlocks: after?.childCount ?? -1, beforeTabs, afterTabs: countTabs(after), docChanged: before !== after, documentPreserved: beforeJSON ? JSON.stringify(beforeJSON) === JSON.stringify(after?.toJSON?.()) : null };
            } catch (error) {
              return { thrown: String(error?.stack || error), beforeSize, beforeBlocks, beforeTabs, afterSize: editor?.state?.doc?.content?.size ?? -1 };
            }
            """
        } else {
            script = "await window.tiptapCommand(name, args);"
        }
        openingCommandTrace?.event("set-content-sent", "loadGeneration=\(loadGeneration)")
        webView.callAsyncJavaScript(script,
            arguments: ["name": command.name, "args": command.args], in: nil, in: .page) { [weak self] result in
            #if DEBUG && os(iOS)
            if let trace {
                let status: String
                switch result {
                case .success: status = "returned"
                case .failure: status = "failed"
                }
                PennedKeyboardTrace.record("bridge.callback", session: self, "sent_seq=\(trace) command=\(command.name) status=\(status)")
            }
            #endif
            guard let self else { return }
            switch result {
            case .failure(let error):
                if command.name == "insertBlock", command.args["blockType"] as? String == "tabs" {
                    print("🧩 TABS BRIDGE ERROR: \(error.localizedDescription)")
                }
                self.logger.error("📤🚨 TRACE TIPTAP OUT failure command=\(command.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                completion?(.failure(error))
            case .success(let value):
                if command.name == "insertBlock", command.args["blockType"] as? String == "tabs" {
                    print("🧩 TABS DIAGNOSTIC result=\(String(describing: value))")
                    self.logger.error("🧩 TABS DIAGNOSTIC result=\(String(describing: value), privacy: .public)")
                }
                self.logger.info("📤✅ TRACE TIPTAP OUT success command=\(command.name, privacy: .public)")
                completion?(.success(()))
            }
        }
    }

    private func setRenderedDocumentID(_ documentID: String?) {
        guard renderedDocumentID != documentID else {
            logger.info("👁️ TRACE renderedDocumentID unchanged id=\(documentID ?? "nil", privacy: .public)")
            return
        }

        logger.info("👁️ TRACE renderedDocumentID set from=\(self.renderedDocumentID ?? "nil", privacy: .public) to=\(documentID ?? "nil", privacy: .public)")
        renderedDocumentID = documentID
    }

    private func payloadSummary(_ payload: [String: Any]) -> String {
        let keys = payload.keys.sorted().joined(separator: ",")
        if let document = payload["document"] as? [String: Any],
           let content = document["content"] as? [Any] {
            return "object(keys=\(keys), documentBlocks=\(content.count), callouts=\(calloutTraceSummary(fromJSONObject: document)))"
        }
        return "object(keys=\(keys))"
    }

    private func calloutTraceSummary(fromCanonicalJSON canonicalJSON: String) -> String {
        guard
            let data = canonicalJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return "invalid-json"
        }

        return calloutTraceSummary(fromJSONObject: object)
    }

    private func calloutTraceSummary(fromJSONObject object: Any) -> String {
        var records: [String] = []

        func visit(_ node: Any, path: String) {
            if let nodes = node as? [Any] {
                for (index, child) in nodes.enumerated() {
                    visit(child, path: path.isEmpty ? "\(index)" : "\(path).\(index)")
                }
                return
            }

            guard let dictionary = node as? [String: Any] else {
                return
            }

            if dictionary["type"] as? String == "callout" {
                let attrs = dictionary["attrs"] as? [String: Any] ?? [:]
                let id = attrs["id"] as? String ?? "nil"
                let icon = attrs["icon"] as? String ?? "nil"
                let color = attrs["color"] as? String ?? "nil"
                records.append("{path:\(path),id:\(id),icon:\(icon),color:\(color)}")
            }

            if let content = dictionary["content"] {
                visit(content, path: path)
            }
        }

        visit(object, path: "")
        return records.isEmpty ? "[]" : "[\(records.joined(separator: ","))]"
    }

}

@MainActor
final class DocumentEditorModel: ObservableObject {
    let session: TipTapEditorSession
    let webViewStore: TipTapEditorWebViewStore
    private let documentRepository: DocumentRepository
    private let snapshotRepository: SnapshotRepository
    private let attachmentStore: AttachmentStore?
    private var pendingCardBlockID: String?
    private let persistenceQueue = DispatchQueue(label: "penned.editor.persistence", qos: .userInitiated)
    private let saveGeneration = EditorSaveGeneration()

    @Published var document: DocumentRecord? {
        didSet {
            guard let document, let oldValue, document.id == oldValue.id else { return }
            if document.title != oldValue.title || document.icon != oldValue.icon
                || document.cover != oldValue.cover || document.appearanceJSON != oldValue.appearanceJSON
                || document.cardStyleJSON != oldValue.cardStyleJSON
                || (document.tipTapJSON != oldValue.tipTapJSON && document.tipTapJSON != latestJSON) {
                noteTemplateChange()
            }
        }
    }
    @Published private(set) var templateNeedsSave = false
    @Published private(set) var isSavingTemplate = false
    @Published private(set) var appearance = DocumentAppearance.plain
    @Published var children: [DocumentRecord] = [] {
        didSet {
            if children.map(TemplatePageSaveContent.init) != oldValue.map(TemplatePageSaveContent.init) {
                noteTemplateChange()
            }
        }
    }
    @Published private(set) var pageReferenceIDs: Set<String> = []
    @Published var snapshots: [DocumentSnapshotRecord] = []
    @Published var gridCardSettingsRequest: GridCardSettingsRequest?
    @Published var iconCalloutSettingsRequest: IconCalloutSettingsRequest?
    @Published var washiTapeRequest: WashiTapeRequest?
    @Published var headingLabelSettingsRequest: HeadingLabelRequest?
    @Published var templateComponentRequest: TemplateComponentRequest?
    @Published var attachmentEditorRequest: AttachmentEditorRequest?
    @Published var attachmentActionRequest: AttachmentActionRequest?
    @Published var blockquoteColorRequest: BlockquoteColorRequest?
    let propertyEditorRequests = PassthroughSubject<InlinePropertyEditorRequest, Never>()
    @Published var collectionEditorRequest: CollectionEditorRequest?
    @Published var templateInsertionRequest: TemplateInsertionRequest?
    @Published var propertyURLRequest: InlinePropertyURLRequest?
    @Published var nestedPageActionTarget: DocumentRecord?
    @Published var blockDeletionRequest: BlockDeletionRequest?
    @Published var listGridSettingsRequest: TipTapListGridSettings?
    @Published var codeBlockEditorRequest: CodeBlockEditorRequest?
    @Published var tabsSettingsRequest: TipTapTabsSettings?
    @Published var weekStripSettingsRequest: WeekStripSettingsRequest?
    @Published var existingEventPickerRequest: ExistingEventPickerRequest?
    @Published var linkedCalendarEventRequest: LinkedCalendarEventRequest?
    @Published var minimalFieldsSettingsRequest: TipTapMinimalFieldsSettings?
    @Published var informationCardSettingsRequest: TipTapInformationCardSettings?
    @Published var cardEditorRequest: PageCardEditorRequest?
    @Published var errorMessage: String?
    @Published var placeholderConversionToken: String?
    @Published var blockConversionRequest: TipTapBlockConversionRequest?
    @Published var tableEditorRequest: TableEditorRequest?
    @Published private(set) var tableContext: TipTapTableContext?
    @Published private(set) var tableFormulaPreview = ""
    @Published private(set) var taskContext: DocumentTaskContext?
    @Published private(set) var historyPageTask: DocumentTaskRecord?
    @Published var taskEditorRequest: TaskEditorRequest?
    @Published var taskHistoryRequest: TaskHistorySheetRequest?
    @Published var taskFeedback: String?
    var onChildCreated: ((DocumentRecord) -> Void)?
    var onOpenNestedPage: ((DocumentRecord) -> Void)?
    var onDocumentSaved: ((DocumentRecord) -> Void)?
    var prepareBlockDropDestination: ((String) async throws -> Void)?
    var blockDropRecordSaved: ((DocumentRecord, Bool) async -> Void)?
    private var blockDropTransfers: [String: BlockDropTransferCheckpoint] = [:]
    var prepareForSpaceChange: (() throws -> Void)?

    private var pendingSaveTask: Task<Void, Never>?
    private var pendingDocumentID: String?
    private(set) var isReadOnlyWarmup = false
    private var warmupNeedsReload = false
    private let pageReferenceLifecycle = PageReferenceLifecycle()
    private var adoptingSavedCheckpoint = false
    private var linkedEventSyncTask: Task<Void, Never>?
    private let linkedEventCalendarService = AppleCalendarService()

    func syncLinkedCalendarEvents() {
        guard let json = latestJSON ?? document?.tipTapJSON,
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var references: [(String, CalendarEventIdentity, Date)] = []
        func collect(_ node: [String: Any]) {
            if node["type"] as? String == "linkedCalendarEvent",
               let attrs = node["attrs"] as? [String: Any],
               let eventID = attrs["eventID"] as? String,
               let identityJSON = attrs["eventIdentity"] as? [String: Any],
               let identityData = try? JSONSerialization.data(withJSONObject: identityJSON),
               let identity = try? JSONDecoder().decode(CalendarEventIdentity.self, from: identityData),
               let startString = attrs["start"] as? String,
               let start = ISO8601DateFormatter().date(from: startString) {
                references.append((eventID, identity, start))
            }
            for child in node["content"] as? [[String: Any]] ?? [] { collect(child) }
        }
        collect(root)
        linkedEventSyncTask?.cancel()
        guard !references.isEmpty else { return }
        let documentID = document?.id
        let service = linkedEventCalendarService
        linkedEventSyncTask = Task { [weak self] in
            let access = await service.access()
            for (eventID, identity, start) in references {
                guard !Task.isCancelled else { return }
                let event = access == .allowed ? await service.linkedEvent(identity: identity, lastKnownStart: start) : nil
                guard !Task.isCancelled, let self, self.document?.id == documentID else { return }
                if let event { self.session.refreshLinkedCalendarEvent(event, referenceID: eventID) }
                else { self.session.markLinkedCalendarEventUnavailable(eventID: eventID) }
            }
        }
    }

    private var latestJSON: String? {
        didSet { if !adoptingSavedCheckpoint && latestJSON != oldValue { noteTemplateChange() } }
    }
    private var lastAutomaticSnapshotRevision = 0
    private var saveSequence = 0 { didSet { saveGeneration.set(saveSequence) } }
    private var templateChangeVersion = 0
    private var confirmedTemplateChangeVersion: Int?
    private var persistentOperations: Set<UUID> = []
    private var persistentOperationWaiters: [CheckedContinuation<Void, Never>] = []

    func beginPersistentOperation() -> UUID {
        let id = UUID(); persistentOperations.insert(id); return id
    }

    func endPersistentOperation(_ id: UUID) {
        persistentOperations.remove(id)
        if persistentOperations.isEmpty {
            let waiters = persistentOperationWaiters; persistentOperationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    var hasUnsavedLibraryContent: Bool {
        if pendingDocumentID != nil || !persistentOperations.isEmpty { return true }
        if case .failed = session.saveState { return true }
        return false
    }

    func waitForPersistentOperations() async {
        while !persistentOperations.isEmpty {
            await withCheckedContinuation { persistentOperationWaiters.append($0) }
        }
    }

    var documentID: String {
        document?.id ?? ""
    }

    init(
        documentRepository: DocumentRepository,
        snapshotRepository: SnapshotRepository,
        attachmentStore: AttachmentStore? = nil,
        runtime: TipTapEditorWebViewStore? = nil
    ) {
        let session = runtime?.coordinator.session ?? TipTapEditorSession()
        self.session = session
        self.webViewStore = runtime ?? TipTapEditorWebViewStore(session: session)
        self.documentRepository = documentRepository
        self.snapshotRepository = snapshotRepository
        self.attachmentStore = attachmentStore
        session.attachmentStore = attachmentStore
        session.attachmentResolver = { [weak documentRepository] id, json in
            guard let documentRepository, let attachmentStore else { return [] }
            return try documentRepository.editorAttachments(documentID: id, json: json, store: attachmentStore)
        }
        session.onEvent = { [weak self] event in
            self?.handle(event)
        }
        session.onClonePageReferences = { [weak self] pairs in
            Task { await self?.cloneDuplicatedPageReferences(pairs) }
        }
        session.onBlockDropTransfer = { [weak self] payload in
            guard let self else { throw VellixError.editorBridge("The source editor is unavailable.") }
            try await self.transferDroppedBlocks(payload)
        }
        session.onValidateBlockDrop = { [weak self] destinationID, pageIDs in
            guard let self, !self.documentID.isEmpty else { return false }
            let repository = self.documentRepository, sourceID = self.documentID
            return await Task.detached(priority: .userInitiated) {
                do { try repository.validateBlockDropTarget(sourceID: sourceID, destinationID: destinationID, movingPageIDs: pageIDs); return true }
                catch { return false }
            }.value
        }
        session.documentForRecovery = { [weak self] in
            guard let self, let document = self.document else { return nil }
            return (document.id, self.latestJSON ?? document.tipTapJSON)
        }
    }

    // Duplicating or pasting a page card must yield a page the copy owns on its
    // own, not a second reference to the original. For each duplicated/pasted
    // card, clone the source page into an independent tree (cloneTree deep-copies
    // the page, its nested sub-pages and attachments and regenerates every inner
    // block id), re-parent the clone under this document, and repoint the card at
    // it. If the source page can't be cloned here, drop the card.
    func cloneDuplicatedPageReferences(_ pairs: [[String: String]]) async {
        guard let parentID = document?.id else { return }
        var changed = false
        for pair in pairs {
            guard let blockID = pair["blockId"], let source = pair["sourceDocumentID"] else { continue }
            do {
                var clone = try documentRepository.duplicate(id: source, attachmentStore: attachmentStore)
                if clone.parentDocumentID != parentID {
                    clone = try documentRepository.move(id: clone.id, spaceID: clone.spaceID,
                        folderID: clone.folderID, parentDocumentID: parentID)
                }
                session.applyClonedPageReference(blockID: blockID, documentID: clone.id)
                changed = true
            } catch {
                session.applyClonedPageReference(blockID: blockID, documentID: nil)
            }
        }
        if changed { refreshRelated() }
    }

    func deleteAttachment(_ request: AttachmentActionRequest) async {
        guard documentID == request.documentID else { return }
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        do {
            guard try await session.attachmentCommand("attachmentDelete", args: ["blockID": request.attachment.blockID]) as? Bool == true else {
                throw VellixError.editorBridge("This file block is no longer available.")
            }
        } catch {
            if documentID == request.documentID { errorMessage = error.localizedDescription }
        }
    }

    func importAttachments(urls: [URL] = [], data: [AttachmentImportData] = [], token: String?) async {
        guard let document, let attachmentStore, session.editingEnabled else { return }
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        let repository = documentRepository.attachmentRepository(store: attachmentStore)
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        var inserted: [AttachmentRecord] = []
        do {
            var records = try await Task.detached(priority: .userInitiated) {
                var records: [AttachmentRecord] = []
                do {
                    for url in urls { records.append(try attachmentStore.importFile(at: url, documentID: document.id)) }
                    for file in data { records.append(try attachmentStore.importData(file.data, originalFileName: file.name, mimeType: file.mimeType, documentID: document.id)) }
                    return records
                } catch {
                    for record in records { try? attachmentStore.removeFile(relativePath: record.relativePath) }
                    throw error
                }
            }.value
            for index in records.indices { records[index].thumbnailRelativePath = await attachmentStore.makeEditorThumbnail(for: records[index]) }
            guard self.document?.id == document.id else {
                for path in records.flatMap(\.storedPaths) { try? attachmentStore.removeFile(relativePath: path) }
                return
            }
            do { try repository.registerImported(records, documentID: document.id) }
            catch {
                for path in records.flatMap(\.storedPaths) { try? attachmentStore.removeFile(relativePath: path) }
                throw error
            }
            session.refreshAttachments(documentID: document.id, json: latestJSON ?? document.tipTapJSON)
            for record in records {
                guard let file = session.attachmentFiles.first(where: { $0.id == record.id }) else { throw VellixError.attachmentImport("The imported file could not be resolved.") }
                var args: [String: Any] = ["file": file.object]
                if let token { args["token"] = token }
                guard try await session.attachmentCommand("attachmentInsert", args: args) as? Bool == true else {
                    for pending in records where !inserted.contains(where: { $0.id == pending.id }) { try? repository.delete(id: pending.id) }
                    throw VellixError.editorBridge("The insertion point changed. Please insert the file again.")
                }
                inserted.append(record)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func prepare(document input: DocumentRecord, readOnlyWarmup: Bool = false) {
        let openingPrewarmedDocument = document?.id == input.id && isReadOnlyWarmup && !readOnlyWarmup
        guard document?.id != input.id || openingPrewarmedDocument else { return }

        flushPendingSave()
        let record: DocumentRecord
        do {
            if readOnlyWarmup { record = input }
            else { record = try PageReferenceLifecycle.prepareForEditing(input, repository: documentRepository) }
        }
        catch { errorMessage = error.localizedDescription; return }
        let reloadContent = openingPrewarmedDocument && (warmupNeedsReload || latestJSON != record.tipTapJSON)
        warmupNeedsReload = false
        isReadOnlyWarmup = readOnlyWarmup
        pageReferenceLifecycle.reset()
        templateChangeVersion = 0
        confirmedTemplateChangeVersion = nil
        document = record
        taskContext = nil
        taskEditorRequest = nil
        taskHistoryRequest = nil
        attachmentEditorRequest = nil
        attachmentActionRequest = nil
        templateComponentRequest = nil
        templateInsertionRequest = nil
        placeholderConversionToken = nil
        templateNeedsSave = record.templateID != nil
        session.configureDocumentContext(documentID: record.id, templateID: record.templateID)
        latestJSON = record.tipTapJSON
        pageReferenceIDs = TipTapContentAnalyzer.pageReferenceIDs(in: record.tipTapJSON)
        session.saveState = .saved(record.updatedAt)
        refreshLibraryContext(currentDocument: record)
        session.setAppearance(appearance)
        session.load(documentID: record.id, canonicalJSON: record.tipTapJSON, force: reloadContent)
        syncLinkedCalendarEvents()
    }

    func rename(title: String) {
        guard let document else {
            return
        }

        do {
            let updated = try documentRepository.updateTitle(id: document.id, title: title)
            self.document = updated
            onDocumentSaved?(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateAppearance(cover: String?, appearance: DocumentAppearance) {
        guard let document else {
            return
        }

        do {
            let updated = try documentRepository.updateAppearance(
                id: document.id,
                cover: cover,
                appearance: appearance
            )
            self.document = updated
            self.appearance = appearance
            session.setAppearance(appearance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateIcon(_ icon: String?) {
        guard let document else {
            return
        }

        do {
            self.document = try documentRepository.updateIcon(id: document.id, icon: icon)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createChild() -> DocumentRecord? {
        guard let document else {
            return nil
        }

        do {
            let child = try documentRepository.create(
                DocumentDraft(
                    title: "Untitled",
                    spaceID: document.spaceID,
                    folderID: document.folderID,
                    parentDocumentID: document.id
                )
            )
            refreshRelated()
            onChildCreated?(child)
            return child
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func createManualSnapshot() {
        guard let document else {
            return
        }

        do {
            let current = try documentRepository.requireDocument(id: document.id)
            _ = try snapshotRepository.create(document: current, reason: .manual)
            refreshRelated()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore(_ snapshot: DocumentSnapshotRecord) {
        flushPendingSave()
        do {
            let restored = try snapshotRepository.restore(snapshotID: snapshot.id)
            document = restored
            latestJSON = restored.tipTapJSON
            pageReferenceIDs = TipTapContentAnalyzer.pageReferenceIDs(in: restored.tipTapJSON)
            onDocumentSaved?(restored)
            session.load(documentID: restored.id, canonicalJSON: restored.tipTapJSON, force: true)
            refreshRelated()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func flushPendingSave() {
        pendingSaveTask?.cancel()
        guard let id = pendingDocumentID, let json = latestJSON else {
            return
        }
        persistEditorJSON(documentID: id, canonicalJSON: json)
        pendingDocumentID = nil
    }

    func saveCurrentContent() throws {
        guard !isReadOnlyWarmup, let document else { return }
        pendingSaveTask?.cancel()
        saveSequence += 1
        let repository = documentRepository, json = latestJSON ?? document.tipTapJSON
        let updated = try persistenceQueue.sync { try repository.saveEditorJSON(id: document.id, canonicalJSON: json) }
        pendingDocumentID = nil
        self.document = updated
        session.saveState = .saved(updated.updatedAt)
        onDocumentSaved?(updated)
    }

    func captureAndSave(suspendingEditing: Bool = false, preservingBlockSelection: Bool = false) async throws {
        guard !isReadOnlyWarmup else { return }
        if PennedSyncTrace.documentID == document?.id {
            PennedSyncTrace.record("editor.captureAndSave", "suspendingEditing=\(suspendingEditing) ready=\(session.isReady)")
        }
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        if let json = try await session.currentJSON(suspendingEditing: suspendingEditing,
                                                    preservingBlockSelection: preservingBlockSelection) { latestJSON = json }
        try saveCurrentContent()
    }

    func saveGridCard(_ request: GridCardSettingsRequest, settings: GridCardSettings) async throws {
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        latestJSON = try await session.commitGridCard(request, settings: settings, documentID: documentID)
        try saveCurrentContent()
    }

    func saveIconCallout(_ request: IconCalloutSettingsRequest, settings: IconCalloutSettings, text: String?, data: Data?) async throws {
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        let id = documentID
        guard !isReadOnlyWarmup, !id.isEmpty, iconCalloutSettingsRequest?.id == request.id,
              session.editingEnabled, session.isReady, !session.isLoadingDocument else {
            throw VellixError.editorBridge("This document is no longer open for editing.")
        }
        var draft = settings
        if let data {
            guard let attachmentStore else { throw VellixError.attachmentImport("The icon image store is unavailable.") }
            let repository = documentRepository.attachmentRepository(store: attachmentStore)
            let file = try repository.importData(data, originalFileName: "Callout Icon.png", mimeType: "image/png", documentID: id)
            draft.imagePath = file.relativePath
            session.refreshAttachments(documentID: id, json: latestJSON ?? document?.tipTapJSON ?? "")
        }
        latestJSON = try await session.commitIconCallout(request, settings: draft, text: text, documentID: id)
        try saveCurrentContent()
    }

    func saveWashiTape(_ request: WashiTapeRequest, imagePath: String?, photo: CardRemotePhoto?, data: Data?, tapeSize: WashiTapeSize) async throws {
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        let id = documentID
        if let photo, photo.id != request.remotePhoto?.id {
            try await CardPhotoService().trackSelection(photo)
        }
        guard document?.id == id, washiTapeRequest?.id == request.id, session.editingEnabled, session.isReady, !session.isLoadingDocument else {
            throw VellixError.editorBridge("This document is no longer open for editing.")
        }
        var path = imagePath
        if let data {
            guard let attachmentStore else { throw VellixError.attachmentImport("The tape image store is unavailable.") }
            let repository = documentRepository.attachmentRepository(store: attachmentStore)
            let file = try repository.importData(data, originalFileName: "Washi Tape.png", mimeType: "image/png", documentID: id)
            path = file.relativePath
            session.refreshAttachments(documentID: id, json: latestJSON ?? document?.tipTapJSON ?? "")
        }
        latestJSON = try await session.commitWashiTape(request, imagePath: path, photo: photo, tapeSize: tapeSize, documentID: id)
        try saveCurrentContent()
    }

    func saveHeadingLabel(_ request: HeadingLabelRequest, settings: HeadingLabelSettings, text: String) async throws {
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        latestJSON = try await session.commitHeadingLabel(request, settings: settings, text: text, documentID: documentID)
        try saveCurrentContent()
    }

    func saveCodeBlock(_ request: CodeBlockEditorRequest, draft: CodeBlockConfiguration) async throws {
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        latestJSON = try await session.commitCodeBlock(request, draft: draft, documentID: documentID)
        try saveCurrentContent()
    }

    @discardableResult
    func saveTemplateEdits() async throws -> Bool {
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        guard let document, document.templateID != nil, templateNeedsSave, !isSavingTemplate else { return false }
        let id = document.id
        let versionAtRequest = templateChangeVersion
        isSavingTemplate = true
        defer { isSavingTemplate = false }

        let json = try await session.currentJSON() ?? latestJSON ?? document.tipTapJSON
        guard self.document?.id == id else { throw VellixError.documentNotFound(id) }
        let changedDuringCapture = templateChangeVersion != versionAtRequest
        pendingSaveTask?.cancel()
        saveSequence += 1
        let repository = documentRepository
        let updated = try persistenceQueue.sync { try repository.saveEditorJSON(id: id, canonicalJSON: json) }
        if !changedDuringCapture { latestJSON = updated.tipTapJSON }
        self.document = updated
        confirmedTemplateChangeVersion = changedDuringCapture ? versionAtRequest : templateChangeVersion
        templateNeedsSave = templateChangeVersion != confirmedTemplateChangeVersion
        pendingDocumentID = nil
        session.saveState = .saved(updated.updatedAt)
        onDocumentSaved?(updated)

        // Keep edits arriving during the snapshot request; they are not acknowledged by this save.
        if changedDuringCapture, let latestJSON { scheduleSave(latestJSON) }
        return true
    }

    func noteTemplateChange() {
        guard document?.templateID != nil else { return }
        templateChangeVersion += 1
        templateNeedsSave = templateChangeVersion != confirmedTemplateChangeVersion
    }

    func discardPendingSave() {
        saveSequence += 1
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        pendingDocumentID = nil
        latestJSON = nil
    }

    private func handle(_ event: TipTapEditorEvent) {
        if isReadOnlyWarmup {
            switch event {
            case .documentTextChanged(let json), .documentChanged(let json), .documentSnapshot(let json),
                 .taskDocumentSnapshot(let json), .tableDocumentSnapshot(let json):
                if json != latestJSON { warmupNeedsReload = true }
            case .editorError(let message): errorMessage = message
            default: break
            }
            return
        }
        switch event {
        case .requestTemplates(let token):
            guard session.isReady, !session.isLoadingDocument, session.editingEnabled, !documentID.isEmpty else { return }
            templateInsertionRequest = TemplateInsertionRequest(documentID: documentID, token: token)
        case .attachmentClipboard(let token, let html, let text, let nativeJSON):
            // A private, versioned Penned clipboard representation travels alongside
            // interoperable HTML and plain text. Paste reconstruction is separate.
            let pennedBlockType = "im.lystaria.penned.blocks+json"
            #if canImport(UIKit)
            UIPasteboard.general.items = [[
                pennedBlockType: Data(nativeJSON.utf8),
                "public.html": Data(html.utf8),
                "public.utf8-plain-text": text
            ]]
            let success = true
            #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            let nativeWritten = NSPasteboard.general.setData(Data(nativeJSON.utf8),
                forType: NSPasteboard.PasteboardType(pennedBlockType))
            let htmlWritten = NSPasteboard.general.setString(html, forType: .html)
            if htmlWritten { NSPasteboard.general.setString(text, forType: .string) }
            let success = nativeWritten && htmlWritten
            #else
            let success = false
            #endif
            session.finishAttachmentClipboard(token: token, success: success)
        case .requestAttachment(let request):
            guard EditorAttachment.paths(in: latestJSON ?? document?.tipTapJSON ?? "").contains(request.relativePath) else { return }
            attachmentEditorRequest = request
        case .requestAttachmentActions(let request):
            guard !documentID.isEmpty,
                  EditorAttachment.paths(in: latestJSON ?? document?.tipTapJSON ?? "").contains(request.relativePath) else { return }
            attachmentActionRequest = AttachmentActionRequest(documentID: documentID, attachment: request)
        case .importAttachments(let token, let files):
            Task { await importAttachments(data: files, token: token) }
        case .requestTemplateComponent(let request):
            guard document?.templateID != nil else { return }
            templateComponentRequest = request
        case .requestTableCreation:
            tableEditorRequest = TableEditorRequest(mode: .create)
        case .requestTableMenu(let context):
            tableContext = context
            tableEditorRequest = TableEditorRequest(mode: .edit(context))
        case .tableStateChanged(let context): tableContext = context
        case .taskStateChanged(let context): taskContext = context
        case .requestTaskMenu(let context):
            taskContext = context
            openTaskScheduling()
        case .requestTaskCompletion(let context, let completed, let skipped):
            guard let task = context.metadata else { return }
            do {
                let result = try task.completing(completed, skipped: skipped, text: context.text)
                session.taskCommand("taskComplete", context: context, values: [
                    "expectedOccurrenceID": task.occurrenceID, "task": result.metadata.object, "checked": result.checked
                ])
            } catch {
                session.taskCommand("taskRelease", context: context)
                errorMessage = error.localizedDescription
            }
        case .tableDocumentSnapshot(let json), .taskDocumentSnapshot(let json):
            latestJSON = json
            updatePageReferences(from: json)
            pendingDocumentID = document?.id
            do {
                try saveCurrentContent()
                refreshRelated()
            } catch {
                session.saveState = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        case .tableFormulaPreview(let result): tableFormulaPreview = result
        case .tableClipboard(let text, let cut):
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
            if cut { session.tableAction("clearContents", tableID: tableContext?.tableID) }
        case .documentTextChanged(let json):
            // The web editor already debounced this text-only checkpoint.
            // Its block references and asset paths did not change.
            if latestJSON != json { scheduleSave(json, immediate: true, reconcileReferences: false) }
        case .documentChanged(let json):
            // EditorAttachment.paths parses and walks the entire document. Skip that
            // whole-document work when the payload cannot reference an attachment.
            if json.contains("attachment") || json.contains("clipSource") || json.contains("\"iconCallout\""),
               !EditorAttachment.paths(in: json).isSubset(of: Set(session.attachmentFiles.map { $0.record.relativePath })) {
                session.refreshAttachments(documentID: documentID, json: json)
            }
            scheduleSave(json)
            syncLinkedCalendarEvents()
        case .documentSnapshot(let json):
            if !EditorAttachment.paths(in: json).isSubset(of: Set(session.attachmentFiles.map { $0.record.relativePath })) {
                session.refreshAttachments(documentID: documentID, json: json)
            }
            scheduleSave(json, immediate: true)
            syncLinkedCalendarEvents()
        case .editorError(let message):
            errorMessage = message
        case .requestPlaceholderConversion(let token):
            guard document?.templateID != nil, session.templateEditing, session.placeholderMode else { return }
            placeholderConversionToken = token
        case .requestGridCardSettings(let request):
            gridCardSettingsRequest = request
        case .requestIconCalloutSettings(let request):
            session.endWebEditingForSettings()
            iconCalloutSettingsRequest = request
        case .requestWashiTapeSettings(let request):
            guard session.editingEnabled, session.selectionMode == "off" else { return }
            session.endWebEditingForSettings()
            washiTapeRequest = request
        case .requestHeadingLabelSettings(let request):
            session.endWebEditingForSettings()
            headingLabelSettingsRequest = request
        case .requestBlockquoteColorPicker(let blockID, let color):
            blockquoteColorRequest = BlockquoteColorRequest(blockID: blockID, color: color)
        case .requestInlinePropertyEditor(let blockID, let property, let resumeEditing):
            propertyEditorRequests.send(InlinePropertyEditorRequest(blockID: blockID, property: property, resumeEditing: resumeEditing))
        case .requestCollection(let request):
            collectionEditorRequest = request
        case .requestPropertyURL(let url):
            propertyURLRequest = InlinePropertyURLRequest(url: url)
        case .requestBlockConversion(let request):
            if request.target == "link" || request.target == "file" {
                blockConversionRequest = request
            } else if ["nestedPage", "pageCard"].contains(request.target) {
                if !request.documentIDs.isEmpty {
                    do {
                        let pages = try documentRepository.setNestedPageCardPresentation(parentID: documentID,
                            documentIDs: request.documentIDs, asCard: request.target == "pageCard")
                        refreshRelated()
                        for page in pages { onDocumentSaved?(page) }
                    } catch { errorMessage = error.localizedDescription }
                } else if let json = request.canonicalJSON, let parent = document {
                    Task { @MainActor in
                        let operation = beginPersistentOperation()
                        defer { endPersistentOperation(operation) }
                        do {
                            let child = try await PageReferenceLifecycle.createGroupedChild(json: json, parent: parent,
                                repository: documentRepository) { childID in
                                if request.target == "pageCard" {
                                    _ = try self.documentRepository.setNestedPageCardPresentation(parentID: parent.id,
                                        documentIDs: [childID], asCard: true)
                                }
                                guard self.document?.id == parent.id, self.session.renderedDocumentID == parent.id else { return false }
                                return try await self.session.attachmentCommand("finishBlockConversionPage",
                                    args: ["token": request.token, "documentID": childID]) as? Bool == true
                            }
                            refreshRelated()
                            onChildCreated?(try documentRepository.requireDocument(id: child.id))
                        } catch { refreshRelated(); errorMessage = error.localizedDescription }
                    }
                }
            }
        case .requestNestedPage(let blockID):
            guard !blockID.isEmpty else { return }
            let child = createChild()
            if let child { pageReferenceIDs.insert(child.id) }
            session.resolvePageReference(blockID: blockID, documentID: child?.id)
        case .requestPageCard(let blockID):
            guard !blockID.isEmpty, cardEditorRequest == nil, document != nil else { return }
            pendingCardBlockID = blockID
            cardEditorRequest = PageCardEditorRequest(blockID: blockID, document: DocumentRecord(title: "Untitled"))
        case .requestOpenPage(let documentID):
            if let taskID = DocumentTaskPages.taskID(for: documentID) {
                do {
                    guard let task = try documentRepository.taskForHistoryPage(id: documentID),
                          task.documentID == self.documentID || DocumentTaskPages.taskID(for: self.documentID) == taskID else { return }
                    taskHistoryRequest = TaskHistorySheetRequest(task: task)
                } catch { errorMessage = error.localizedDescription }
                return
            }
            refreshRelated()
            guard let child = children.first(where: { $0.id == documentID }),
                  child.parentDocumentID == document?.id else { return }
            onOpenNestedPage?(child)
        case .requestPageActions(let documentID):
            guard let child = children.first(where: { $0.id == documentID }),
                  child.parentDocumentID == document?.id else { return }
            nestedPageActionTarget = child
        case .requestPageCardSettings(let documentID):
            guard cardEditorRequest == nil, let child = children.first(where: { $0.id == documentID }),
                  child.parentDocumentID == document?.id, !child.isTrashed else { return }
            session.endWebEditingForSettings()
            editPageCard(child)
        case .requestBlockDeletion(let token, _, _):
            blockDeletionRequest = BlockDeletionRequest(documentID: documentID, token: token)
        case .requestListGridSettings(let settings):
            guard listGridSettingsRequest == nil, session.editingEnabled, session.selectionMode == "off",
                  session.renderedDocumentID == documentID else { return }
            session.endWebEditingForSettings()
            listGridSettingsRequest = settings
        case .requestCodeBlockEditor(let request):
            session.endWebEditingForSettings()
            codeBlockEditorRequest = request
        case .openLinkedCalendarEvent(let eventID, let identity, let start):
            guard linkedCalendarEventRequest == nil else { return }
            linkedCalendarEventRequest = LinkedCalendarEventRequest(eventID: eventID, identity: identity, start: start)
        case .requestExistingEventPicker:
            guard existingEventPickerRequest == nil else { return }
            session.endWebEditingForSettings()
            existingEventPickerRequest = ExistingEventPickerRequest()
        case .requestWeekStripSettings(let request):
            guard weekStripSettingsRequest == nil else { return }
            session.endWebEditingForSettings()
            weekStripSettingsRequest = request
        case .requestTabsSettings(let settings):
            guard tabsSettingsRequest == nil else { return }
            session.endWebEditingForSettings()
            tabsSettingsRequest = settings
        case .requestInformationCardSettings(let settings):
            session.endWebEditingForSettings()
            informationCardSettingsRequest = settings
        case .requestMinimalFieldsSettings(let settings):
            session.endWebEditingForSettings()
            minimalFieldsSettingsRequest = settings
        case .selectedBlocksForSubpage(let token, let json):
            let parentID = documentID
            Task { await createChildFromSelectedBlocks(token: token, parentID: parentID, canonicalJSON: json) }
        default:
            break
        }
    }

    func groupSelectedBlocksIntoChildPage() {
        session.requestSelectedBlocksForSubpage()
    }

    func openTaskScheduling() {
        guard let context = taskContext else { return }
        session.endWebEditingForSettings()
        taskEditorRequest = TaskEditorRequest(context: context)
    }

    func convertChecklist(_ context: DocumentTaskContext, toTask: Bool) {
        session.taskCommand("taskConvert", context: context, values: [
            "enabled": toTask, "task": DocumentTaskMetadata().object
        ])
    }

    func configureTask(_ context: DocumentTaskContext, reminder: Bool, scheduledDate: Date?, recurrence: TaskRepeatRule?) async throws {
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        guard context.metadata != nil else { throw DocumentTaskError.missingTask }
        try await session.configureTask(context, configuration: [
            "reminderEnabled": reminder,
            "scheduledAt": scheduledDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "recurrence": recurrence.map { rule in
                (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(rule))) ?? NSNull()
            } ?? NSNull()
        ])
        try await captureAndSave()
    }

    func receiveExternalTaskChange(_ record: DocumentRecord) {
        guard document?.id == record.id else { return }
        latestJSON = record.tipTapJSON
        document = record
        if !session.isReady || session.isLoadingDocument {
            session.load(documentID: record.id, canonicalJSON: record.tipTapJSON, force: true)
            session.saveState = .saved(record.updatedAt)
            return
        }
        // External task actions use the same block attributes and ProseMirror history.
        for context in (try? DocumentTaskIndex.contexts(in: record.tipTapJSON)) ?? [] {
            guard let task = context.metadata else { continue }
            session.taskCommand("taskComplete", context: context, values: [
                "expectedOccurrenceID": "", "external": true, "task": task.object, "checked": context.checked
            ])
        }
        session.saveState = .saved(record.updatedAt)
    }

    func editPageCard(_ page: DocumentRecord) {
        guard page.parentDocumentID == document?.id, !page.isTrashed else { return }
        cardEditorRequest = PageCardEditorRequest(blockID: nil, document: page)
    }

    func cancelCardInsertion() {
        if let pendingCardBlockID {
            session.resolvePageReference(blockID: pendingCardBlockID, documentID: nil)
        }
        pendingCardBlockID = nil
    }

    func clearEditorPresentationRequests() {
        session.cancelBlockConversion()
        func clear<Value>(_ keyPath: ReferenceWritableKeyPath<DocumentEditorModel, Value?>) {
            if self[keyPath: keyPath] != nil { self[keyPath: keyPath] = nil }
        }
        session.tagRequest = nil
        clear(\.gridCardSettingsRequest)
        clear(\.iconCalloutSettingsRequest)
        clear(\.washiTapeRequest)
        clear(\.headingLabelSettingsRequest)
        clear(\.blockquoteColorRequest)
        clear(\.templateComponentRequest)
        clear(\.templateInsertionRequest)
        clear(\.attachmentEditorRequest)
        clear(\.attachmentActionRequest)
        clear(\.collectionEditorRequest)
        clear(\.propertyURLRequest)
        clear(\.nestedPageActionTarget)
        if let request = blockDeletionRequest { session.dismissBlockActions(requestToken: request.token) }
        clear(\.blockDeletionRequest)
        clear(\.listGridSettingsRequest)
        clear(\.codeBlockEditorRequest)
        clear(\.tabsSettingsRequest)
        clear(\.weekStripSettingsRequest)
        clear(\.existingEventPickerRequest)
        clear(\.linkedCalendarEventRequest)
        clear(\.minimalFieldsSettingsRequest)
        clear(\.informationCardSettingsRequest)
        if cardEditorRequest != nil { cancelCardInsertion() }
        clear(\.cardEditorRequest)
        if placeholderConversionToken != nil { session.cancelPlaceholderConversion() }
        clear(\.placeholderConversionToken)
        clear(\.blockConversionRequest)
        if tableEditorRequest != nil { session.tableAction("close") }
        clear(\.tableEditorRequest)
        clear(\.taskEditorRequest)
        clear(\.taskHistoryRequest)
    }

    func savePageCard(request: PageCardEditorRequest, style: PageCardStyle, imageData: Data?) async throws {
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        guard let parent = document, let attachmentStore else {
            throw VellixError.impossibleMove("The card image store is unavailable.")
        }
        if style.backdrop == .photo, let photo = style.remotePhoto,
           photo != (request.document.cardStyle?.backdrop == .photo ? request.document.cardStyle?.remotePhoto : nil) {
            try await CardPhotoService().trackSelection(photo)
        }
        guard document?.id == parent.id,
              request.blockID == nil || pendingCardBlockID == request.blockID else {
            throw VellixError.impossibleMove("The document changed while this card was being configured.")
        }
        let page = try documentRepository.savePageCard(parentID: parent.id,
            documentID: request.blockID == nil ? request.document.id : nil,
            style: style, imageData: imageData, attachmentStore: attachmentStore)
        if let blockID = request.blockID {
            pendingCardBlockID = nil
            pageReferenceIDs.insert(page.id)
            refreshRelated()
            onChildCreated?(page)
            session.resolvePageReference(blockID: blockID, documentID: page.id)
        } else {
            refreshRelated()
            onDocumentSaved?(page)
        }
    }

    func trashChildPage(id: String) {
        guard let child = children.first(where: { $0.id == id }),
              child.parentDocumentID == document?.id else { return }
        do {
            let current = try documentRepository.requireDocument(id: id)
            guard current.parentDocumentID == document?.id, !current.isTrashed else {
                refreshRelated()
                return
            }
            _ = try documentRepository.trash(id: id)
            refreshRelated()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createChildFromSelectedBlocks(token: String, parentID: String, canonicalJSON: String) async {
        guard let document, document.id == parentID, session.renderedDocumentID == parentID, !session.isLoadingDocument else { return }
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        do {
            let child = try await PageReferenceLifecycle.createGroupedChild(json: canonicalJSON,
                parent: document, repository: documentRepository) { childID in
                try await self.session.placeGroupedPage(token: token, documentID: childID, parentID: document.id)
            }
            refreshRelated()
            onChildCreated?(child)
        } catch {
            refreshRelated()
            errorMessage = error.localizedDescription
        }
    }

    private func transferDroppedBlocks(_ payload: [String: Any]) async throws {
        guard !isReadOnlyWarmup, let source = document, session.acceptsEditorPresentationRequests,
              let token = payload["token"] as? String, let forward = payload["forward"] as? Bool,
              let before = payload["sourceBefore"] as? [String: Any],
              let after = payload["sourceAfter"] as? [String: Any] else {
            throw VellixError.editorBridge("The block drop request is no longer valid.")
        }
        let prior = blockDropTransfers[token]
        guard prior != nil || (payload["destinationID"] as? String != nil && forward) else {
            throw VellixError.editorBridge("The move's undo information is no longer available.")
        }
        let destinationID = prior?.destinationID ?? payload["destinationID"] as? String ?? ""
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        try await prepareBlockDropDestination?(destinationID)
        try await captureAndSave(preservingBlockSelection: true)
        guard documentID == source.id, session.renderedDocumentID == source.id, !session.isLoadingDocument else {
            throw VellixError.editorBridge("The source document changed during the drop.")
        }
        let sourceBefore = String(decoding: try JSONSerialization.data(withJSONObject: before, options: [.sortedKeys]), as: UTF8.self)
        let sourceAfter = String(decoding: try JSONSerialization.data(withJSONObject: after, options: [.sortedKeys]), as: UTF8.self)
        let blocksJSON = try (payload["blocks"] as? [[String: Any]]).map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }
        pendingSaveTask?.cancel()
        saveSequence += 1
        let repository = documentRepository
        let result: BlockDropTransferResult = try await withCheckedThrowingContinuation { continuation in
            persistenceQueue.async {
                do {
                    continuation.resume(returning: try repository.transferDroppedBlocks(sourceID: source.id,
                        sourceBefore: sourceBefore, sourceAfter: sourceAfter, destinationID: destinationID,
                        blocksJSON: blocksJSON, checkpoint: prior, forward: forward))
                } catch { continuation.resume(throwing: error) }
            }
        }
        blockDropTransfers[token] = result.checkpoint
        latestJSON = result.source.tipTapJSON
        document = result.source
        pendingDocumentID = nil
        pageReferenceIDs = TipTapContentAnalyzer.pageReferenceIDs(in: result.source.tipTapJSON)
        session.saveState = .saved(result.source.updatedAt)
        session.refreshAttachments(documentID: source.id, json: result.source.tipTapJSON)
        await blockDropRecordSaved?(result.destination, true)
        for page in result.movedPages {
            await blockDropRecordSaved?(page, false)
            onDocumentSaved?(page)
        }
        onDocumentSaved?(result.destination)
        onDocumentSaved?(result.source)
        refreshRelated()
    }

    func adoptBlockDropRecord(_ record: DocumentRecord, contentChanged: Bool) async {
        guard documentID == record.id else { return }
        guard contentChanged else { refreshLibraryContext(currentDocument: record); return }
        pendingSaveTask?.cancel()
        saveSequence += 1
        latestJSON = record.tipTapJSON
        document = record
        pendingDocumentID = nil
        pageReferenceIDs = TipTapContentAnalyzer.pageReferenceIDs(in: record.tipTapJSON)
        session.refreshAttachments(documentID: record.id, json: record.tipTapJSON)
        var applied = false
        #if os(iOS)
        applied = await session.applyExternalBlockDrop(record)
        #endif
        // Only an uninitialized or failed retained runtime needs full hydration.
        if !applied { session.load(documentID: record.id, canonicalJSON: record.tipTapJSON, force: true) }
        session.saveState = .saved(record.updatedAt)
        refreshLibraryContext(currentDocument: record)
    }

    private func updatePageReferences(from json: String) {
        let next = TipTapContentAnalyzer.pageReferenceIDs(in: json)
        guard next != pageReferenceIDs else { return }
        do {
            try pageReferenceLifecycle.reconcile(previous: pageReferenceIDs, next: next,
                parentID: documentID, repository: documentRepository)
        } catch { errorMessage = error.localizedDescription }
        pageReferenceIDs = next
        refreshRelated()
    }

    private func scheduleSave(_ json: String, immediate: Bool = false, reconcileReferences: Bool = true) {
        guard let document else { return }
        latestJSON = json
        if reconcileReferences { updatePageReferences(from: json) }
        pendingDocumentID = document.id
        if !immediate, session.saveState != .unsaved { session.saveState = .unsaved }
        pendingSaveTask?.cancel()

        pendingSaveTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 650_000_000)
            }
            guard !Task.isCancelled else {
                return
            }
            self?.savePending()
        }
    }

    private func savePending() {
        guard let id = pendingDocumentID, let json = latestJSON else { return }
        persistEditorJSON(documentID: id, canonicalJSON: json)
        pendingDocumentID = nil
    }

    private func persistEditorJSON(documentID: String, canonicalJSON: String) {
        saveSequence += 1
        let sequence = saveSequence
        let documentRepository = documentRepository
        let snapshotRepository = snapshotRepository
        let snapshotBaseRevision = lastAutomaticSnapshotRevision
        let operation = beginPersistentOperation()
        let generation = saveGeneration

        if session.saveState != .saving { session.saveState = .saving }

        persistenceQueue.async { [weak self] in
            guard generation.isCurrent(sequence) else {
                Task { @MainActor [weak self] in self?.endPersistentOperation(operation) }
                return
            }
            let result: Result<EditorSaveResult, Error>
            do {
                let updated = try documentRepository.saveEditorJSON(
                    id: documentID,
                    canonicalJSON: canonicalJSON
                )
                var snapshotRevision: Int?
                if updated.revision - snapshotBaseRevision >= 8 {
                    _ = try snapshotRepository.create(document: updated, reason: .automatic)
                    snapshotRevision = updated.revision
                }

                result = .success(
                    EditorSaveResult(
                        document: updated,
                        snapshotRevision: snapshotRevision
                    )
                )
            } catch {
                result = .failure(error)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.endPersistentOperation(operation) }
                self.finishEditorSave(result, sequence: sequence, submittedJSON: canonicalJSON)
            }
        }
    }

    private func finishEditorSave(
        _ result: Result<EditorSaveResult, Error>,
        sequence: Int,
        submittedJSON: String
    ) {
        guard sequence == saveSequence else { return }

        switch result {
        case .success(let saveResult):
            guard document?.id == saveResult.document.id else { return }
            if latestJSON == submittedJSON {
                // Do not let an older save overwrite text from a newer checkpoint.
                adoptingSavedCheckpoint = true
                latestJSON = saveResult.document.tipTapJSON
                adoptingSavedCheckpoint = false
            }
            if let snapshotRevision = saveResult.snapshotRevision {
                lastAutomaticSnapshotRevision = snapshotRevision
            }
            if document != saveResult.document {
                document = saveResult.document
                onDocumentSaved?(saveResult.document)
            }
            session.saveState = pendingDocumentID == nil ? .saved(saveResult.document.updatedAt) : .unsaved

        case .failure(let error):
            print("💾🚨 TRACE MODEL finish failure sequence=\(sequence) error=\(error.localizedDescription)")
            // A later flush may retry the latest snapshot after a transient failure.
            if pendingDocumentID == nil, latestJSON == submittedJSON { pendingDocumentID = document?.id }
            session.saveState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func updateChildDocument(_ saved: DocumentRecord) -> Bool {
        guard saved.parentDocumentID == document?.id,
              let index = children.firstIndex(where: { $0.id == saved.id }),
              children[index] != saved else { return false }
        let contentChanged = TemplatePageSaveContent(children[index]) != TemplatePageSaveContent(saved)
        children[index] = saved
        session.setPageReferences(children)
        return contentChanged
    }

    func refreshLibraryContext(currentDocument: DocumentRecord? = nil) {
        guard let document else { return }
        do {
            let current = try currentDocument ?? documentRepository.requireDocument(id: document.id)
            historyPageTask = try documentRepository.taskForHistoryPage(id: document.id)
            if DocumentTaskPages.isManaged(document.id), current.tipTapJSON != (latestJSON ?? document.tipTapJSON) {
                if session.isReady && !session.isLoadingDocument { session.refreshTaskHistory(current.tipTapJSON) }
                else {
                    latestJSON = current.tipTapJSON
                    session.load(documentID: current.id, canonicalJSON: current.tipTapJSON, force: true)
                }
            }
            if self.document != current { self.document = current }
            let effectiveAppearance = try documentRepository.effectiveAppearance(for: current)
            if appearance != effectiveAppearance {
                appearance = effectiveAppearance
                session.setAppearance(effectiveAppearance)
            }
            refreshRelated()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshTaskHistoryPage() {
        guard DocumentTaskPages.isManaged(documentID) else { return }
        refreshLibraryContext()
    }

    // Called only after the workspace has drained pending writes and applied a remote transaction.
    func reloadAfterLibrarySync() throws {
        guard let document else { return }
        let current = try documentRepository.requireDocument(id: document.id)
        let contentChanged = latestJSON != current.tipTapJSON
        #if DEBUG && os(iOS)
        PennedKeyboardTrace.record("sync.reloadAfterLibrarySync", session: session, "contentChanged=\(contentChanged)", live: true)
        #endif
        discardPendingSave()
        self.document = current
        latestJSON = current.tipTapJSON
        pageReferenceIDs = TipTapContentAnalyzer.pageReferenceIDs(in: current.tipTapJSON)
        session.refreshAttachments(documentID: current.id, json: current.tipTapJSON)
        if contentChanged { session.load(documentID: current.id, canonicalJSON: current.tipTapJSON, force: true) }
        session.saveState = .saved(current.updatedAt)
        refreshLibraryContext()
    }

    private func refreshRelated() {
        guard let document else {
            return
        }

        do {
            var currentChildren = try documentRepository.children(of: document.id, includingCollectionEntries: false)
            let existing = Set(currentChildren.map(\.id))
            for id in pageReferenceIDs where id != document.id && !existing.contains(id) {
                if let referenced = try documentRepository.document(id: id), referenced.parentDocumentID == document.id,
                   !referenced.isTrashed, !referenced.isArchived { currentChildren.append(referenced) }
            }
            if children != currentChildren { children = currentChildren }
            session.setPageReferences(currentChildren)
            snapshots = try snapshotRepository.history(documentID: document.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TemplatePageSaveContent: Equatable {
    let id: String
    let title: String
    let icon: String?
    let cover: String?
    let appearanceJSON: String?
    let cardStyleJSON: String?
    let tipTapJSON: String

    init(_ document: DocumentRecord) {
        id = document.id
        title = document.title
        icon = document.icon
        cover = document.cover
        appearanceJSON = document.appearanceJSON
        cardStyleJSON = document.cardStyleJSON
        tipTapJSON = document.tipTapJSON
    }
}

struct BlockDeletionRequest: Equatable {
    let documentID: String
    let token: String
}

struct BlockquoteColorRequest: Identifiable, Equatable {
    let id = UUID()
    var blockID: String
    var color: String
}

private struct EditorSaveResult: Sendable {
    var document: DocumentRecord
    var snapshotRevision: Int?
}

private nonisolated final class EditorSaveGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func set(_ next: Int) { lock.withLock { value = next } }
    func isCurrent(_ candidate: Int) -> Bool { lock.withLock { value == candidate } }
}
