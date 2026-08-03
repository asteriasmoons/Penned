//
//  EditorSession.swift
//  Vellix
//

import Foundation
import Combine
import CoreGraphics
import os
import WebKit

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class EditorSession: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isLoadingDocument = false
    @Published var saveState: EditorSaveState = .idle
    @Published var bridgeErrorMessage: String?
    @Published var editorContentHeight: CGFloat = 320
    @Published var selectedBlockCount = 0
    @Published var isEditing = false
    @Published private(set) var renderedDocumentID: String?

    var onEvent: ((EditorEvent) -> Void)?

    private weak var webView: WKWebView?
    private var loadedDocumentID: String?
    private var pendingDocument: (id: String, json: String)?
    private var pendingAppearance: DocumentAppearance?
    private var awaitingRenderedDocumentID: String?
    private let logger = Logger(subsystem: "im.lystaria.Vellix", category: "EditorBridge")

    func attach(webView: WKWebView) {
        guard self.webView !== webView else {
            return
        }

        self.webView = webView
        isReady = false
        loadedDocumentID = nil
        renderedDocumentID = nil
        if let pendingDocument {
            load(documentID: pendingDocument.id, canonicalJSON: pendingDocument.json, force: true)
        }
    }

    func detach(webView: WKWebView) {
        guard self.webView === webView else {
            return
        }

        self.webView = nil
        isReady = false
        loadedDocumentID = nil
        awaitingRenderedDocumentID = nil
    }

    func markNavigationStarted() {
        isReady = false
        loadedDocumentID = nil
        renderedDocumentID = nil
        awaitingRenderedDocumentID = nil
    }

    func load(documentID: String, canonicalJSON: String, force: Bool = false) {
        guard isReady, webView != nil else {
            pendingDocument = (documentID, canonicalJSON)
            awaitingRenderedDocumentID = documentID
            setRenderedDocumentID(nil)
            return
        }

        guard force || loadedDocumentID != documentID else {
            setRenderedDocumentID(documentID)
            return
        }

        isLoadingDocument = true
        pendingDocument = nil
        loadedDocumentID = documentID
        awaitingRenderedDocumentID = documentID
        setRenderedDocumentID(nil)
        send(EditorCommand.loadDocument(canonicalJSON: canonicalJSON)) { [weak self] result in
            guard let self else { return }
            self.isLoadingDocument = false
            if case .failure(let error) = result {
                self.bridgeErrorMessage = error.localizedDescription
                self.logger.error("Failed to load document into editor: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func requestSnapshot() {
        send(EditorCommand.requestSnapshot())
    }

    func focus() {
        send(EditorCommand.focusEditor())
    }

    func setEditable(_ editable: Bool) {
        send(EditorCommand.setEditable(editable))
    }

    func setTheme(_ theme: String) {
        send(EditorCommand.setTheme(theme))
    }

    func setAppearance(_ appearance: DocumentAppearance) {
        guard isReady, webView != nil else {
            pendingAppearance = appearance
            return
        }

        pendingAppearance = nil
        send(EditorCommand.setAppearance(appearance))
    }

    func insertDivider(_ style: VellixDividerStyle) {
        send(EditorCommand.insertDivider(style))
    }

    func insertPageBreak() {
        send(EditorCommand.insertPageBreak())
    }

    func insertCallout(icon: String, text: String, color: String = "#ffffff") {
        send(EditorCommand.insertCallout(icon: icon, text: text, color: color))
    }

    func setSelectedBlockType(_ blockType: String, level: Int? = nil, color: String? = nil) {
        send(EditorCommand.setSelectedBlockType(blockType, level: level, color: color))
    }

    func indentSelectedBlocks() {
        send(EditorCommand.indentSelectedBlocks())
    }

    func outdentSelectedBlocks() {
        send(EditorCommand.outdentSelectedBlocks())
    }

    func setSelectedCalloutColor(_ color: String) {
        send(EditorCommand.setSelectedCalloutColor(color))
    }

    func updateCalloutIcon(blockID: String?, icon: String) {
        send(EditorCommand.updateCalloutIcon(blockID: blockID, icon: icon))
    }

    func deleteSelectedBlocks() {
        send(EditorCommand.deleteSelectedBlocks())
    }

    func copySelectedBlocks() {
        send(EditorCommand.copySelectedBlocks())
    }

    func cutSelectedBlocks() {
        send(EditorCommand.cutSelectedBlocks())
    }

    func duplicateSelectedBlocks() {
        send(EditorCommand.duplicateSelectedBlocks())
    }

    func requestSelectedBlocksForSubpage() {
        send(EditorCommand.requestSelectedBlocksForSubpage())
    }

    func selectAllBlocks() {
        send(EditorCommand.selectAllBlocks())
    }

    func clearBlockSelection() {
        send(EditorCommand.clearBlockSelection())
    }

    func updateEditorContentHeight(_ height: CGFloat) {
        // The web editor reports a tight height measured to the last block with
        // real content. Trust it directly; the SwiftUI layer applies its own
        // small minimum height per device size. Only a sanity floor is kept
        // here to avoid a zero/negative height during teardown.
        let clamped = max(40, min(height, 12_000))
        guard abs(editorContentHeight - clamped) > 1 else {
            return
        }
        editorContentHeight = clamped
    }

    func undo() {
        send(EditorCommand.undo())
    }

    func redo() {
        send(EditorCommand.redo())
    }

    func handleRawMessage(_ body: Any) {
        do {
            guard JSONSerialization.isValidJSONObject(body) else {
                throw VellixError.editorBridge("The editor sent a non-JSON message.")
            }

            let data = try JSONSerialization.data(withJSONObject: body)
            let envelope = try JSONDecoder().decode(EditorBridgeEnvelope.self, from: data)
            if envelope.type == "diag" {
                let message = envelope.payload.objectValue?["message"]?.stringValue ?? ""
                logger.info("VELLIX-DIAG \(message, privacy: .public)")
                return
            }
            let event = try EditorEvent(envelope: envelope)
            handle(event)
        } catch {
            bridgeErrorMessage = error.localizedDescription
            logger.error("Invalid editor event: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ event: EditorEvent) {
        switch event {
        case .editorReady(let blockCount):
            logger.info("Editor ready with \(blockCount) blocks")
            isReady = true
            selectedBlockCount = 0
            isEditing = false
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

        case .documentChanged:
            guard !isLoadingDocument else {
                logger.debug("Suppressed programmatic editor change")
                return
            }
            onEvent?(event)

        case .documentSnapshot:
            onEvent?(event)

        case .editorError(let message):
            bridgeErrorMessage = message
            onEvent?(event)

        case .contentHeightChanged(let height):
            updateEditorContentHeight(height)
            if let awaitingRenderedDocumentID,
               awaitingRenderedDocumentID == loadedDocumentID {
                setRenderedDocumentID(awaitingRenderedDocumentID)
                self.awaitingRenderedDocumentID = nil
            }
            onEvent?(event)

        case .blockSelectionChanged(let count):
            guard selectedBlockCount != count else {
                return
            }
            selectedBlockCount = count
            send(EditorCommand.setEditable(count == 0))
            if count > 0 {
                isEditing = false
            }
            onEvent?(event)

        case .focusChanged(let focused):
            isEditing = focused
            onEvent?(event)

        case .requestHaptic(let style):
            triggerHaptic(style: style)

        case .statisticsChanged, .requestCalloutIconPicker, .selectedBlocksForSubpage, .unknown:
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

    private func send(
        _ command: EditorBridgeEnvelope,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard let webView else {
            completion?(.failure(VellixError.editorBridge("The editor web view is not attached.")))
            return
        }

        do {
            let data = try JSONEncoder().encode(command)
            let object = try JSONSerialization.jsonObject(with: data)
            Task { @MainActor in
                do {
                    _ = try await webView.callAsyncJavaScript(
                        "window.receiveNativeMessage(message)",
                        arguments: ["message": object],
                        in: nil,
                        contentWorld: .page
                    )
                    completion?(.success(()))
                } catch {
                    completion?(.failure(error))
                }
            }
        } catch {
            completion?(.failure(error))
        }
    }

    private func setRenderedDocumentID(_ documentID: String?) {
        guard renderedDocumentID != documentID else {
            return
        }

        renderedDocumentID = documentID
    }
}

@MainActor
final class EditorCoordinatorModel: ObservableObject {
    let session = EditorSession()
    private let documentRepository: DocumentRepository
    private let snapshotRepository: SnapshotRepository

    @Published var document: DocumentRecord?
    @Published var children: [DocumentRecord] = []
    @Published var snapshots: [DocumentSnapshotRecord] = []
    @Published private(set) var instantPreviewBlocks: [InstantPreviewBlock] = []
    @Published var calloutIconRequest: CalloutIconRequest?
    @Published var errorMessage: String?

    private var pendingSaveTask: Task<Void, Never>?
    private var pendingDocumentID: String?
    private var latestJSON: String?
    private var lastAutomaticSnapshotRevision = 0
    private var saveSequence = 0

    init(
        documentRepository: DocumentRepository,
        snapshotRepository: SnapshotRepository
    ) {
        self.documentRepository = documentRepository
        self.snapshotRepository = snapshotRepository
        session.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func load(documentID: String?) {
        flushPendingSave()
        guard let documentID else {
            document = nil
            children = []
            snapshots = []
            instantPreviewBlocks = []
            return
        }

        do {
            let record = try documentRepository.requireDocument(id: documentID)
            try documentRepository.markOpened(id: record.id)
            document = record
            latestJSON = record.blockNoteJSON
            instantPreviewBlocks = BlockNoteContentAnalyzer.instantPreviewBlocks(from: record.blockNoteJSON)
            session.saveState = .saved(record.updatedAt)
            session.load(documentID: record.id, canonicalJSON: record.blockNoteJSON)
            session.setAppearance(record.appearance)
            refreshRelated()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(title: String) {
        guard let document else {
            return
        }

        do {
            let updated = try documentRepository.updateTitle(id: document.id, title: title)
            self.document = updated
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
                    title: "Child Document",
                    spaceID: document.spaceID,
                    folderID: document.folderID,
                    parentDocumentID: document.id
                )
            )
            refreshRelated()
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
            latestJSON = restored.blockNoteJSON
            instantPreviewBlocks = BlockNoteContentAnalyzer.instantPreviewBlocks(from: restored.blockNoteJSON)
            session.load(documentID: restored.id, canonicalJSON: restored.blockNoteJSON, force: true)
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

    private func handle(_ event: EditorEvent) {
        switch event {
        case .documentChanged(let json):
            scheduleSave(json)
        case .documentSnapshot(let json):
            scheduleSave(json, immediate: true)
        case .editorError(let message):
            errorMessage = message
        case .requestCalloutIconPicker(let blockID, let icon):
            calloutIconRequest = CalloutIconRequest(blockID: blockID, icon: icon)
        case .selectedBlocksForSubpage(let title, let json):
            createChildFromSelectedBlocks(title: title, canonicalJSON: json)
        default:
            break
        }
    }

    func groupSelectedBlocksIntoChildPage() {
        session.requestSelectedBlocksForSubpage()
    }

    private func createChildFromSelectedBlocks(title: String, canonicalJSON: String) {
        guard let document else {
            return
        }

        do {
            _ = try documentRepository.create(
                DocumentDraft(
                    title: title.trimmedNonEmpty ?? "New Sub Page",
                    spaceID: document.spaceID,
                    folderID: document.folderID,
                    parentDocumentID: document.id,
                    appearanceJSON: document.appearanceJSON,
                    blockNoteJSON: canonicalJSON
                )
            )
            session.deleteSelectedBlocks()
            refreshRelated()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleSave(_ json: String, immediate: Bool = false) {
        guard let document else {
            return
        }

        latestJSON = json
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
            return
        }
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

        Task { [weak self] in
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
                        documentID: updated.id,
                        savedAt: updated.updatedAt,
                        snapshotRevision: snapshotRevision
                    )
                )
            } catch {
                result = .failure(error)
            }

            self?.finishEditorSave(result, sequence: sequence)
        }
    }

    private func finishEditorSave(
        _ result: Result<EditorSaveResult, Error>,
        sequence: Int
    ) {
        guard sequence == saveSequence else {
            return
        }

        switch result {
        case .success(let saveResult):
            guard document?.id == saveResult.documentID else {
                return
            }
            if let snapshotRevision = saveResult.snapshotRevision {
                lastAutomaticSnapshotRevision = snapshotRevision
            }
            session.saveState = .saved(saveResult.savedAt)

        case .failure(let error):
            session.saveState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func refreshRelated() {
        guard let document else {
            return
        }

        do {
            children = try documentRepository.children(of: document.id)
            snapshots = try snapshotRepository.history(documentID: document.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CalloutIconRequest: Identifiable, Equatable {
    let id = UUID()
    var blockID: String
    var icon: String
}

private struct EditorSaveResult: Sendable {
    var documentID: String
    var savedAt: Date
    var snapshotRevision: Int?
}
