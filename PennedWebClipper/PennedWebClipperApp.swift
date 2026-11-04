import SwiftUI

@main
struct PennedWebClipperApp: App {
    @StateObject private var setup = ClipperSetupModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ClipperSetupView(model: setup)
                .preferredColorScheme(.dark)
                .task { await setup.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await setup.refresh() } }
                }
        }
    }
}
