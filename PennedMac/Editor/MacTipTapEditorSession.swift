// Mac-target platform adapter. Based on Vellix/Editor/TipTapEditorSession.swift.
// iPhone/iPad implementations remain in their original target.
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

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class TipTapEditorSession: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isLoadingDocument = false
    @Published private(set) var isPresentationReady = false
    private var presentation = DocumentPresentationState()
    private var presentationTask: Task<Void, Never>?
    private var confirmingFrameGeneration: Int?
    private var pendingNativePresentationHeights: [String: (viewID: String, height: CGFloat)] = [:]
    private var currentAppearance: DocumentAppearance?
    private(set) var applicationColorScheme: ColorScheme = .dark
    private var pageReferenceColorScheme: ColorScheme = .dark
    var preparesInteractivePresentation = true
    var presentationDiagnostics: String {
        "generation=\(presentation.generation) webPrepared=\(presentation.webPrepared) contentReady=\(presentation.isContentReady) snapshotPending=\(confirmingFrameGeneration != nil) nativePending=\(pendingNativePresentationHeights.count)"
    }
    @Published var saveState: TipTapSaveState = .idle
    @Published var bridgeErrorMessage: String?
    @Published var editorContentHeight: CGFloat = 320
    @Published var editorVisualContentBottom: CGFloat = 320
    @Published var selectedBlockCount = 0
    @Published var selectionMode = "off"
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
    private var templateEditing = false
    private(set) var editingEnabled = true

    var onEvent: ((TipTapEditorEvent) -> Void)?
    var documentForRecovery: (() -> (id: String, json: String)?)?

    private weak var webView: WKWebView?
    var tagNavigationWebView: WKWebView? { webView }
    private var loadedDocumentID: String?
    private var pendingDocument: (id: String, json: String)?
    private var recoveryDocument: (id: String, json: String)?
    private var preservesRecoveryPayload = false
    private var loadGeneration = 0
    private var textColorContext: (token: String, documentID: String, generation: Int)?
    private var textColorRequestGeneration = 0
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

    private func startupElapsedMS() -> Int {
        guard let startupStartTime else { return -1 }
        return Int((CFAbsoluteTimeGetCurrent() - startupStartTime) * 1000)
    }

    func attach(webView: WKWebView) {
        guard self.webView !== webView else {
            logger.info("🧭 TRACE TipTapEditorSession.attach ignored same webView")
            return
        }

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
        // A retained WKWebView can navigate again after its content process exits.
        // Requeue the model's latest text before clearing the old bridge state.
        preservesRecoveryPayload = preservesRecoveryPayload || loadedDocumentID != nil
        pendingDocument = documentForRecovery?() ?? pendingDocument ?? recoveryDocument
        loadGeneration += 1
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
        // SwiftUI checks this on every WebView update; no-op checks must not publish state or send bridge commands.
        if !force {
            if isReady, webView != nil, loadedDocumentID == documentID { return }
            if (!isReady || webView == nil), let pendingDocument, pendingDocument.id == documentID,
               pendingDocument.json == canonicalJSON || preservesRecoveryPayload { return }
        }
        preservesRecoveryPayload = false
        loadGeneration += 1
        let generation = loadGeneration
        logger.info("VELLIX-OPEN load id=\(documentID, privacy: .public) bytes=\(canonicalJSON.count) head=\(String(canonicalJSON.prefix(80)), privacy: .public)")
        recoveryDocument = (documentID, canonicalJSON)
        tagRequest = nil
        refreshAttachments(documentID: documentID, json: canonicalJSON)
        logger.info("📄 TRACE load request id=\(documentID, privacy: .public) ready=\(self.isReady) force=\(force) loaded=\(self.loadedDocumentID ?? "nil", privacy: .public) bytes=\(canonicalJSON.count)")
        guard isReady, webView != nil else {
            formattingState = TipTapFormattingState()
            logger.info("📄 TRACE load queued id=\(documentID, privacy: .public)")
            pendingDocument = (documentID, canonicalJSON)
            isLoadingDocument = true
            resetPresentation(documentID: documentID)
            awaitingRenderedDocumentID = documentID
            setRenderedDocumentID(nil)
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
        logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms icon registration start")
        registerIconAssets(editorIconNames(fromCanonicalJSON: canonicalJSON)) { [weak self] in
            guard let self, self.loadGeneration == generation, self.isReady else { return }
            self.logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms icon registration complete")
            self.logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms setContent send")
            self.send(TipTapEditorCommand.loadDocument(canonicalJSON: canonicalJSON)) { [weak self] result in
                guard let self, self.loadGeneration == generation, self.isReady else { return }
                self.logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms setContent completion")
                if case .failure = result {
                    self.finishDocumentLoad(result, generation: generation)
                    return
                }
                // setContent resets TipTap's selection mode/editability. Restore the
                // native lock state before exposing the newly loaded document.
                self.send(TipTapEditorCommand.setEditable(self.editingEnabled)) { [weak self] result in
                    self?.finishDocumentLoad(result, generation: generation)
                }
            }
        }
    }

    private func finishDocumentLoad(_ result: Result<Void, Error>, generation: Int) {
        guard loadGeneration == generation, isReady else {
            logger.info("VELLIX-OPEN finishDocumentLoad SKIP loadGen=\(self.loadGeneration) gen=\(generation) isReady=\(self.isReady)")
            return
        }
        isLoadingDocument = false
        if case .failure(let error) = result {
            pendingDocument = documentForRecovery?() ?? recoveryDocument
            loadedDocumentID = nil
            bridgeErrorMessage = error.localizedDescription
            logger.error("VELLIX-OPEN finishDocumentLoad FAIL error=\(error.localizedDescription, privacy: .public)")
            return
        }
        logger.info("VELLIX-OPEN finishDocumentLoad OK docID=\(self.loadedDocumentID ?? "nil", privacy: .public) -> preparePresentation")
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

    func setTemplateEditing(_ enabled: Bool) {
        templateEditing = enabled
        if !enabled { placeholderMode = false }
        guard isReady else { return }
        send(TipTapEditorCommand("setTemplateEditing", args: ["enabled": enabled]))
    }

    func togglePlaceholderMode() {
        guard templateEditing, isReady else { return }
        placeholderMode.toggle()
        send(TipTapEditorCommand("setPlaceholderMode", args: ["active": placeholderMode]))
    }

    func placeholderAction(_ action: String, token: String? = nil) {
        guard templateEditing else { return }
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

    func currentJSON(suspendingEditing: Bool = false) async throws -> String? {
        guard isReady, !isLoadingDocument, let loadedDocumentID, let webView else { return nil }
        let generation = loadGeneration
        let result = try await webView.callAsyncJavaScript("if (suspend) await window.tiptapCommand('setEditable', {editable: false}); return await window.tiptapCommand('getDocument', {});",
            arguments: ["suspend": suspendingEditing], in: nil, contentWorld: .page)
        guard loadGeneration == generation, isReady, !isLoadingDocument else { return nil }
        let json = try TipTapContentAnalyzer.normalizePayloadToJSON(result)
        recoveryDocument = (loadedDocumentID, json)
        return json
    }

    func focus() {
        send(TipTapEditorCommand.focusEditor())
    }

    func focusDocumentEnd() {
        send(TipTapEditorCommand.focusDocumentEnd())
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

    func setEditable(_ editable: Bool) {
        editingEnabled = editable
        if !editable { textConversionState = TipTapTextConversionState() }
        send(TipTapEditorCommand.setEditable(editable))
    }

    func setTheme(_ theme: String) {
        send(TipTapEditorCommand.setTheme(theme))
    }

    func setAppearance(_ appearance: DocumentAppearance) {
        currentAppearance = appearance
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
        setPageReferences(pageRecords)
    }

    func setPageReferences(_ records: [DocumentRecord]) {
        guard records != pageRecords || pageReferenceColorScheme != applicationColorScheme else { return }
        let schemeChanged = pageReferenceColorScheme != applicationColorScheme
        pageReferenceColorScheme = applicationColorScheme
        let previous = Dictionary(uniqueKeysWithValues: pageRecords.map { ($0.id, $0) })
        let presentations = Dictionary(uniqueKeysWithValues: pageReferencePayload.compactMap { payload -> (String, [String: Any])? in
            guard let id = payload["documentID"] as? String else { return nil }
            return (id, payload)
        })
        pageReferencePayload = records.map { record in
            if previous[record.id] == record, !(schemeChanged && record.appearance.isThemeDependent), let cached = presentations[record.id] { return cached }
            return PageReferencePresentation.bridgeObject(record, attachmentStore: attachmentStore, colorScheme: applicationColorScheme)
        }
        pageRecords = records
        if isReady { sendPageReferences() }
    }

    private func sendPageReferences() {
        send(TipTapEditorCommand("setPageReferences", args: ["pages": pageReferencePayload])) { [weak self] _ in self?.preparePresentation() }
    }

    func setCollections(_ payloads: [[String: Any]], preparingForDisplay: Bool = false) {
        // Do NOT tear down an editor that is already presentation-ready. It was shown and
        // confirmed once, so its WebKit pixels are valid. Re-running the off-screen snapshot
        // "proof of pixels" handshake for a warm model is unnecessary, and it deadlocks on iPad:
        // the editor is still at opacity 0 in the deck during the open (selectedDocumentID only
        // flips once it is marked ready), so takeSnapshot never calls back and the open hangs to
        // the 12s timeout ("This page could not be prepared"). Pushing the updated collections to
        // JS below re-renders the live editor in place, which is all a warm re-show needs.
        _ = preparingForDisplay
        collectionPayloads = payloads
        if isReady {
            let icons = Set(payloads.flatMap { ($0["fields"] as? [[String: Any]] ?? []).compactMap { $0["icon"] as? String } })
            registerIconAssets(icons) { [weak self] in
                guard let self else { return }
                self.send(TipTapEditorCommand("setCollections", args: ["collections": self.collectionPayloads])) { [weak self] _ in self?.preparePresentation() }
            }
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
        guard !isPresentationReady, presentation.isContentReady,
              let webView, webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        let generation = presentation.generation
        guard confirmingFrameGeneration != generation else { return }
        confirmingFrameGeneration = generation
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: min(900, webView.bounds.height))
        configuration.afterScreenUpdates = true
        // A JS layout frame is not proof that WebKit has produced displayable pixels.
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            guard let self, self.presentation.generation == generation else { return }
            self.logger.info("VELLIX-OPEN snapshot RETURNED image=\(image != nil) error=\(error?.localizedDescription ?? "none", privacy: .public)")
            self.confirmingFrameGeneration = nil
            guard image != nil else {
                self.bridgeErrorMessage = error?.localizedDescription ?? "The page could not be prepared for display."
                return
            }
            self.presentation.framePresented(generation: generation)
            self.isPresentationReady = self.presentation.isReady
        }
        // WKWebView.takeSnapshot(afterScreenUpdates:) can silently never call back when the
        // web view isn't on-screen yet (it is still at opacity 0 in the editor deck while it
        // prepares). Don't let that hang the open: the JS layout frame already confirms the
        // content is laid out, so present anyway if the snapshot hasn't returned promptly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.confirmingFrameGeneration == generation,
                  self.presentation.generation == generation, !self.isPresentationReady,
                  self.presentation.isContentReady else { return }
            self.confirmingFrameGeneration = nil
            self.presentation.framePresented(generation: generation)
            self.isPresentationReady = self.presentation.isReady
        }
    }

    func editorDidLayout() {
        confirmPresentationIfReady()
    }

    private func resetPresentation(documentID: String?) {
        textConversionState = TipTapTextConversionState()
        isConvertingSelectedText = false
        presentationTask?.cancel()
        confirmingFrameGeneration = nil
        presentation.begin(documentID: documentID)
        pendingNativePresentationHeights = [:]
        isPresentationReady = false
    }

    private func preparePresentation() {
        logger.info("VELLIX-OPEN preparePresentation enter interactive=\(self.preparesInteractivePresentation) isReady=\(self.isReady) loading=\(self.isLoadingDocument) presReady=\(self.isPresentationReady) hasWebView=\(self.webView != nil) docID=\(self.loadedDocumentID ?? "nil", privacy: .public)")
        guard preparesInteractivePresentation, isReady, !isLoadingDocument, !isPresentationReady, let webView, let documentID = loadedDocumentID else {
            logger.info("VELLIX-OPEN preparePresentation GUARD-FAIL (did not run)")
            return
        }
        presentationTask?.cancel()
        let generation = presentation.startPreparation()
        let args: [String: Any] = ["collections": collectionPayloads, "pages": pageReferencePayload, "files": attachmentFiles.map(\.object),
            "appearance": currentAppearance.map { TipTapEditorCommand.setAppearance($0.resolved(for: applicationColorScheme), interfaceScheme: applicationColorScheme).args } ?? [:]]
        let icons = Set(collectionPayloads.flatMap { ($0["fields"] as? [[String: Any]] ?? []).compactMap { $0["icon"] as? String } })
        presentationTask = Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            await withCheckedContinuation { continuation in self.registerIconAssets(icons) { continuation.resume() } }
            guard !Task.isCancelled, self.loadedDocumentID == documentID else { return }
            do {
                let result = try await webView.callAsyncJavaScript("return await window.tiptapCommand('preparePresentation', args);",
                    arguments: ["args": args], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
                guard !Task.isCancelled, self.loadedDocumentID == documentID else { return }
                var nativeViews: [String: String] = [:]
                for region in result["nativeViews"] as? [[String: String]] ?? [] {
                    if let block = region["blockID"], let view = region["viewID"] { nativeViews[block] = view }
                }
                self.pendingNativePresentationHeights = self.pendingNativePresentationHeights.filter {
                    nativeViews[$0.key] == $0.value.viewID
                }
                self.presentation.prepared(generation: generation, nativeViews: nativeViews)
                self.logger.info("VELLIX-OPEN prepared nativeViews=\(nativeViews.count) contentReady=\(self.presentation.isContentReady)")
                self.confirmPresentationIfReady()
                self.schedulePresentationWatchdog(generation: generation, documentID: documentID)
            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("VELLIX-OPEN preparePresentation JS ERROR=\(error.localizedDescription, privacy: .public)")
                self.bridgeErrorMessage = error.localizedDescription
            }
        }
    }

    // The content is laid out once preparePresentation returns, but presentation is gated
    // on every native collection/page region reporting its layout — which never happens
    // while the editor is still off-screen (opacity 0) warming in the editor deck. Don't
    // let that hang the open: if it hasn't presented shortly, force it through.
    private func schedulePresentationWatchdog(generation: Int, documentID: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.logger.info("VELLIX-OPEN watchdog fire gen=\(generation) presGen=\(self.presentation.generation) docMatch=\(self.loadedDocumentID == documentID) presReady=\(self.isPresentationReady) bounds=\(self.webView.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "nil")")
            guard self.presentation.generation == generation,
                  self.loadedDocumentID == documentID, !self.isPresentationReady,
                  let webView = self.webView, webView.bounds.width > 0, webView.bounds.height > 0 else { return }
            self.confirmingFrameGeneration = nil
            self.pendingNativePresentationHeights = [:]
            self.presentation.forceReady(generation: generation)
            self.isPresentationReady = self.presentation.isReady
            self.logger.info("VELLIX-OPEN watchdog FORCED presReady=\(self.isPresentationReady)")
        }
    }

    func cancelCollectionInsertion(_ blockID: String) {
        send(TipTapEditorCommand("resolveCollection", args: ["blockID": blockID, "collectionID": ""]))
    }

    func resolvePageReference(blockID: String, documentID: String?) {
        send(TipTapEditorCommand("resolvePageReference", args: ["blockId": blockID, "documentId": documentID ?? ""]))
    }

    func insertDivider(_ style: VellixDividerStyle) {
        send(TipTapEditorCommand.insertDivider(style))
    }

    func insertPageBreak() {
        send(TipTapEditorCommand.insertPageBreak())
    }

    func insertBlock(_ blockType: String) {
        if blockType == "callout" {
            registerIconAsset("sparkle") { [weak self] in
                self?.send(TipTapEditorCommand.insertBlock(blockType))
            }
            return
        }

        send(TipTapEditorCommand.insertBlock(blockType))
    }

    func insertCallout(icon: String, text: String, color: String = "#ffffff") {
        let icon = normalizedIconName(icon)
        registerIconAsset(icon) { [weak self] in
            self?.send(TipTapEditorCommand.insertCallout(icon: icon, text: text, color: color))
        }
    }

    func insertPlainCallout(color: String) {
        send(TipTapEditorCommand("insertBlock", args: ["blockType": "plainCallout", "color": color]))
    }

    func setSelectedBlockType(_ blockType: String, level: Int? = nil, color: String? = nil) {
        if blockType == "callout" {
            registerIconAsset("sparkle") { [weak self] in
                self?.send(TipTapEditorCommand.setSelectedBlockType(blockType, level: level, color: color))
            }
            return
        }

        send(TipTapEditorCommand.setSelectedBlockType(blockType, level: level, color: color))
    }

    func indentSelectedBlocks() {
        send(TipTapEditorCommand.indentSelectedBlocks())
    }

    func outdentSelectedBlocks() {
        send(TipTapEditorCommand.outdentSelectedBlocks())
    }

    func setSelectedCalloutColor(_ color: String) {
        send(TipTapEditorCommand.setSelectedCalloutColor(color))
    }

    func formatSelectedBlocks(action: String, value: String? = nil) {
        send(TipTapEditorCommand.formatSelectedBlocks(action: action, value: value))
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
        if target == "callout" { registerIconAsset("sparkle", completion: apply) }
        else { apply() }
    }

    func beginTextColorEditing() async throws -> InlineTextColorEditorRequest? {
        guard isReady, !isLoadingDocument, editingEnabled, selectionMode == "off", formattingState.canColorText,
              let documentID = loadedDocumentID else { return nil }
        textColorRequestGeneration += 1
        let requestGeneration = textColorRequestGeneration, generation = loadGeneration
        guard let value = try await attachmentCommand("textColorBegin", args: ["trackSelection": true]) as? [String: Any],
              let token = value["token"] as? String, let text = value["text"] as? String else { return nil }
        guard requestGeneration == textColorRequestGeneration, loadedDocumentID == documentID,
              loadGeneration == generation, editingEnabled, isReady, !isLoadingDocument else {
            if loadedDocumentID == documentID, loadGeneration == generation, isReady {
                send(TipTapEditorCommand("textColorEnd", args: ["token": token, "restoreFocus": false]))
            }
            return nil
        }
        textColorContext = (token, documentID, generation)
        return InlineTextColorEditorRequest(id: token, documentID: documentID, selectedText: text,
            initialColor: InlineTextColor.decode(value["style"]))
    }

    func applyTextColor(_ color: InlineTextColor?, request: InlineTextColorEditorRequest) async throws {
        guard textColorContext?.token == request.id, loadedDocumentID == request.documentID,
              textColorContext?.generation == loadGeneration, editingEnabled, selectionMode == "off", !isLoadingDocument else {
            throw VellixError.editorBridge("This text selection is no longer available.")
        }
        let generation = loadGeneration
        let applied = try await attachmentCommand("textColorApply", args: ["token": request.id,
            "style": color.map { $0.bridgeValue as Any } ?? NSNull()]) as? Bool
        guard applied == true, generation == loadGeneration, loadedDocumentID == request.documentID else {
            throw VellixError.editorBridge("This text selection changed. Select the text again.")
        }
    }

    func endTextColorEditing(requestID: String? = nil, restoreFocus: Bool = true) {
        if let requestID, textColorContext?.token != requestID { return }
        textColorRequestGeneration += 1
        guard let context = textColorContext else { return }
        textColorContext = nil
        guard context.documentID == loadedDocumentID, context.generation == loadGeneration,
              isReady, !isLoadingDocument else { return }
        send(TipTapEditorCommand("textColorEnd", args: ["token": context.token, "restoreFocus": restoreFocus && editingEnabled]))
    }

    func updateCalloutIcon(blockID: String?, icon: String) {
        let icon = normalizedIconName(icon)
        registerIconAsset(icon) { [weak self] in
            self?.send(TipTapEditorCommand.updateCalloutIcon(blockID: blockID, icon: icon))
        }
    }

    func updateCalloutColor(blockID: String, color: String) {
        send(TipTapEditorCommand.updateCalloutColor(blockID: blockID, color: color))
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

    func copySelectedBlocks() {
        send(TipTapEditorCommand.copySelectedBlocks())
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
        send(TipTapEditorCommand.undo())
    }

    func redo() {
        send(TipTapEditorCommand.redo())
    }

    func handleRawMessage(_ body: Any) {
        do {
            guard
                let dictionary = body as? [String: Any],
                let kind = dictionary["kind"] as? String
            else {
                throw VellixError.editorBridge("The editor sent an invalid TipTap message.")
            }

            let payload = dictionary["payload"] as? [String: Any] ?? [:]
            logger.info("📥 TRACE TIPTAP IN kind=\(kind, privacy: .public) payload=\(self.payloadSummary(payload), privacy: .public)")
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
        case .tagRequest(let request): tagRequest = request
        case .editorReady(let blockCount):
            logger.info("VELLIX-OPEN editorReady blocks=\(blockCount)")
            logger.info("⏱️ STARTUP +\(self.startupElapsedMS())ms editor ready blockCount=\(blockCount)")
            isReady = true
            setTemplateEditing(templateEditing)
            sendPageReferences()
            setCollections(collectionPayloads)
            send(TipTapEditorCommand("setAttachments", args: ["files": attachmentFiles.map(\.object)]))
        selectedBlockCount = 0
        selectionMode = "off"
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

        case .documentChanged(let json), .documentSnapshot(let json):
            logger.info("📝 TRACE EVENT documentChanged isLoading=\(self.isLoadingDocument)")
            guard isReady, !isLoadingDocument, let loadedDocumentID else {
                logger.debug("Suppressed programmatic editor change")
                return
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
            guard selectedBlockCount != count else {
                return
            }
            selectedBlockCount = count
            if count > 0 {
                isEditing = false
                slashMenuState = nil
            }
            onEvent?(event)

        case .selectionModeChanged(let mode):
            logger.info("🔘 TRACE EVENT selectionModeChanged mode=\(mode, privacy: .public) previous=\(self.selectionMode, privacy: .public)")
            selectionMode = mode
            if mode == "off" {
                selectedBlockCount = 0
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
            let current = isReady && !isLoadingDocument && editingEnabled && selectionMode == "off" ? state : TipTapTextConversionState()
            if textConversionState != current { textConversionState = current }

        case .requestHaptic(let style):
            logger.info("🫨 TRACE EVENT requestHaptic style=\(style, privacy: .public)")
            triggerHaptic(style: style)

        case .statisticsChanged:
            logger.info("📊 TRACE EVENT statisticsChanged")
            onEvent?(event)

        case .requestCalloutIconPicker:
            logger.info("✨ TRACE EVENT requestCalloutIconPicker")
            onEvent?(event)

        case .requestBlockquoteColorPicker, .requestCalloutColorPicker:
            onEvent?(event)

        case .attachmentClipboard, .requestAttachment, .requestAttachmentActions, .importAttachments, .requestCollection, .requestTemplateComponent, .requestInlinePropertyEditor, .requestPropertyURL, .requestNestedPage, .requestPageCard, .requestOpenPage, .requestPageActions, .requestBlockDeletion, .requestPlaceholderConversion:
            onEvent?(event)

        case .tableDocumentSnapshot, .taskDocumentSnapshot:
            guard isReady, !isLoadingDocument, loadedDocumentID != nil else { return }
            onEvent?(event)

        case .requestTableCreation, .requestTableMenu, .tableStateChanged, .tableFormulaPreview, .tableClipboard,
             .taskStateChanged, .requestTaskMenu, .requestTaskCompletion:
            onEvent?(event)

        case .slashMenuChanged(let state):
            logger.info("⌘ TRACE EVENT slashMenuChanged visible=\(state != nil) count=\(state?.items.count ?? 0)")
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
            "chevright",
            "chevdown",
            "chevup",
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

            if dictionary["type"] as? String == "callout" {
                let attrs = dictionary["attrs"] as? [String: Any] ?? [:]
                icons.insert(normalizedIconName(attrs["icon"] as? String))
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
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        logger.info("📤 TRACE TIPTAP OUT command=\(command.name, privacy: .public) args=\(self.payloadSummary(command.args), privacy: .public)")
        guard let webView else {
            completion?(.failure(VellixError.editorBridge("The editor web view is not attached.")))
            return
        }

        // tiptapCommand is async. Evaluating `void tiptapCommand(...)` acknowledges
        // scheduling, not completion, and could expose/capture an empty startup body.
        webView.callAsyncJavaScript("await window.tiptapCommand(name, args);",
            arguments: ["name": command.name, "args": command.args], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.logger.error("📤🚨 TRACE TIPTAP OUT failure command=\(command.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                completion?(.failure(error))
            case .success:
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
    @Published var calloutIconRequest: CalloutIconRequest?
    @Published var calloutColorRequest: CalloutColorRequest?
    @Published var templateComponentRequest: TemplateComponentRequest?
    @Published var attachmentEditorRequest: AttachmentEditorRequest?
    @Published var attachmentActionRequest: AttachmentActionRequest?
    @Published var blockquoteColorRequest: BlockquoteColorRequest?
    @Published var propertyEditorRequest: InlinePropertyEditorRequest?
    @Published var collectionEditorRequest: CollectionEditorRequest?
    @Published var propertyURLRequest: InlinePropertyURLRequest?
    @Published var nestedPageToOpen: DocumentRecord?
    @Published var nestedPageActionTarget: DocumentRecord?
    @Published var blockDeletionRequest: BlockDeletionRequest?
    @Published var cardEditorRequest: PageCardEditorRequest?
    @Published var errorMessage: String?
    @Published var placeholderConversionToken: String?
    @Published var tableEditorRequest: TableEditorRequest?
    @Published private(set) var tableContext: TipTapTableContext?
    @Published private(set) var tableFormulaPreview = ""
    @Published private(set) var taskContext: DocumentTaskContext?
    @Published private(set) var historyPageTask: DocumentTaskRecord?
    @Published var taskEditorRequest: TaskEditorRequest?
    @Published var taskHistoryRequest: TaskHistorySheetRequest?
    @Published var taskFeedback: String?
    var onChildCreated: ((DocumentRecord) -> Void)?
    var onDocumentSaved: ((DocumentRecord) -> Void)?
    var prepareForSpaceChange: (() throws -> Void)?

    private var pendingSaveTask: Task<Void, Never>?
    private var pendingDocumentID: String?
    private var latestJSON: String? {
        didSet { if latestJSON != oldValue { noteTemplateChange() } }
    }
    private var lastAutomaticSnapshotRevision = 0
    private var saveSequence = 0
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
        attachmentStore: AttachmentStore? = nil
    ) {
        let session = TipTapEditorSession()
        self.session = session
        self.webViewStore = TipTapEditorWebViewStore(session: session)
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
        session.documentForRecovery = { [weak self] in
            guard let self, let document = self.document else { return nil }
            return (document.id, self.latestJSON ?? document.tipTapJSON)
        }
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

    func prepare(document record: DocumentRecord) {
        guard document?.id != record.id else { return }

        flushPendingSave()
        templateChangeVersion = 0
        confirmedTemplateChangeVersion = nil
        document = record
        taskContext = nil
        taskEditorRequest = nil
        taskHistoryRequest = nil
        attachmentEditorRequest = nil
        attachmentActionRequest = nil
        templateNeedsSave = record.templateID != nil
        session.setTemplateEditing(record.templateID != nil)
        latestJSON = record.tipTapJSON
        pageReferenceIDs = TipTapContentAnalyzer.pageReferenceIDs(in: record.tipTapJSON)
        session.saveState = .saved(record.updatedAt)
        session.load(documentID: record.id, canonicalJSON: record.tipTapJSON)
        refreshLibraryContext()
        session.setAppearance(appearance)
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
        guard let document else { return }
        pendingSaveTask?.cancel()
        saveSequence += 1
        let updated = try documentRepository.saveEditorJSON(id: document.id, canonicalJSON: latestJSON ?? document.tipTapJSON)
        pendingDocumentID = nil
        self.document = updated
        session.saveState = .saved(updated.updatedAt)
        onDocumentSaved?(updated)
    }

    func captureAndSave(suspendingEditing: Bool = false) async throws {
        let operation = beginPersistentOperation()
        defer { endPersistentOperation(operation) }
        if let json = try await session.currentJSON(suspendingEditing: suspendingEditing) { latestJSON = json }
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
        let updated = try documentRepository.saveEditorJSON(id: id, canonicalJSON: json)
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
        switch event {
        case .attachmentClipboard(let token, let html, let text):
            #if canImport(UIKit)
            UIPasteboard.general.items = [["public.html": Data(html.utf8), "public.utf8-plain-text": text]]
            let success = true
            #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            let success = NSPasteboard.general.setString(html, forType: .html)
            if success { NSPasteboard.general.setString(text, forType: .string) }
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
            taskEditorRequest = TaskEditorRequest(context: context)
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
            pageReferenceIDs = TipTapContentAnalyzer.pageReferenceIDs(in: json)
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
        case .documentChanged(let json):
            if !EditorAttachment.paths(in: json).isSubset(of: Set(session.attachmentFiles.map { $0.record.relativePath })) {
                session.refreshAttachments(documentID: documentID, json: json)
            }
            scheduleSave(json)
        case .documentSnapshot(let json):
            if !EditorAttachment.paths(in: json).isSubset(of: Set(session.attachmentFiles.map { $0.record.relativePath })) {
                session.refreshAttachments(documentID: documentID, json: json)
            }
            scheduleSave(json, immediate: true)
        case .editorError(let message):
            errorMessage = message
        case .requestPlaceholderConversion(let token):
            placeholderConversionToken = token
        case .requestCalloutIconPicker(let blockID, let icon, let color):
            calloutIconRequest = CalloutIconRequest(blockID: blockID, icon: icon, color: color)
        case .requestCalloutColorPicker(let blockID, let color):
            calloutColorRequest = CalloutColorRequest(blockID: blockID, color: color)
        case .requestBlockquoteColorPicker(let blockID, let color):
            blockquoteColorRequest = BlockquoteColorRequest(blockID: blockID, color: color)
        case .requestInlinePropertyEditor(let blockID, let property):
            propertyEditorRequest = InlinePropertyEditorRequest(blockID: blockID, property: property)
        case .requestCollection(let request):
            collectionEditorRequest = request
        case .requestPropertyURL(let url):
            propertyURLRequest = InlinePropertyURLRequest(url: url)
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
            nestedPageToOpen = child
        case .requestPageActions(let documentID):
            guard let child = children.first(where: { $0.id == documentID }),
                  child.parentDocumentID == document?.id else { return }
            nestedPageActionTarget = child
        case .requestBlockDeletion(let token):
            blockDeletionRequest = BlockDeletionRequest(documentID: documentID, token: token)
        case .selectedBlocksForSubpage(let title, let json):
            createChildFromSelectedBlocks(title: title, canonicalJSON: json)
        default:
            break
        }
    }

    func groupSelectedBlocksIntoChildPage() {
        session.requestSelectedBlocksForSubpage()
    }

    func openTaskScheduling() {
        guard let context = taskContext else { return }
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

    private func createChildFromSelectedBlocks(title: String, canonicalJSON: String) {
        guard let document else {
            return
        }

        do {
            let child = try documentRepository.create(
                DocumentDraft(
                    title: title.trimmedNonEmpty ?? "New Sub Page",
                    spaceID: document.spaceID,
                    folderID: document.folderID,
                    parentDocumentID: document.id,
                    tipTapJSON: canonicalJSON
                )
            )
            for pageID in TipTapContentAnalyzer.pageReferenceIDs(in: canonicalJSON) {
                guard let page = try documentRepository.document(id: pageID), page.parentDocumentID == document.id else { continue }
                _ = try documentRepository.move(id: page.id, spaceID: page.spaceID, folderID: page.folderID, parentDocumentID: child.id)
            }
            session.deleteSelectedBlocks()
            refreshRelated()
            onChildCreated?(child)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleSave(_ json: String, immediate: Bool = false) {
        guard let document else {
            print("💾 TRACE MODEL scheduleSave ignored no document")
            return
        }

        print("💾 TRACE MODEL scheduleSave id=\(document.id) bytes=\(json.count) immediate=\(immediate)")
        latestJSON = json
        pageReferenceIDs = TipTapContentAnalyzer.pageReferenceIDs(in: json)
        pendingDocumentID = document.id
        session.saveState = .unsaved
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
        guard let id = pendingDocumentID, let json = latestJSON else {
            print("💾 TRACE MODEL savePending ignored no pending")
            return
        }
        print("💾 TRACE MODEL savePending id=\(id) bytes=\(json.count)")
        persistEditorJSON(documentID: id, canonicalJSON: json)
        pendingDocumentID = nil
    }

    private func persistEditorJSON(documentID: String, canonicalJSON: String) {
        saveSequence += 1
        let sequence = saveSequence
        let documentRepository = documentRepository
        let snapshotRepository = snapshotRepository
        let snapshotBaseRevision = lastAutomaticSnapshotRevision

        session.saveState = .saving
        print("💾 TRACE MODEL persist start id=\(documentID) sequence=\(sequence) bytes=\(canonicalJSON.count)")

        Task { [weak self] in
            guard let self, sequence == self.saveSequence, self.document?.id == documentID else { return }
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

            self.finishEditorSave(result, sequence: sequence)
        }
    }

    private func finishEditorSave(
        _ result: Result<EditorSaveResult, Error>,
        sequence: Int
    ) {
        guard sequence == saveSequence else {
            print("💾 TRACE MODEL finish stale sequence=\(sequence) current=\(saveSequence)")
            return
        }

        switch result {
        case .success(let saveResult):
            guard document?.id == saveResult.document.id else {
                print("💾 TRACE MODEL finish ignored different document id=\(saveResult.document.id)")
                return
            }
            print("💾 TRACE MODEL finish success id=\(saveResult.document.id) sequence=\(sequence)")
            if let snapshotRevision = saveResult.snapshotRevision {
                lastAutomaticSnapshotRevision = snapshotRevision
            }
            document = saveResult.document
            onDocumentSaved?(saveResult.document)
            session.saveState = .saved(saveResult.document.updatedAt)

        case .failure(let error):
            print("💾🚨 TRACE MODEL finish failure sequence=\(sequence) error=\(error.localizedDescription)")
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

    func refreshLibraryContext() {
        guard let document else { return }
        do {
            let current = try documentRepository.requireDocument(id: document.id)
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

struct CalloutIconRequest: Identifiable, Equatable {
    let id = UUID()
    var blockID: String
    var icon: String
    var color: String
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

struct CalloutColorRequest: Identifiable, Equatable {
    let id = UUID()
    var blockID: String?
    var color: String
}

private struct EditorSaveResult: Sendable {
    var document: DocumentRecord
    var snapshotRevision: Int?
}
