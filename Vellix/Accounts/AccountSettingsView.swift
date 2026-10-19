import SwiftUI
import SwiftData
import PhotosUI

private enum AccountSheet: String, Identifiable {
    case signIn, accounts, name, email, library
    var id: String { rawValue }
}

struct AccountSettingsView: View {
    var embeddedInWorkspace = false
    @EnvironmentObject private var accounts: AppState
    @Environment(\.openURL) private var openURL
    @State private var sheet: AccountSheet?
    @State private var photo: PhotosPickerItem?
    @State private var photoTask: Task<Void, Never>?
    @State private var photoRequest = UUID()
    @State private var importing = false
    @State private var confirmLogout = false
    @State private var confirmDelete = false
    @State private var accountDeleted = false
    @State private var deletedAppleAccount = false

    var body: some View {
        VStack(spacing: 0) {
            if !embeddedInWorkspace { HStack {
                SettingsBackButton()
                Text("Account Settings")
                    .font(.system(.headline, design: .rounded).weight(.black))
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, VellixSpacing.lg).frame(minHeight: 60) }

            ScrollView {
                VStack(alignment: .leading, spacing: VellixSpacing.xl) {
                    avatar.frame(maxWidth: .infinity).padding(.vertical, VellixSpacing.lg)

                    if case .checking = accounts.status {
                        ProgressView("Checking account").frame(maxWidth: .infinity)
                    } else if let user = accounts.currentUser {
                        if user.remoteAuthDeleted {
                            Text("Your email account was deleted. Finish removing its iCloud profile and local account details.")
                                .font(.footnote).foregroundStyle(VellixSurface.secondaryInk)
                            accountButton("Finish Account Deletion", icon: "profilewavy", action: deleteAccount)
                        } else {
                            VStack(spacing: VellixSpacing.sm) {
                                detail("Name", value: user.displayName ?? "Not set") { sheet = .name }
                                detail("Contact Email", value: user.email ?? "Not set") { sheet = .email }
                                VStack(alignment: .leading, spacing: VellixSpacing.xs) {
                                    Text("Sign-In Method: \(user.providerName)")
                                    if let email = user.authenticationEmail { Text("Sign-In Email: \(email)").textSelection(.enabled) }
                                }.font(.footnote).foregroundStyle(VellixSurface.secondaryInk)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            accountButton("Log Out", icon: "dooropen") { confirmLogout = true }
                            accountButton("Library & Sync", icon: "cloudie") { sheet = .library }
                        }
                    } else {
                        accountButton("Sign In", icon: "profilewavy") { sheet = .signIn }
                    }

                    if accounts.accountContainer != nil {
                        accountButton("Add Account", icon: "addwavy") { sheet = .accounts }
                    } else {
                        accountButton("Retry Account Storage", icon: "arrowsprofile", action: accounts.retryStorage)
                    }

                    if !accounts.syncState.isEmpty {
                        HStack(spacing: VellixSpacing.sm) {
                            LibraryIcon(name: "cloudie", size: 19)
                            Text(accounts.syncState).font(.footnote)
                        }.foregroundStyle(VellixSurface.secondaryInk)
                    }
                    if let error = accounts.errorMessage {
                        VStack(alignment: .leading, spacing: VellixSpacing.sm) {
                            Text(error).font(.footnote).foregroundStyle(VellixSurface.coral)
                            if let user = accounts.currentUser, !user.remoteAuthDeleted {
                                Button("Retry iCloud Sync", action: accounts.refreshProfile)
                                    .foregroundStyle(VellixSurface.violet)
                            }
                        }
                    }

                    if let user = accounts.currentUser, !user.remoteAuthDeleted {
                        VStack(alignment: .leading, spacing: VellixSpacing.md) {
                            Text("Danger Zone").font(.headline)
                            Button(role: .destructive) { confirmDelete = true } label: {
                                VStack(alignment: .leading, spacing: VellixSpacing.xs) {
                                    Text("Delete Account").foregroundStyle(VellixSurface.coral)
                                    Text(user.isEmail
                                        ? "Permanently delete your email account and Penned profile details. Your local documents will be kept."
                                        : "Permanently delete your Penned account details from this device and iCloud. Your local documents will be kept.")
                                        .font(.footnote).foregroundStyle(VellixSurface.secondaryInk)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(VellixSpacing.lg).pennedSheetField()
                            }.buttonStyle(.plain)
                            if user.isApple {
                                Link("Manage Apple Account", destination: URL(string: "https://account.apple.com")!)
                                    .font(.footnote).foregroundStyle(VellixSurface.violet)
                            }
                        }.padding(.top, VellixSpacing.md)
                    }
                    if accounts.isWorking || importing { ProgressView().frame(maxWidth: .infinity) }
                }
                .fontDesign(.rounded).fontWeight(.black)
                .padding(VellixSpacing.lg).frame(maxWidth: 620).frame(maxWidth: .infinity)
                .disabled(accounts.isWorking)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { accounts.refreshProfile(); await accounts.waitForProfileSync() }
        }
        .foregroundStyle(VellixSurface.ink).tint(VellixSurface.violet)
        .background(VellixSurface.appBackground).preferredColorScheme(.dark)
        .navigationBarBackButtonHidden()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar).toolbarBackground(.hidden, for: .navigationBar)
        #elseif os(macOS)
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        .sheet(item: $sheet) { target in AccountSheetHost(target: target) }
        .task { accounts.refreshProfile(); await accounts.waitForProfileSync() }
        .confirmationDialog("Log out of Penned?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log Out") { Task { await accounts.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your documents and saved account details will stay on this device.") }
        .confirmationDialog("Permanently delete your Penned account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive, action: deleteAccount)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(accounts.currentUser?.isEmail == true
                ? "Your Supabase email account and its Penned profile details will be permanently deleted. Local documents will not be deleted."
                : "Your account name, contact email, and photo will be deleted from this device and iCloud. Local documents will not be deleted. This does not delete your Apple Account or revoke its Apple sign-in authorization.")
        }
        .alert("Penned Account Deleted", isPresented: $accountDeleted) {
            if deletedAppleAccount {
                Button("Manage Apple Account") { openURL(URL(string: "https://account.apple.com")!) }
            }
            Button("Done", role: .cancel) {}
        } message: {
            Text(deletedAppleAccount
                ? "Your account details were deleted. Your local documents were kept. To disconnect Sign in with Apple too, open your Apple Account's Sign-In & Security settings and stop using Sign in with Apple for Penned."
                : "Your email account and Penned profile details were deleted. Your local documents were kept.")
        }
        .onChange(of: photo) { _, item in importPhoto(item) }
        .onChange(of: accounts.currentAccountIdentity) { _, _ in photoRequest = UUID(); photoTask?.cancel(); importing = false }
        .onDisappear { photoRequest = UUID(); photoTask?.cancel() }
    }

    private var avatar: some View {
        let imageData = accounts.currentUser?.profileImageData
        return PhotosPicker(selection: $photo, matching: .images) {
            AccountAvatar(data: imageData, size: 144)
                .overlay(alignment: .bottomTrailing) {
                    LibraryIcon(name: "imagesign", size: 21)
                        .frame(width: 44, height: 44)
                        .background(VellixSurface.paperLifted, in: Circle())
                        .overlay(Circle().strokeBorder(VellixSurface.hairline))
                }
        }
        .buttonStyle(.plain).disabled(accounts.currentUser == nil || accounts.currentUser?.remoteAuthDeleted == true || importing || accounts.isWorking)
        .accessibilityLabel("Change account photo")
        .contextMenu {
            if accounts.currentUser?.profileImageData != nil {
                Button("Remove Photo", role: .destructive) {
                    do { try accounts.updateImage(nil) } catch { accounts.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    private func detail(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: VellixSpacing.md) {
                VStack(alignment: .leading, spacing: VellixSpacing.xs) {
                    Text(title).font(.footnote).foregroundStyle(VellixSurface.secondaryInk)
                    Text(value).font(.body).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                LibraryIcon(name: "pencil", size: 18).foregroundStyle(VellixSurface.violet)
            }.padding(VellixSpacing.lg).pennedSheetField()
        }.buttonStyle(.plain)
    }

    private func accountButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title).frame(maxWidth: .infinity, alignment: .leading) }
                icon: { LibraryIcon(name: icon, size: 20) }
                .padding(VellixSpacing.lg).foregroundStyle(VellixSurface.violet).pennedSheetField()
        }.buttonStyle(.plain)
    }

    private func importPhoto(_ item: PhotosPickerItem?) {
        guard let item, let id = accounts.currentAccountIdentity else { return }
        photoTask?.cancel()
        let request = UUID(); photoRequest = request; importing = true; photo = nil
        photoTask = Task {
            defer { if photoRequest == request { importing = false } }
            do {
                guard let input = try await item.loadTransferable(type: Data.self) else { throw AccountError.invalidImage }
                let data = try await Task.detached { try SpaceIconImage.prepare(input) }.value
                guard !Task.isCancelled, photoRequest == request, accounts.currentAccountIdentity == id else { return }
                try accounts.updateImage(data)
            } catch { if photoRequest == request { accounts.errorMessage = error.localizedDescription } }
        }
    }

    private func deleteAccount() {
        let wasApple = accounts.currentUser?.isApple == true
        Task {
            do {
                try await accounts.deleteCurrentAccount()
                deletedAppleAccount = wasApple
                accountDeleted = true
            } catch { accounts.errorMessage = error.localizedDescription }
        }
    }
}

private struct AccountAvatar: View {
    var data: Data?
    var size: CGFloat
    var body: some View {
        Group {
            if let data {
                SpaceImage(data: data, title: "Account", size: size)
            } else {
                LibraryIcon(name: "profilewavy", size: size * 0.55)
                    .foregroundStyle(VellixSurface.violet)
                    .frame(width: size, height: size).pennedSheetField(cornerRadius: size / 2)
            }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}

private struct AccountSheetHost: View {
    @EnvironmentObject private var accounts: AppState
    @Environment(\.dismiss) private var dismiss
    let target: AccountSheet
    var body: some View {
        if let container = accounts.accountContainer {
            content.modelContainer(container)
        } else {
            Text(AccountError.storageUnavailable.localizedDescription).padding(VellixSpacing.lg)
                .pennedSheet(title: "Account", close: { dismiss() })
        }
    }
    @ViewBuilder private var content: some View {
        switch target {
        case .signIn: SignInView()
        case .accounts: AccountSwitcherSheet()
        case .library:
            if let identity = accounts.currentAccountIdentity { AccountLibrarySheet(identity: identity) }
        case .name, .email:
            AccountDetailSheet(isEmail: target == .email, userID: accounts.currentAccountIdentity,
                value: target == .email ? accounts.currentUser?.email ?? "" : accounts.currentUser?.displayName ?? "")
        }
    }
}

private struct AccountDetailSheet: View {
    @EnvironmentObject private var accounts: AppState
    @Environment(\.dismiss) private var dismiss
    let isEmail: Bool
    let userID: AccountIdentity?
    @State var value: String
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: VellixSpacing.md) {
            TextField(isEmail ? "Contact Email" : "Name", text: $value)
                .textFieldStyle(.plain).padding(VellixSpacing.md).pennedSheetField()
                .autocorrectionDisabled(isEmail)
                #if os(iOS)
                .keyboardType(isEmail ? .emailAddress : .default)
                .textInputAutocapitalization(isEmail ? .never : .words)
                #endif
            if isEmail {
                Text("Contact email only. Your verified sign-in email is unchanged.").font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(VellixSurface.coral) }
            Spacer(minLength: 0)
        }
        .fontDesign(.rounded).fontWeight(.black).padding(VellixSpacing.lg)
        .pennedSheet(title: isEmail ? "Contact Email" : "Name", close: { dismiss() }) {
            Button("Save") {
                do {
                    guard accounts.currentAccountIdentity == userID else { throw AuthService.AuthServiceError.notSignedIn }
                    if isEmail { try accounts.updateEmail(value) } else { try accounts.updateCurrentUserDisplayName(value) }
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }.disabled((try? isEmail ? AccountValidation.email(value) : AccountValidation.name(value)) == nil)
        }
        .presentationDetents([.medium, .large])
    }
}

private struct AccountSwitcherSheet: View {
    @EnvironmentObject private var accounts: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showSignIn = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(spacing: VellixSpacing.sm) {
                ForEach(accounts.savedAccounts, id: \.persistentModelID) { user in
                    Button {
                        Task {
                            do { try await accounts.activate(user); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack(spacing: VellixSpacing.md) {
                            AccountAvatar(data: user.profileImageData, size: 38)
                            VStack(alignment: .leading, spacing: VellixSpacing.xs) {
                                Text(user.displayName ?? "\(user.providerName) Account")
                                if let email = user.email { Text(email).font(.footnote).foregroundStyle(.secondary) }
                                Text(user.remoteAuthDeleted ? "Deletion pending" : "\(user.providerName) · \(user.authenticationEmail ?? "Sign-in email unavailable")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if let identity = user.identity, identity == accounts.currentAccountIdentity { LibraryIcon(name: "checkwavy", size: 20) }
                        }.padding(VellixSpacing.md).pennedSheetField()
                    }.buttonStyle(.plain)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(VellixSurface.coral) }
            }.padding(VellixSpacing.lg)
        }
        .fontDesign(.rounded).fontWeight(.black).disabled(accounts.isWorking)
        .pennedSheet(title: "Accounts", closeDisabled: accounts.isWorking, close: { dismiss() }) {
            Button("Sign In") { showSignIn = true }.disabled(accounts.isWorking)
        }
        .onAppear { accounts.reloadAccounts() }
        .sheet(isPresented: $showSignIn, onDismiss: { if accounts.currentUser != nil { dismiss() } }) { SignInView() }
    }
}
