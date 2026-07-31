//
//  ContentView.swift
//  Vellix
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VellixShellView()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppEnvironment.makePreview())
}
