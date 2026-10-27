// Mac-target platform adapter. Based on Vellix/Accounts/AccountLibrarySheet.swift.
// iPhone/iPad implementations remain in their original target.
import SwiftUI

struct AccountLibrarySheet: View {
    @EnvironmentObject private var accounts: AppState
    @EnvironmentObject private var workspace: LibraryWorkspace
    @Environment(\.dismiss) private var dismiss
    let identity: AccountIdentity
    var embeddedInWorkspace = false
    @State private var selectedSpaces = Set<String>()
    @State private var includeStyles = false
    @State private var adopting = false
    @State private var enabling = false
    @State private var restoringCloud = false
    @State private var error: String?
    @State private var busy = false
    @State private var revisions: [LibrarySyncConflict] = []
    @State private var restoring: LibrarySyncConflict?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VellixSpacing.lg) {
                Text("Document Library").font(.headline)
                HStack {
                    Text(workspace.usesLocalLibrary ? "On This Device" : "Account Library")
                    Spacer()
                    Button(workspace.usesLocalLibrary ? "Open Account Library" : "Open Local Library") {
                        let local = !workspace.usesLocalLibrary
                        guard accounts.currentAccountIdentity == identity else { return }
                        dismiss()
                        Task { await workspace.activate(identity, local: local) }
                    }.foregroundStyle(VellixSurface.violet)
                }.padding(VellixSpacing.md).pennedSheetField()

                Text("iCloud Sync").font(.headline)
                if workspace.usesLocalLibrary {
                    Text("This library stays on this device.").font(.footnote).foregroundStyle(.secondary)
                } else if workspace.syncEnabled {
                    action(workspace.syncNeedsRetry ? "Retry Sync" : "Sync Now", icon: "cloudie") { await workspace.synchronize(retry: workspace.syncNeedsRetry) }
                    action("Pause Sync", icon: "cloudie") { try await workspace.pauseSync() }
                    Text("\(workspace.pendingChanges) queued changes | \(workspace.pendingDownloads) waiting records")
                        .font(.footnote).foregroundStyle(.secondary)
                    if workspace.cloudZoneRemoved {
                        Button("Restore Removed Cloud Library") { restoringCloud = true }
                            .font(.footnote).foregroundStyle(VellixSurface.violet)
                    }
                } else {
                    Button { enabling = true } label: {
                        Label { Text("Enable iCloud Sync") } icon: { LibraryIcon(name: "cloudie", size: 22) }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(VellixSpacing.md).pennedSheetField()
                    }.buttonStyle(.plain).foregroundStyle(VellixSurface.violet)
                }
                if !workspace.syncMessage.isEmpty {
                    Text(workspace.syncMessage).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }

                let localSpaces = workspace.localSpaces
                if !localSpaces.isEmpty {
                    Text("Adopt Local Spaces").font(.headline)
                    ForEach(localSpaces) { space in
                        Button {
                            if !selectedSpaces.insert(space.id).inserted { selectedSpaces.remove(space.id) }
                        } label: {
                            HStack(spacing: VellixSpacing.md) {
                                LibraryIcon(name: space.icon ?? "spaces", size: 22)
                                Text(space.title).frame(maxWidth: .infinity, alignment: .leading)
                                if selectedSpaces.contains(space.id) { LibraryIcon(name: "checkwavy", size: 22) }
                            }.padding(VellixSpacing.md).pennedSheetField()
                        }.buttonStyle(.plain).foregroundStyle(VellixSurface.violet)
                    }
                    Toggle("Include local saved styles", isOn: $includeStyles)
                    Button("Adopt Selected Spaces") { adopting = true }
                        .foregroundStyle(VellixSurface.violet).disabled(selectedSpaces.isEmpty)
                }

                if !revisions.isEmpty {
                    Text("Recovery Revisions").font(.headline)
                    ForEach(revisions) { revision in
                        VStack(alignment: .leading, spacing: VellixSpacing.sm) {
                            Text(revision.row.values["title"]?.text ?? revision.row.values["name"]?.text ?? revision.row.table)
                            Text(revision.createdAt, style: .date).font(.footnote).foregroundStyle(.secondary)
                            Text(revision.reason).font(.footnote).foregroundStyle(.secondary)
                            if let json = revision.row.values["tipTapJSON"]?.text {
                                DisclosureGroup("Revision Content") {
                                    Text((try? TipTapContentAnalyzer.analyze(json).plainText) ?? "").font(.footnote).textSelection(.enabled)
                                }
                            }
                            if !revision.deleted {
                                Button("Restore Revision") { restoring = revision }.foregroundStyle(VellixSurface.violet)
                            } else { Text("Deletion revision retained").font(.footnote).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(VellixSpacing.md).pennedSheetField()
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(VellixSurface.coral) }
                if busy { ProgressView().frame(maxWidth: .infinity) }
            }
            .fontDesign(.rounded).fontWeight(.black).foregroundStyle(VellixSurface.ink)
            .padding(VellixSpacing.lg).disabled(busy)
        }
        .modifier(AccountLibraryPresentation(embedded: embeddedInWorkspace, busy: busy, close: { dismiss() }))
        .task { workspace.refreshSyncStatus(); reloadRecovery() }
        .macConfirmationDialog("Enable iCloud document sync?", isPresented: $enabling, titleVisibility: .visible) {
            Button("Enable Sync") { perform { try await workspace.enableSync(identity: identity) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This account library will upload to the current iCloud account. Other devices must use the same Penned account and iCloud account. Local-only Spaces are not included.") }
        .macConfirmationDialog("Adopt Spaces into \(accounts.currentUser?.displayName ?? "this account")?", isPresented: $adopting, titleVisibility: .visible) {
            Button("Adopt Selected Spaces") {
                perform {
                    try await workspace.adopt(spaceIDs: selectedSpaces, includeSavedStyles: includeStyles, identity: identity)
                    selectedSpaces = []; dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(workspace.localSpaces.filter { selectedSpaces.contains($0.id) }.map(\.title).joined(separator: ", ")) will move from the local-only library into this account. Their content and identifiers are preserved. They will upload if this account's sync is enabled.\(includeStyles ? " All local saved styles will also move." : " Saved styles will stay local.")")
        }
        .macConfirmationDialog("Re-create this account's CloudKit zone?", isPresented: $restoringCloud, titleVisibility: .visible) {
            Button("Restore Cloud Library") { perform { await workspace.synchronize(retry: true, restoreCloud: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Use this only after a removed-zone error. Penned will upload the retained local library to the same bound iCloud account. Existing local content will not be deleted.") }
        .macConfirmationDialog("Restore this revision?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible) {
            Button("Restore Revision") {
                guard let revision = restoring else { return }; restoring = nil
                perform { try await workspace.recover(revision); reloadRecovery() }
            }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: { Text("The current version will also be retained in recovery history.") }
    }

    private func action(_ title: String, icon: String, operation: @escaping () async throws -> Void) -> some View {
        Button { perform(operation) } label: {
            Label { Text(title).frame(maxWidth: .infinity, alignment: .leading) } icon: { LibraryIcon(name: icon, size: 22) }
                .padding(VellixSpacing.md).pennedSheetField()
        }.buttonStyle(.plain).foregroundStyle(VellixSurface.violet)
    }
    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !busy, accounts.currentAccountIdentity == identity else { return }
        busy = true; error = nil
        Task {
            defer { busy = false; workspace.refreshSyncStatus() }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
    private func reloadRecovery() { revisions = (try? workspace.recoveryRevisions()) ?? [] }
}

private struct AccountLibraryPresentation: ViewModifier {
    let embedded: Bool
    let busy: Bool
    let close: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content }
        else { content.pennedSheet(title: "Library & Sync", closeDisabled: busy, close: close) }
    }
}
