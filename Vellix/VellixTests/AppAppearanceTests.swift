import Foundation
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#endif
@testable import Vellix

@Suite @MainActor
struct AppAppearanceTests {
    @Test(arguments: PennedAppearancePreference.allCases)
    func preferencesPersistIndependentlyOfAccounts(_ preference: PennedAppearancePreference) throws {
        let suite = "Penned.Appearance.Tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(preference.rawValue, forKey: PennedAppearancePreference.storageKey)
        #expect(PennedAppearancePreference.read(from: try #require(UserDefaults(suiteName: suite))) == preference)
    }

    @Test func existingAndNewInstallationsRemainDarkWithoutAValidPreference() throws {
        let suite = "Penned.Appearance.Tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PennedAppearancePreference.read(from: defaults) == .dark)
        defaults.set("invalid", forKey: PennedAppearancePreference.storageKey)
        #expect(PennedAppearancePreference.read(from: defaults) == .dark)
    }

    @Test func systemTracksBothSchemesWhileExplicitPreferencesDoNot() {
        #expect(PennedAppearancePreference.system.colorScheme == nil)
        for scheme in [ColorScheme.light, .dark] {
            #expect(PennedAppearancePreference.system.effectiveScheme(system: scheme) == scheme)
            #expect(PennedAppearancePreference.light.effectiveScheme(system: scheme) == .light)
            #expect(PennedAppearancePreference.dark.effectiveScheme(system: scheme) == .dark)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func plainDocumentsResolveWithoutChangingTheirSavedAppearance(_ scheme: ColorScheme) {
        let saved = DocumentAppearance.plain
        let encoded = saved.encodedJSON()
        let colors = DocumentPresentationColors.resolve(scheme)
        let display = saved.resolved(for: scheme)
        #expect(display.editorBackground == .solid(colors.backdrop))
        #expect(display.innerPageBackground == .solid(colors.paper))
        #expect(display.textColorHex == colors.text)
        #expect(saved == .plain && DocumentAppearance.decode(encoded) == saved)
        #expect(display.themeID == nil && display.fontStyle == saved.fontStyle)
    }

    @Test func legacyDefaultRecordsAndAbsentAppearanceBothFollowTheApplication() {
        let legacy = """
        {"editorBackground":{"kind":"solid","colorHex":"#343434","secondaryColorHex":"#343434"},
        "innerPageBackground":{"kind":"solid","colorHex":"#242424","secondaryColorHex":"#242424"},
        "textColorHex":"#F7F7F7","fontStyle":"rounded"}
        """
        let saved = DocumentAppearance.decode(legacy)
        #expect(saved.customizedFields == nil && saved.isThemeDependent)
        #expect(saved.resolved(for: .light) == DocumentAppearance.plain.resolved(for: .light))
        #expect(DocumentAppearance.decode(nil).resolved(for: .light) == saved.resolved(for: .light))
    }

    @Test(arguments: [DocumentThemeID.custom, .lunarClouds, .neonCode])
    func explicitStylesStayIdenticalInBothSchemes(_ theme: DocumentThemeID) {
        var saved = DocumentAppearance.defaultForTheme(theme)
        saved.editorBackground = .solid("#F1A5C7")
        saved.innerPageBackground = .solid("#FFF1DB")
        saved.textColorHex = "#30213C"
        saved.fontStyle = .serif
        #expect(!saved.isThemeDependent)
        #expect(saved.resolved(for: .light) == saved && saved.resolved(for: .dark) == saved)
    }

    @Test func legacyCustomValuesAndFontsArePreservedWithoutFreezingDefaultFields() {
        var saved = DocumentAppearance.plain
        saved.textColorHex = "#9734C8"
        saved.fontStyle = .serif
        #expect(saved.resolved(for: .light).textColorHex == "#9734C8")
        #expect(saved.resolved(for: .light).fontStyle == .serif)
        #expect(saved.resolved(for: .light).editorBackground == .solid(DocumentPresentationColors.light.backdrop))
        saved.editorBackground = .solid("#FFAACC")
        #expect(saved.resolved(for: .light) == saved && !saved.isThemeDependent)
    }

    @Test func aLegacyExplicitBlackSurfaceKeepsItsWhiteTextEvenWithoutAThemeID() {
        var saved = DocumentAppearance.plain
        saved.editorBackground = .solid("#000000")
        #expect(saved.themeID == nil && !saved.isThemeDependent)
        #expect(saved.resolved(for: .light) == saved)
        #expect(saved.resolved(for: .light).textColorHex == "#F7F7F7")
        var record = DocumentRecord(title: "Legacy custom black")
        record.appearanceJSON = saved.encodedJSON()
        let preview = DocumentPreviewContent(document: record, children: [], collections: [])
        #expect(preview.cacheKey(for: .light) == preview.cacheKey(for: .dark))
    }

    @Test func redundantLegacySolidBackgroundMetadataDoesNotFreezeDefaultDocuments() {
        var saved = DocumentAppearance.plain
        saved.editorBackground.gradientDirection = .diagonal
        saved.editorBackground.blurImage = false
        saved.editorBackground.effect = .immersive
        saved.innerPageBackground.effect = .immersive
        saved.showsCover = false
        #expect(saved.isThemeDependent)
        #expect(saved.resolved(for: .light).editorBackground == .solid(DocumentPresentationColors.light.backdrop))
        #expect(saved.resolved(for: .light).textColorHex == DocumentPresentationColors.light.text)
    }

    @Test func explicitDefaultColoredTextCanRemainWhiteInLightMode() {
        var saved = DocumentAppearance.plain
        saved.markCustomized(.text)
        #expect(saved.resolved(for: .light).textColorHex == "#F7F7F7")
        #expect(DocumentAppearance.decode(saved.encodedJSON()).customizedFields == [.text])
        #expect(saved.resolved(for: .light).editorBackground != saved.editorBackground)
    }

    @Test func returningToPlainAppearanceRestoresAutomaticPresentation() {
        var saved = DocumentAppearance.defaultForTheme(.neonCode)
        saved.markCustomized(.text)
        saved = .plain
        #expect(saved.customizedFields == nil && saved.isThemeDependent)
        #expect(saved.resolved(for: .light).textColorHex == DocumentPresentationColors.light.text)
        #expect(saved.resolved(for: .dark) == .plain)
    }

    @Test func defaultPreviewKeysDifferButExplicitStylesKeepTheirKeys() {
        var document = DocumentRecord(title: "Plain")
        let plain = DocumentPreviewContent(document: document, children: [], collections: [])
        #expect(plain.cacheKey(for: .light) != plain.cacheKey(for: .dark))
        document.appearanceJSON = DocumentAppearance.defaultForTheme(.neonCode).encodedJSON()
        let styled = DocumentPreviewContent(document: document, children: [], collections: [])
        #expect(styled.cacheKey(for: .light) == styled.cacheKey(for: .dark))
        let child = DocumentRecord(title: "Default nested page", parentDocumentID: document.id)
        let parent = DocumentPreviewContent(document: document, children: [child], collections: [])
        #expect(parent.cacheKey(for: .light) != parent.cacheKey(for: .dark))
    }

    @Test func presentationAndPreviewResolutionNeverWriteDocumentOrHistoryRecords() throws {
        let database = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: database)
        let saved = try documents.create(DocumentDraft(title: "Saved", tipTapJSON: TipTapContentAnalyzer.starterDocument(title: "", lines: ["Original body"])))
        let storedBefore = try documents.requireDocument(id: saved.id)
        let snapshots = SnapshotRepository(database: database)
        let before = try snapshots.history(documentID: saved.id)
        for scheme in [ColorScheme.light, .dark, .light] {
            _ = saved.appearance.resolved(for: scheme)
            _ = DocumentPreviewContent(document: saved, children: [], collections: []).cacheKey(for: scheme)
        }
        let after = try documents.requireDocument(id: saved.id)
        #expect(after == storedBefore)
        #expect(after.tipTapJSON == saved.tipTapJSON && after.appearanceJSON == nil)
        #expect(try snapshots.history(documentID: saved.id) == before)
    }

    @Test func sharedApplicationColorsHaveReadableLightAndDarkContrast() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let background = VellixSurface.appBackground.resolve(in: environment)
            for color in [VellixSurface.ink, VellixSurface.secondaryInk, VellixSurface.violet] {
                let foreground = color.resolve(in: environment)
                #expect(contrast(foreground, background) >= 4.5)
            }
        }
    }

    #if os(macOS)
    @Test func appearanceSettingsRenderDistinctReadablePalettesWithoutChangingTheirDimensions() async throws {
        let suite = "Penned.Appearance.Tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var images: [CGImage] = []
        for scheme in [ColorScheme.light, .dark] {
            let window = NSWindow(contentRect: CGRect(x: 30, y: 30, width: 390, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: PennedAppearanceSettingsView().defaultAppStorage(defaults)
                .environment(\.colorScheme, scheme).frame(width: 390, height: 480))
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            #expect(image.width == image.height * 390 / 480)
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt32.self)
            #expect(Set(UnsafeBufferPointer(start: pixels, count: image.width * image.height)).count > 10, "Settings must contain painted controls and labels, not just a background")
            images.append(image)
            try DocumentPreviewImageFile.write(image, to: FileManager.default.temporaryDirectory
                .appendingPathComponent("penned-appearance-settings-\(scheme == .light ? "light" : "dark").png"))
        }
        #expect(images[0].dataProvider?.data != images[1].dataProvider?.data)
    }
    #endif

    @Test func nativePreviewCacheRendersDefaultThemesSeparatelyAndReusesCustomPixels() async throws {
        let database = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: database)
        let store = AttachmentStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let collections = CollectionRepository(database: database, documents: documents)
        let assets = try #require(ProcessInfo.processInfo.environment["PENNED_EDITOR_ASSET_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "VellixEditor", withExtension: "bundle"))
        let html = try TipTapEditorAssetCache.document(in: assets)
        let previews = DocumentPreviewCache(documents: documents, attachments: store, collections: collections,
            loadEditor: { webView, _ in webView.loadHTMLString(html.html, baseURL: assets) })
        let plain = try documents.create(DocumentDraft(title: "Default preview", tipTapJSON: TipTapContentAnalyzer.starterDocument(title: "", lines: ["Theme-aware preview body"])))
        let before = try documents.requireDocument(id: plain.id)
        let light = try #require(await previews.image(for: plain, colorScheme: .light))
        let dark = try #require(await previews.image(for: plain, colorScheme: .dark))
        #expect(light.width == dark.width && light.height == dark.height)
        #expect(light.dataProvider?.data != dark.dataProvider?.data)
        for (name, image) in [("light", light), ("dark", dark)] {
            try DocumentPreviewImageFile.write(image, to: FileManager.default.temporaryDirectory
                .appendingPathComponent("penned-appearance-document-\(name).png"))
        }
        #expect(previews.cachedImage(for: plain, colorScheme: .light) === light)
        #expect(previews.cachedImage(for: plain, colorScheme: .dark) === dark)
        #expect(try documents.requireDocument(id: plain.id) == before)

        let custom = try documents.create(DocumentDraft(title: "Custom preview", appearanceJSON: DocumentAppearance.defaultForTheme(.neonCode).encodedJSON()))
        let first = try #require(await previews.image(for: custom, colorScheme: .light))
        let second = try #require(await previews.image(for: custom, colorScheme: .dark))
        #expect(first === second)
        previews.remove(documentIDs: [plain.id, custom.id])
    }

    private func contrast(_ first: Color.Resolved, _ second: Color.Resolved) -> Double {
        func luminance(_ color: Color.Resolved) -> Double {
            func linear(_ value: Float) -> Double { let v = Double(value); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
