//
//  PennedMacApp.swift
//  PennedMac
//
//  Created by Asteria Moon on 10/18/26.
//

import SwiftUI
import AppKit

@main
struct PennedMacApp: App {
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var delegate
    @StateObject private var app = MacApplicationModel()
    var body: some Scene {
        WindowGroup("Penned", id: "workspace") {
            MacLibraryWindowRoot().environmentObject(app).environmentObject(app.accounts).environmentObject(app.library)
                .pennedApplicationAppearance()
                .macApplicationControls()
        }
        .defaultSize(width: 1320, height: 880)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands { MacWorkspaceCommands() }
        Settings {
            MacSettingsRoot().environmentObject(app).environmentObject(app.accounts).environmentObject(app.library)
                .pennedApplicationAppearance()
                .macApplicationControls()
        }
    }
}
