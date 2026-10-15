import Foundation
import Testing
@testable import Vellix

@MainActor
struct DocumentPreviewTests {
    @Test func editsAndOwnThemeInvalidateTheSnapshot() {
        let original = DocumentRecord(title: "Notes")
        let key = DocumentPreviewCache.cacheKey(original, children: [])
        var edited = original
        edited.title = "Renamed"
        #expect(key != DocumentPreviewCache.cacheKey(edited, children: []))
        edited = original
        edited.tipTapJSON = TipTapContentAnalyzer.starterDocument(title: "Notes", lines: ["New content"])
        #expect(key != DocumentPreviewCache.cacheKey(edited, children: []))
        edited = original
        edited.appearanceJSON = DocumentAppearance.defaultForTheme(.neonCode).encodedJSON()
        #expect(key != DocumentPreviewCache.cacheKey(edited, children: []))
        edited = original
        edited.cover = "covers/new.png"
        #expect(key != DocumentPreviewCache.cacheKey(edited, children: []))
    }

    @Test func openingOrStarringDoesNotRerenderTheDocument() {
        let original = DocumentRecord(title: "Notes")
        var opened = original
        opened.lastOpenedAt = .now
        opened.isFavorite = true
        #expect(DocumentPreviewCache.cacheKey(original, children: []) == DocumentPreviewCache.cacheKey(opened, children: []))
    }

    @Test func childEditsInvalidateTheParentButChildOrderDoesNot() {
        let parent = DocumentRecord(title: "Parent")
        let child = DocumentRecord(title: "Child", parentDocumentID: parent.id)
        let second = DocumentRecord(title: "Second", parentDocumentID: parent.id)
        let key = DocumentPreviewCache.cacheKey(parent, children: [child, second])
        #expect(key == DocumentPreviewCache.cacheKey(parent, children: [second, child]))
        var changed = child
        changed.tipTapJSON = TipTapContentAnalyzer.starterDocument(title: "Child", lines: ["Changed"])
        #expect(key != DocumentPreviewCache.cacheKey(parent, children: [changed, second]))
    }

    @Test func pageBreaksSplitNativeSurfacesWithoutCoveringTheGap() {
        let result = PreviewPageBreak.segments([PreviewPageBreak(y: 50, height: 14)], bodyY: 80, totalHeight: 400)
        #expect(result == [PreviewPageBreak(y: 0, height: 130), PreviewPageBreak(y: 144, height: 256)])
    }

    @Test func pageBreaksOutsideThePreviewDoNotCreateExtraSurfaces() {
        let result = PreviewPageBreak.segments([PreviewPageBreak(y: 900, height: 14)], bodyY: 80, totalHeight: 400)
        #expect(result == [PreviewPageBreak(y: 0, height: 400)])
        #expect(PreviewPageBreak.segments([], bodyY: 80, totalHeight: 400) == result)
    }
}
