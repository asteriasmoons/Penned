import AppKit
import SwiftUI

struct MacInfoInspector: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var model: DocumentEditorModel
    @EnvironmentObject private var environment: AppEnvironment
    @State private var actions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacSegmentedControl("Info Section", selection: $actions, options: [false, true], label: { $0 ? "Actions" : "Page Info" })
            if let document = model.document {
                if !actions {
                    MacInspectorSectionHeader(title: "Properties")
                    LabeledContent("Created", value: document.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Updated", value: document.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Words", value: document.wordCount.formatted())
                    LabeledContent("Characters", value: document.characterCount.formatted())
                    LabeledContent("Reading Time", value: "\(document.estimatedReadingMinutes) min")
                    if let space = environment.allSpaces.first(where: { $0.id == document.spaceID }) { LabeledContent("Space", value: space.title) }
                    if let folder = environment.overview.folders.first(where: { $0.id == document.folderID }) { LabeledContent("Folder", value: folder.title) }
                    if let parent = document.parentDocumentID, let record = try? environment.documents.document(id: parent) {
                        Button("Parent: " + record.title) { workspace.perform { try await workspace.open(record) } }
                    }
                    MacInspectorSectionHeader(title: "Document")
                    MacDocumentMenu(document: document, workspace: workspace)
                } else {
                    action("Find in Page", icon: "searchwavy") { workspace.findInDocument = true }
                    action(document.isFavorite ? "Unstar Document" : "Star Document", icon: "starfill") { environment.starDocuments([document.id], isFavorite: !document.isFavorite) }
                    action("View Backups", icon: "clockwavy") { workspace.showHistory = true }
                    action("Copy Plain Text", icon: "copy") {
                        workspace.perform {
                            try await model.captureAndSave()
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.document?.plainText ?? "", forType: .string)
                        }
                    }
                    action("Duplicate Document", icon: "copy") { workspace.perform { try await workspace.flush(); let copy = try environment.documents.duplicate(id: document.id, attachmentStore: environment.attachmentStore); environment.refresh(); try await workspace.open(copy, newTab: true) } }
                    action("Save as Template", icon: "copy") { environment.saveAsTemplate(document) }
                    Divider()
                    MacSelectionActions(session: model.session)
                    Divider()
                    Button("Move Document to Trash", role: .destructive) { workspace.requestTrash([document.id]) }
                }
            }
        }.font(.system(size: 12, weight: .medium, design: .rounded)).controlSize(.small)
    }
    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label { Text(title).frame(maxWidth: .infinity, alignment: .leading) } icon: { LibraryIcon(name: icon, size: 16) } }.buttonStyle(.plain)
    }
}

private struct MacSelectionActions: View {
    @ObservedObject var session: TipTapEditorSession
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacInspectorSectionHeader(title: "Selected Blocks")
            Button("Select All Blocks") { session.selectAllBlocks() }
            Group {
                Button("Cut") { session.cutSelectedBlocks() }
                Button("Copy") { session.copySelectedBlocks() }
                Button("Duplicate") { session.duplicateSelectedBlocks() }
                Button("Move to New Page") { session.requestSelectedBlocksForSubpage() }
                Button("Delete Selected Blocks", role: .destructive) { session.deleteSelectedBlocks() }
            }.disabled(session.selectedBlockCount == 0)
        }
    }
}

struct MacVersionHistory: View {
    @ObservedObject var model: DocumentEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var restoring: DocumentSnapshotRecord?
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Document Backups").font(.headline); Spacer(); Button("Done") { dismiss() } }
            Button("Create Backup Now") { Task { do { try await model.captureAndSave(); model.createManualSnapshot() } catch { model.errorMessage = error.localizedDescription } } }
            List(model.snapshots) { snapshot in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(snapshot.createdAt.formatted()); Spacer(); Button("Restore") { restoring = snapshot } }
                    Text(snapshot.reason).font(.caption).foregroundStyle(.secondary)
                    Text((try? TipTapContentAnalyzer.analyze(snapshot.tipTapJSON).plainText) ?? "").lineLimit(4).font(.caption)
                }.padding(.vertical, 6)
            }
        }.padding(20)
        .macConfirmationDialog("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible) {
            Button("Restore Backup") { if let snapshot = restoring { Task { do { try await model.captureAndSave(); model.restore(snapshot); restoring = nil; dismiss() } catch { model.errorMessage = error.localizedDescription } } } }
        } message: { Text("Your current edits will be saved before restoring this revision.") }
    }
}
