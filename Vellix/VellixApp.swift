//
//  VellixApp.swift
//  Vellix
//
//  Created by Asteria Moon on 7/29/26.
//

import Combine
import SwiftUI

@main
struct VellixApp: App {
    @StateObject private var startup = VellixStartup()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let environment = startup.environment {
                    ContentView().environmentObject(environment)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Library Unavailable").font(.title2.bold())
                            Button("Retry", action: startup.open)
                            DisclosureGroup("Details") {
                                Text(startup.errorMessage ?? "The persistent library could not be opened.")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .padding(28)
                    }
                }
            }
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    startup.environment?.taskNotifications.refresh()
                    startup.environment?.calendar.refresh()
                }
                if phase == .background {
                    startup.environment?.editorCache.preparedModels.forEach { $0.flushPendingSave() }
                }
            }
        }
        .commands {
            if let environment = startup.environment { VellixCommands(environment: environment) }
        }
    }
}

@MainActor
private final class VellixStartup: ObservableObject {
    @Published var environment: AppEnvironment?
    @Published var errorMessage: String?

    init() { open() }

    func open() {
        do {
            environment = try AppEnvironment.makeLive()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
