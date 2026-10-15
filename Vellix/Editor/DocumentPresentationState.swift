import Foundation

nonisolated struct DocumentPresentationState {
    private(set) var generation = 0
    private(set) var documentID: String?
    private(set) var webPrepared = false
    private var expectedNativeViews: [String: String] = [:]
    private var nativeLayouts: [String: String] = [:]
    private var confirmedFrameGeneration: Int?

    var isReady: Bool {
        isContentReady && confirmedFrameGeneration == generation
    }
    var isContentReady: Bool {
        documentID != nil && webPrepared && expectedNativeViews.allSatisfy { nativeLayouts[$0.key] == $0.value }
    }
    mutating func begin(documentID: String?) {
        generation += 1; self.documentID = documentID
        webPrepared = false; expectedNativeViews = [:]; nativeLayouts = [:]
        confirmedFrameGeneration = nil
    }
    mutating func startPreparation() -> Int { generation += 1; webPrepared = false; return generation }
    mutating func prepared(generation: Int, nativeViews: [String: String]) {
        guard generation == self.generation, documentID != nil else { return }
        webPrepared = true; expectedNativeViews = nativeViews
    }
    mutating func nativeDidLayout(blockID: String, viewID: String) { nativeLayouts[blockID] = viewID }
    mutating func framePresented(generation: Int) {
        guard generation == self.generation, isContentReady else { return }
        confirmedFrameGeneration = generation
    }
}
