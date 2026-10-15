//
//  VellixCommands.swift
//  Vellix
//

import SwiftUI

struct VellixCommands: Commands {
    @ObservedObject var environment: AppEnvironment

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Page") {
                _ = environment.createDocument()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Folder") {
                environment.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Page") {
            Button("Star Selected Page") {
                environment.toggleFavoriteSelected()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(environment.selectedDocumentID == nil)

            Button("Duplicate Selected Page") {
                environment.duplicateSelected()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(environment.selectedDocumentID == nil)

            Button("Move Selected Page to Trash") {
                environment.trashSelected()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(environment.selectedDocumentID == nil)

            Divider()

            Button("Search") {
                environment.focusLibrarySearch()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Toggle Inspector") {
                environment.isInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }

        SidebarCommands()
    }
}
