import Foundation
import WebKit

@MainActor
enum CollectionDeletion {
    static func delete(_ collectionID: String, in environment: AppEnvironment) async throws {
        _ = try environment.collections.repository.snapshot(id: collectionID)
        try await environment.prepareForWorkspaceNavigation()
        let models = environment.editorCache.preparedModels
        let operations = models.map { $0.beginPersistentOperation() }
        let editable = models.map { $0.session.editingEnabled }
        defer {
            for (index, model) in models.enumerated() {
                model.session.setEditable(editable[index])
                model.endPersistentOperation(operations[index])
            }
        }
        models.forEach { $0.session.setEditable(false) }
        for model in models {
            guard model.session.isReady, !model.session.isLoadingDocument,
                  let webView = model.session.tagNavigationWebView else { continue }
            // Edit the existing ProseMirror document in place, retaining unsaved text and history.
            _ = try await webView.callAsyncJavaScript("""
                const editor = document.querySelector('.tiptap-editor')?.editor;
                if (!editor) throw new Error('The editor is not ready.');
                const ranges = [];
                editor.state.doc.descendants((node, pos) => {
                    if (node.type.name === 'collection' && node.attrs.collectionID === collectionID)
                        ranges.push({from: pos, to: pos + node.nodeSize});
                });
                if (ranges.length) {
                    const transaction = editor.state.tr.setMeta('addToHistory', false);
                    ranges.reverse().forEach(range => transaction.delete(range.from, range.to));
                    editor.view.dispatch(transaction);
                }
                """, arguments: ["collectionID": collectionID], in: nil, contentWorld: .page)
            try await model.captureAndSave()
        }
        let changed = try environment.collections.repository.deleteCollection(id: collectionID)
        for model in models {
            if changed.contains(model.documentID) { try model.reloadAfterLibrarySync() }
            else { model.refreshLibraryContext() }
        }
        environment.collections.refresh()
        environment.refresh()
    }
}
