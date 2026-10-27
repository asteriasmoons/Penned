import Foundation

// Explicit launch-argument fixtures use an in-memory library, never the user's database.
@MainActor enum MacVerificationFixtures {
    static func populate(_ environment: AppEnvironment) throws {
        for (index, title) in ["Desktop Writing", "Night Notes", "Project Outline", "Reading Journal", "Research"].enumerated() {
            let appearance: DocumentAppearance = index == 1 ? .defaultForTheme(.lunarClouds)
                : index == 4 ? .defaultForTheme(.neonCode) : .plain
            let json = TipTapContentAnalyzer.starterDocument(title: "", lines: [
                "A saved rich-text paragraph for native Mac verification.",
                "The document body must remain visible when tabs, sidebars, and inspector panels change.",
                "Edits use Penned's existing document format and save pipeline."
            ])
            let document = try environment.documents.create(DocumentDraft(title: title, spaceID: environment.selectedSpaceID, appearanceJSON: appearance.encodedJSON(), tipTapJSON: json))
            if index < 2 { _ = try environment.documents.setFavorite(id: document.id, isFavorite: true) }
        }
        environment.refresh()
    }
}
