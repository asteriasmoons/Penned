import SwiftUI

struct PublishingRuntime: ViewModifier {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var accounts: AppState
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content.task(id: (accounts.currentAccountIdentity?.libraryOwnerKey ?? "signed-out") + String(accounts.currentUser?.remoteAuthDeleted ?? false)) {
            environment.publishing.start(identity: { [weak accounts] in
                accounts?.currentUser?.remoteAuthDeleted == false ? accounts?.currentAccountIdentity : nil
            }, accessToken: { [weak accounts] in
                guard let accounts else { throw PublishingFailure.authenticationRequired }
                return try await accounts.publishingAccessToken()
            }, authorAvatar: { [weak accounts] in accounts?.currentUser?.profileImageData })
        }
        .onChange(of: accounts.currentUser?.profileRevision) { _, _ in environment.publishing.profileChanged() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { environment.publishing.retry() } }
        .onDisappear { environment.publishing.stop() }
    }
}

enum PublishingPanel: String, Identifiable {
    case url, password, email, people, domains, emailSettings, expiration, comments, advanced, qr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .url: "Customize URL"
        case .password: "Password"
        case .email: "Email Access"
        case .people: "Add People"
        case .domains: "Add Email Domain Access"
        case .emailSettings: "Email Access Settings"
        case .expiration: "Expiration Date"
        case .comments: "Comments"
        case .advanced: "Advanced Options"
        case .qr: "Published Link"
        }
    }
}

struct PublicationOptionRow: View {
    let title: String
    let icon: String
    var value = ""
    var destructive = false
    var inactive = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LibraryIcon(name: icon, size: 20).frame(width: 24)
                Text(title).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(.secondary).lineLimit(1)
                if !destructive { LibraryIcon(name: "chevright", size: 13).foregroundStyle(.secondary) }
            }.padding(.horizontal, 14).frame(minHeight: 52)
                .foregroundStyle(destructive ? VellixSurface.coral : VellixSurface.controlInk)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(inactive)
    }
}

struct PublicationPrimaryButton: View {
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 46) }
            .buttonStyle(.plain).foregroundStyle(Color.black)
            .background(PennedSheetStyle.accent, in: Capsule())
    }
}
