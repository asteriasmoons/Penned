//
//  VellixApp.swift
//  Vellix
//
//  Created by Asteria Moon on 7/29/26.
//

import Combine
import SwiftUI
import SwiftData
import AuthenticationServices
import CloudKit

@main
struct VellixApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(PennedApplicationDelegate.self) private var applicationDelegate
    #elseif canImport(AppKit)
    @NSApplicationDelegateAdaptor(PennedApplicationDelegate.self) private var applicationDelegate
    #endif
    @StateObject private var startup = LibraryWorkspace()
    @StateObject private var accounts = AppState()
    @State private var recoverySignIn = false
    @Environment(\.scenePhase) private var scenePhase

    private var workspaceSessionKey: String {
        if case .checking = accounts.status { return "checking" }
        return accounts.currentAccountIdentity?.libraryOwnerKey ?? "signed-out"
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if startup.matches(accounts.currentAccountIdentity), let environment = startup.environment {
                    ContentView().environmentObject(environment).environmentObject(accounts)
                        .environmentObject(startup).id(environment.database.libraryID + (accounts.currentAccountIdentity?.libraryOwnerKey ?? "signed-out"))
                } else if startup.isSwitching || startup.errorMessage == nil {
                    ProgressView("Opening library")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Library Unavailable").font(.title2.bold())
                            Button("Retry") { Task { await startup.activate(accounts.currentAccountIdentity) } }
                            if let previous = startup.identity, previous != accounts.currentAccountIdentity,
                               let user = accounts.savedAccounts.first(where: { $0.identity == previous && !$0.remoteAuthDeleted }) {
                                Button("Return to Previous Account") {
                                    Task {
                                        do { try await accounts.activate(user) }
                                        catch { accounts.errorMessage = error.localizedDescription }
                                    }
                                }
                            }
                            if accounts.accountContainer != nil {
                                Button("Account Sign In") { recoverySignIn = true }
                            }
                            if let error = accounts.errorMessage { Text(error).font(.footnote).foregroundStyle(VellixSurface.coral) }
                            DisclosureGroup("Details") {
                                Text(startup.errorMessage ?? "The persistent library could not be opened.")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .fontDesign(.rounded).fontWeight(.black).tint(VellixSurface.violet).padding(28)
                    }
                }
            }
            .preferredColorScheme(.dark)
            .sheet(isPresented: $recoverySignIn) {
                if let container = accounts.accountContainer { SignInView().environmentObject(accounts).modelContainer(container) }
            }
            .task { await accounts.bootstrap()?.value }
            .task(id: workspaceSessionKey) {
                if case .checking = accounts.status { return }
                guard !Task.isCancelled else { return }
                startup.currentOwner = { accounts.currentUser?.remoteAuthDeleted == false ? accounts.currentAccountIdentity?.libraryOwnerKey : nil }
                PennedSyncNotifications.synchronize = { await startup.synchronize() }
                await startup.activate(accounts.currentAccountIdentity)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    accounts.bootstrap(force: true)
                    startup.environment?.taskNotifications.refresh()
                    startup.environment?.calendar.refresh()
                    Task { await startup.synchronize() }
                }
                if phase == .background {
                    startup.environment?.editorCache.preparedModels.forEach { $0.flushPendingSave() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                Task { await accounts.handleAppleCredentialRevoked() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                accounts.refreshProfile()
                Task { await startup.cloudIdentityChanged() }
            }
        }
        .commands {
            if let environment = startup.environment { VellixCommands(environment: environment) }
        }
    }
}
