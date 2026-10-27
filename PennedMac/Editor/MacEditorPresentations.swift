import AppKit
import SwiftUI

struct MacEditorPresentations: ViewModifier {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var model: DocumentEditorModel
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.openURL) private var openURL
    let locked: Bool
    @State private var collection: CollectionEditorRequest?
    func body(content: Content) -> some View {
        content
            .sheet(item: $model.attachmentEditorRequest) { request in
                AttachmentEditorSheet(request: request, session: model.session, editable: !locked).frame(width: 520, height: 600)
            }
            .sheet(item: $model.taskEditorRequest) { TaskEditorSheet(model: model, notifications: environment.taskNotifications, request: $0).frame(width: 510, height: 600) }
            .sheet(item: $model.taskHistoryRequest) { TaskHistorySheet(request: $0).frame(width: 540, height: 700) }
            .sheet(item: $model.tableEditorRequest, onDismiss: { model.session.tableAction("close") }) { TableEditorSheet(model: model, request: $0).frame(width: 560, height: 650) }
            .sheet(item: $model.propertyEditorRequest) { request in
                InlinePropertyEditorSheet(property: request.property, editingGuidance: model.session.placeholderMode,
                    onSave: { model.session.updateInlineProperty(blockID: request.blockID, property: $0) },
                    onDelete: { model.session.deleteInlineProperty(blockID: request.blockID) }).frame(width: 540, height: 650)
            }
            .sheet(item: $model.templateComponentRequest) { TemplateComponentEditorSheet(request: $0, session: model.session).frame(width: 540, height: 650) }
            .sheet(item: $model.cardEditorRequest, onDismiss: { model.cancelCardInsertion() }) { request in
                PageCardEditorSheet(request: request, store: environment.attachmentStore) { style, data in
                    try await model.savePageCard(request: request, style: style, imageData: data)
                }.frame(width: 650, height: 650)
            }
            .sheet(item: $model.calloutIconRequest) { request in
                VellixIconLibraryPicker(title: "Callout Icon") { icon in
                    model.session.updateCalloutIcon(blockID: request.blockID, icon: icon.name); model.calloutIconRequest = nil
                }.frame(width: 600, height: 600)
            }
            .sheet(item: $model.calloutColorRequest) { request in
                MacBlockColorSheet(title: "Callout Color", initial: request.color) { color in
                    if let id = request.blockID { model.session.updateCalloutColor(blockID: id, color: color) }
                }.frame(width: 400, height: 300)
            }
            .sheet(item: $model.blockquoteColorRequest) { request in
                MacBlockColorSheet(title: "Blockquote Color", initial: request.color) { model.session.updateBlockquoteColor(blockID: request.blockID, color: $0) }.frame(width: 400, height: 300)
            }
            .sheet(isPresented: Binding(get: { workspace.showIconPicker && workspace.activeEditor === model }, set: { workspace.showIconPicker = $0 })) {
                VellixIconLibraryPicker(title: "Document Icon") { icon in model.updateIcon(icon.name); workspace.showIconPicker = false }.frame(width: 600, height: 600)
            }
            .sheet(item: $collection) { collectionSheet($0).frame(minWidth: 540, idealHeight: 650) }
            .onChange(of: workspace.activeID) { _, _ in model.taskHistoryRequest = nil }
            .onChange(of: workspace.activeTab.location.documentID) { _, id in
                if id != model.documentID { model.taskHistoryRequest = nil }
            }
            .onReceive(model.$collectionEditorRequest) { request in
                guard let request, workspace.activeEditor === model, !locked else { return }
                model.collectionEditorRequest = nil
                do {
                    if request.action == "create" { collection = request; return }
                    guard try environment.collections.repository.collectionIDs(forDocument: model.documentID).contains(request.collectionID) else { throw LibraryError.wrongOwner }
                    let snapshot = try environment.collections.load(request.collectionID)
                    if request.action == "openEntry" {
                        guard snapshot.entries.contains(where: { $0.id == request.documentID }) else { throw LibraryError.wrongOwner }
                        openPage(request.documentID)
                    } else { collection = request }
                } catch { model.errorMessage = error.localizedDescription }
            }
            .onReceive(model.$propertyURLRequest) { request in
                if let request, let url = InlinePropertyDefinition.safeURL(request.url) { openURL(url); model.propertyURLRequest = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pennedCollectionsChanged, object: environment.database)) { _ in
                environment.collections.refresh()
                model.session.setCollections(environment.collections.payloads(for: model.documentID))
            }
            .macConfirmationDialog("Delete this block?", isPresented: Binding(get: { model.blockDeletionRequest != nil }, set: { value in
                if !value, let request = model.blockDeletionRequest { model.session.dismissBlockActions(requestToken: request.token); model.blockDeletionRequest = nil }
            }), titleVisibility: .visible) {
                Button("Delete Block", role: .destructive) { if let request = model.blockDeletionRequest { model.session.deleteBlock(requestToken: request.token); model.blockDeletionRequest = nil } }
            }
            .macConfirmationDialog("Page Actions", isPresented: Binding(get: { model.nestedPageActionTarget != nil }, set: { if !$0 { model.nestedPageActionTarget = nil } }), titleVisibility: .visible) {
                if let document = model.nestedPageActionTarget {
                    Button("Open") { openPage(document.id); model.nestedPageActionTarget = nil }
                    Button("Edit Card") { model.editPageCard(document); model.nestedPageActionTarget = nil }
                    Button("Move to Trash", role: .destructive) { workspace.requestTrash([document.id]); model.nestedPageActionTarget = nil }
                }
            }
            .macConfirmationDialog("File Actions", isPresented: Binding(get: { model.attachmentActionRequest != nil }, set: { if !$0 { model.attachmentActionRequest = nil } }), titleVisibility: .visible) {
                if let request = model.attachmentActionRequest {
                    Button("Open File") { if let url = try? environment.attachmentStore.validatedFileURL(relativePath: request.attachment.relativePath) { NSWorkspace.shared.open(url) } }
                    Button("Display Options") { model.attachmentEditorRequest = request.attachment; model.attachmentActionRequest = nil }
                    Button("Delete File Block", role: .destructive) { Task { await model.deleteAttachment(request); model.attachmentActionRequest = nil } }
                }
            }
            .macConfirmationDialog("Convert this block into a template placeholder?", isPresented: Binding(get: { model.placeholderConversionToken != nil }, set: { if !$0 { model.session.cancelPlaceholderConversion(); model.placeholderConversionToken = nil } }), titleVisibility: .visible) {
                Button("Convert to Placeholder") { model.session.placeholderAction("convert", token: model.placeholderConversionToken); model.placeholderConversionToken = nil }
            }
            .macAlert("Editor", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
    private func openPage(_ id: String) {
        workspace.perform { let document = try environment.documents.requireDocument(id: id); try await workspace.open(document) }
    }
    @ViewBuilder private func collectionSheet(_ request: CollectionEditorRequest) -> some View {
        let store = environment.collections
        if request.action == "create" { CollectionCreateSheet(model: model, blockID: request.blockID) }
        else if let snapshot = store.snapshots[request.collectionID] {
            switch request.action {
            case "field": CollectionFieldEditorSheet(store: store, field: snapshot.field(request.fieldID) ?? CollectionField(collectionID: snapshot.record.id, name: "", kind: .text))
            case "value":
                if let field = snapshot.field(request.fieldID), let entry = snapshot.entries.first(where: { $0.id == request.documentID }) {
                    CollectionValueSheet(store: store, collectionID: snapshot.record.id, documentID: entry.id, field: field, value: entry.values[field.id] ?? CollectionValue())
                }
            case "addEntry": CollectionAddEntrySheet(store: store, collectionID: snapshot.record.id, onOpen: openPage)
            case "entry":
                if let entry = snapshot.entries.first(where: { $0.id == request.documentID }) { CollectionEntryActionsSheet(store: store, collectionID: snapshot.record.id, entry: entry, onOpen: openPage) }
            default: CollectionManagementSheet(store: store, snapshot: snapshot, closesOnSelection: request.action == "menu")
            }
        }
    }
}

private struct MacBlockColorSheet: View {
    let title: String
    @State private var color: Color
    let change: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    init(title: String, initial: String, change: @escaping (String) -> Void) { self.title = title; _color = State(initialValue: Color(vellixHex: initial)); self.change = change }
    var body: some View {
        VellixBlockColorControls(title: title, selection: $color, onColorChange: { change($0.vellixHexString(fallback: "#FFFFFF")) })
            .padding().pennedSheet(title: title, close: { dismiss() })
    }
}
