import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MacAccountSettings: View {
    @EnvironmentObject private var app: MacApplicationModel
    @EnvironmentObject private var accounts: AppState
    @State private var signingIn = false
    @State private var deleting = false
    @State private var signingOut = false
    @State private var editing: String?
    @State private var value = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let user = accounts.currentUser {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 8) {
                            Group {
                                if let data = user.profileImageData, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill() }
                                else { LibraryIcon(name: "profilewavy", size: 64) }
                            }.frame(width: 100, height: 100).clipShape(Circle())
                            Button("Change Photo") { choosePhoto() }.controlSize(.small)
                            if user.profileImageData != nil { Button("Remove Photo") { perform { try accounts.updateImage(nil) } }.controlSize(.small) }
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            field("Name", text: user.displayName ?? "Not set", key: "name")
                            field("Contact Email", text: user.email ?? "Not set", key: "email")
                            LabeledContent("Sign-In Method", value: user.providerName)
                            if let email = user.authenticationEmail { LabeledContent("Sign-In Email", value: email).textSelection(.enabled) }
                        }
                    }
                    Button("Log Out") { signingOut = true }
                    if !accounts.syncState.isEmpty { Text(accounts.syncState).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Sign in to Penned").font(.headline)
                    Text("Use your existing account to access its document library.").foregroundStyle(.secondary)
                }
                Button(accounts.currentUser == nil ? "Sign In" : "Add Account") {
                    perform { try await app.prepareAccountChange(); signingIn = true }
                }.disabled(accounts.accountContainer == nil)
                if !accounts.savedAccounts.isEmpty {
                    Divider()
                    Text("Saved Accounts").font(.headline)
                    ForEach(accounts.savedAccounts, id: \.persistentModelID) { user in
                        Button {
                            perform { try await app.prepareAccountChange(); try await accounts.activate(user) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(user.displayName ?? user.providerName + " Account")
                                    Text(user.authenticationEmail ?? user.email ?? user.providerName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if user.identity == accounts.currentAccountIdentity { LibraryIcon(name: "checkwavy", size: 18) }
                            }.padding(12).background(VellixSurface.input, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(user.identity == accounts.currentAccountIdentity)
                    }
                }
                if accounts.currentUser != nil {
                    Divider().padding(.top, 16)
                    Text("Danger Zone").font(.headline)
                    Button("Delete Account", role: .destructive) { deleting = true }
                    Text("Deletes the account and its cloud profile. Local documents remain protected by their existing account ownership.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if busy || accounts.isWorking { ProgressView() }
            }.padding(26).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.disabled(busy || accounts.isWorking)
        .sheet(isPresented: $signingIn) {
            if let container = accounts.accountContainer { SignInView().environmentObject(accounts).modelContainer(container).frame(width: 520, height: 480) }
        }
        .macAlert(editing == "email" ? "Contact Email" : "Name", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Value", text: $value)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") { let field = editing; editing = nil; perform { if field == "email" { try accounts.updateEmail(value) } else { try accounts.updateCurrentUserDisplayName(value) } } }
        }
        .macConfirmationDialog("Log out of Penned?", isPresented: $signingOut, titleVisibility: .visible) {
            Button("Log Out") { perform { try await app.prepareAccountChange(); await accounts.signOut() } }
        }
        .macConfirmationDialog("Permanently delete your account?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { perform { try await app.prepareAccountChange(); try await accounts.deleteCurrentAccount() } }
        } message: { Text("This cannot be undone. Your pending document edits will be saved first.") }
        .macAlert("Account Action Failed", isPresented: Binding(get: { error != nil || accounts.errorMessage != nil }, set: { if !$0 { error = nil; accounts.errorMessage = nil } })) { Button("OK") { error = nil; accounts.errorMessage = nil } } message: { Text(error ?? accounts.errorMessage ?? "") }
    }
    private func field(_ title: String, text: String, key: String) -> some View {
        HStack { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(text).textSelection(.enabled) }; Spacer(); Button("Edit") { value = text == "Not set" ? "" : text; editing = key } }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
    private func choosePhoto() {
        let identity = accounts.currentAccountIdentity
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        perform {
            guard await panel.begin() == .OK, let url = panel.url, accounts.currentAccountIdentity == identity else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try SpaceIconImage.prepare(Data(contentsOf: url, options: .mappedIfSafe))
            try accounts.updateImage(data)
        }
    }
}
