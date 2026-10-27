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
    var onDocumentSaved: ((DocumentRecord) -> Void)?

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
                let model = makeModel(for: document)
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

    var preparedModels: [DocumentEditorModel] {
        modelsByDocumentID.keys.sorted().compactMap { modelsByDocumentID[$0] }
    }

    func remove(documentID: String) {
        guard let model = modelsByDocumentID.removeValue(forKey: documentID) else {
            return
        }
        model.discardPendingSave()
    }

    private func makeModel(for document: DocumentRecord) -> DocumentEditorModel {
        let model = DocumentEditorModel(
            documentRepository: documentRepository,
            snapshotRepository: snapshotRepository,
            attachmentStore: attachmentStore
        )
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
        model.session.setCollections(collectionPayloads(document.id))
        model.prepare(document: document)
        return model
    }
}
