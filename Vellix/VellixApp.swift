//
//  VellixApp.swift
//  Vellix
//
//  Created by Asteria Moon on 7/29/26.
//

import SwiftUI

@main
struct VellixApp: App {
    @StateObject private var environment =
        AppEnvironment.makeLive()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(environment)
                .preferredColorScheme(.dark)
        }
        .commands {
            VellixCommands(environment: environment)
        }
    }
}
