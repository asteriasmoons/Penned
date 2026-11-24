//
//  DocumentEditorCache.swift
//  Vellix
//

import Combine
import Foundation

@MainActor
final class DocumentEditorCache: ObservableObject {
    @Published private var modelsByDocumentID: [String: DocumentEditorModel] = [:]

    private let documentRepository: DocumentRepository
    private let snapshotRepository: SnapshotRepository
    private let attachmentStore: AttachmentStore?
    private let collectionPayloads: (String) -> [[String: Any]]
    private var standbyRuntime: TipTapEditorWebViewStore?
    var onDocumentSaved: ((DocumentRecord) -> Void)?
    var ownsEditorPresentation: ((String) -> Bool)?
    var openNestedPage: ((DocumentRecord, String) -> Void)?
    weak var documentPreviews: DocumentPreviewCache?

    init(
        documentRepository: DocumentRepository,
        snapshotRepository: SnapshotRepository,
        attachmentStore: AttachmentStore? = nil,
        collectionPayloads: @escaping (String) -> [[String: Any]] = { _ in [] }
    ) {
        self.documentRepository = documentRepository
        self.snapshotRepository = snapshotRepository
        self.attachmentStore = attachmentStore
        self.collectionPayloads = collectionPayloads
    }

    func prepare(_ documents: [DocumentRecord]) {
        var preparedModels = modelsByDocumentID
        var changed = false

        for document in documents {
            if let model = preparedModels[document.id] {
                model.refreshLibraryContext()
                model.session.setCollections(collectionPayloads(document.id))
            } else {
                let model = makeModel(for: document, readOnlyWarmup: true)
                preparedModels[document.id] = model
                changed = true
            }
        }

        if changed {
            modelsByDocumentID = preparedModels
        }
    }

    @discardableResult
    func prepare(_ document: DocumentRecord) -> DocumentEditorModel {
        if let model = modelsByDocumentID[document.id] {
            if model.isReadOnlyWarmup { model.prepare(document: document) }
            if DocumentTaskPages.isManaged(document.id) || model.document?.title != document.title || model.document?.cover != document.cover
                || model.document?.icon != document.icon || model.document?.appearanceJSON != document.appearanceJSON {
                model.refreshLibraryContext()
            }
            return model
        }

        let model = makeModel(for: document)
        modelsByDocumentID[document.id] = model
        return model
    }

    func model(for documentID: String?) -> DocumentEditorModel? {
        guard let documentID else { return nil }
        return modelsByDocumentID[documentID]
    }

    var hasStandbyRuntime: Bool { standbyRuntime != nil }

    func prepareStandbyRuntime() {
        guard standbyRuntime == nil else { return }
        let session = TipTapEditorSession()
        session.isStandbyRuntime = true
        PennedDiagnostics.markStartup("editor-standby.start")
        standbyRuntime = TipTapEditorWebViewStore(session: session)
    }

    func discardStandbyRuntime() {
        standbyRuntime?.discardUnusedRuntime()
        standbyRuntime = nil
    }

    private func takeStandbyRuntime() -> TipTapEditorWebViewStore? {
        guard let standbyRuntime else { return nil }
        self.standbyRuntime = nil
        if standbyRuntime.coordinator.session.bridgeErrorMessage != nil {
            standbyRuntime.discardUnusedRuntime()
            return nil
        }
        standbyRuntime.coordinator.session.isStandbyRuntime = false
        return standbyRuntime
    }

    func prepareForOpening(_ document: DocumentRecord, payloads: [[String: Any]],
                           timing: PennedDocumentOpeningTiming) -> DocumentEditorModel {
        let trace = timing.trace
        let started = trace?.event("editor-cache-start")
        if let model = modelsByDocumentID[document.id] {
            trace?.event("editor-cache-route", "route=retained-document \(model.session.openingReadinessState(for: document.id))")
            model.session.beginOpening(timing)
            timing.mark("runtime-selected", route: "retained-document")
            if model.session.isReady { timing.mark("editor-bridge-ready", route: "already-ready") }
            model.session.setCollections(payloads)
            if model.isReadOnlyWarmup { model.prepare(document: document) }
            if DocumentTaskPages.isManaged(document.id) || model.document?.title != document.title ||
                model.document?.cover != document.cover || model.document?.icon != document.icon ||
                model.document?.appearanceJSON != document.appearanceJSON {
                model.refreshLibraryContext()
            }
            model.session.resumeRetainedPresentation(for: document.id)
            if document.tipTapJSON.contains("\"trackedTask\"") {
                model.refreshSharedTaskReferences()
            }
            trace?.event("editor-cache-completed", "route=retained-document", since: started)
            return model
        }
        let model = makeModel(for: document, payloads: payloads, timing: timing)
        if model.documentID == document.id { modelsByDocumentID[document.id] = model }
        trace?.event("editor-cache-completed", "modelMatches=\(model.documentID == document.id)", since: started)
        return model
    }

    var preparedModels: [DocumentEditorModel] {
        modelsByDocumentID.keys.sorted().compactMap { modelsByDocumentID[$0] }
    }

    func remove(documentID: String) {
        guard let model = modelsByDocumentID.removeValue(forKey: documentID) else {
            return
        }
        model.discardPendingSave()
    }

    private func makeModel(for document: DocumentRecord, readOnlyWarmup: Bool = false,
                           payloads: [[String: Any]]? = nil, timing: PennedDocumentOpeningTiming? = nil) -> DocumentEditorModel {
        timing?.trace?.event("standby-candidate", "exists=\(standbyRuntime != nil) bridgeReady=\(standbyRuntime?.coordinator.session.isReady == true) bridgeErrorMessage=\(standbyRuntime?.coordinator.session.bridgeErrorMessage == nil ? "none" : "present")")
        let runtime = readOnlyWarmup ? nil : takeStandbyRuntime()
        let route = runtime.map { $0.coordinator.session.isReady ? "standby-ready" : "standby-starting" } ?? "cold"
        timing?.trace?.event("editor-cache-route", "route=\(route)")
        timing?.mark("runtime-selected", route: route)
        let model = DocumentEditorModel(
            documentRepository: documentRepository,
            snapshotRepository: snapshotRepository,
            attachmentStore: attachmentStore,
            runtime: runtime
        )
        if let timing {
            model.session.beginOpening(timing)
            if model.session.isReady { timing.mark("editor-bridge-ready", route: "already-ready") }
        }
        model.session.documentPreviewCache = documentPreviews
        let documentID = document.id
        model.session.ownsEditorPresentation = { [weak self] in
            self?.ownsEditorPresentation?(documentID) == true
        }
        model.onOpenNestedPage = { [weak self] child in self?.openNestedPage?(child, documentID) }
        model.prepareBlockDropDestination = { [weak self] id in
            // A retained child may have an outstanding autosave. Drain it before
            // the transfer compares and updates its persisted body.
            if let destination = self?.modelsByDocumentID[id], destination.hasUnsavedLibraryContent {
                try await destination.captureAndSave(preservingBlockSelection: true)
            }
        }
        model.blockDropRecordSaved = { [weak self] saved, contentChanged in
            guard let cached = self?.modelsByDocumentID[saved.id] else { return }
            await cached.adoptBlockDropRecord(saved, contentChanged: contentChanged)
        }
        model.onChildCreated = { [weak self] child in
            self?.prepare(child)
        }
        model.onDocumentSaved = { [weak self] saved in
            guard let self else { return }
            self.onDocumentSaved?(saved)
            guard let parentID = saved.parentDocumentID,
                  let parent = self.modelsByDocumentID[parentID],
                  parent.updateChildDocument(saved) else { return }
            var ancestorID = parent.document?.parentDocumentID
            var seen: Set<String> = [saved.id, parentID]
            while let id = ancestorID, seen.insert(id).inserted,
                  let ancestor = self.modelsByDocumentID[id] {
                ancestor.noteTemplateChange()
                ancestorID = ancestor.document?.parentDocumentID
            }
        }
        model.session.setCollections(payloads ?? collectionPayloads(document.id))
        model.prepare(document: document, readOnlyWarmup: readOnlyWarmup)
        return model
    }
}
