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
    @StateObject private var startup = LibraryWorkspace(defersStartupServices: true)
    @StateObject private var accounts = AppState(deferStorageOpen: true)
    @State private var launchStarted: TimeInterval?
    @State private var recordedFirstWorkspace = false
    #if os(iOS)
    @StateObject private var webClipper = WebClipperCoordinator()
    @State private var clipperAccountSettings = false
    #endif
    @State private var recoveryAccountSettings = false
    @State private var pendingDocumentLink: URL?
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
                        .task(id: ObjectIdentifier(environment)) {
                            if !recordedFirstWorkspace {
                                recordedFirstWorkspace = true
                                PennedDiagnostics.markStartup("workspace-mounted", since: launchStarted)
                            }
                            await startup.startOpenedLibraryServices()
                        }
                        .task(id: ObjectIdentifier(environment)) { await openPendingDocumentLink() }
                } else if startup.isSwitching || startup.errorMessage == nil {
                    PennedLibraryLoadingView()
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
                                Button("Account Settings") { recoveryAccountSettings = true }
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
            .foregroundStyle(VellixSurface.ink)
            .background { VellixSurface.appBackground.ignoresSafeArea() }
            .pennedApplicationAppearance()
            .sheet(isPresented: $recoveryAccountSettings) {
                if let container = accounts.accountContainer { AccountSettingsView().environmentObject(accounts).environmentObject(startup).modelContainer(container) }
            }
            .task {
                if launchStarted == nil { launchStarted = PennedDiagnostics.markStartup("launch-task.start") }
                startup.prepareDatabase()
                await accounts.bootstrap()?.value
            }
            .onOpenURL { url in
                guard url.scheme?.lowercased() == "penned" else { return }
                #if os(iOS)
                if url.host == "clipper" {
                    clipperAccountSettings = true
                    webClipper.refresh()
                    return
                }
                #endif
                pendingDocumentLink = url
                Task { await openPendingDocumentLink() }
            }
            #if os(iOS)
            .task(id: workspaceSessionKey + (startup.environment?.database.libraryID ?? "") + String(accounts.isWorking) + String(startup.isSwitching)) {
                webClipper.connect(accounts: accounts, environment: startup.matches(accounts.currentAccountIdentity) ? startup.environment : nil)
            }
            .sheet(isPresented: $clipperAccountSettings) {
                if let container = accounts.accountContainer {
                    AccountSettingsView().environmentObject(accounts).environmentObject(startup).modelContainer(container)
                }
            }
            #endif
            .task(id: workspaceSessionKey) {
                if case .checking = accounts.status { return }
                guard !Task.isCancelled else { return }
                startup.currentOwner = { accounts.currentUser?.remoteAuthDeleted == false ? accounts.currentAccountIdentity?.libraryOwnerKey : nil }
                PennedSyncNotifications.synchronize = { await startup.synchronize() }
                await startup.activate(accounts.currentAccountIdentity)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    // Initial activation is owned by the startup task. On a
                    // real foreground return, revalidate and resume services.
                    guard startup.matches(accounts.currentAccountIdentity) else { return }
                    accounts.bootstrap(force: true)
                    #if os(iOS)
                    webClipper.refresh()
                    #endif
                    startup.environment?.taskNotifications.refresh()
                    startup.environment?.calendar.refresh()
                    Task {
                        try? await Task.sleep(for: .seconds(8))
                        guard !Task.isCancelled, scenePhase == .active else { return }
                        await startup.synchronize()
                    }
                }
                if phase == .background {
                    startup.environment?.editorCache.preparedModels.forEach { $0.flushPendingSave() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                Task { await accounts.handleAppleCredentialRevoked() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged).receive(on: DispatchQueue.main)) { _ in
                accounts.refreshProfile()
                Task { await startup.cloudIdentityChanged() }
            }
        }
        .commands {
            if let environment = startup.environment { VellixCommands(environment: environment) }
        }
    }

    @MainActor private func openPendingDocumentLink() async {
        guard let url = pendingDocumentLink, startup.matches(accounts.currentAccountIdentity), let environment = startup.environment else { return }
        pendingDocumentLink = nil
        do { if let document = try await DocumentInternalLink.resolve(url, environment: environment) { environment.select(document) } }
        catch { environment.errorMessage = error.localizedDescription }
    }
}
