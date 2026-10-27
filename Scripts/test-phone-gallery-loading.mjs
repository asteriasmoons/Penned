import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

// Source-only checks. No compiler, build, app launch, or simulator.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = path => readFile(join(root, path), "utf8");

test("the default phone gallery crop keeps sixty percent and stays top-aligned", async () => {
    const preview = await read("Vellix/Documents/LibraryDocumentPreview.swift");
    assert.match(preview, /static var phoneGalleryHeightFraction: CGFloat\? \{\s+#if os\(iOS\)\s+return UIDevice\.current\.userInterfaceIdiom == \.phone \? 0\.6 : nil\s+#else\s+return nil\s+#endif\s+\}/);
    assert.match(preview, /height: geometry\.size\.height, alignment: \.top/);
    assert.match(preview, /\/ min\(1, max\(0\.01, visibleHeightFraction\)\)/);
    assert.match(preview, /\.clipped\(\)/);
    assert.match(preview, /\.frame\(width: current\.isThemed \? 376 : 360, height: 740, alignment: \.topLeading\)/);
    for (const width of [138, 194, 260]) {
        for (const snapshotWidth of [360, 376]) {
            const original = width * 740 / snapshotWidth;
            const cropped = width / ((snapshotWidth / 740) / 0.6);
            assert.ok(Math.abs(cropped / original - 0.6) < 1e-12);
        }
    }
});

test("document and tag galleries apply phone cropping but retain both iPad sizing paths", async () => {
    const browser = await read("Vellix/Documents/DocumentBrowserView.swift");
    assert.match(browser, /visibleHeightFraction: previewHeightFraction/);
    assert.match(browser, /if let phoneFraction = LibraryDocumentPreview\.phoneGalleryHeightFraction/);
    assert.match(browser, /return workspace == nil \? 1 : PadWorkspaceMetrics\.galleryPreviewHeightFraction/);
    assert.match(await read("Vellix/Tags/TagBrowserView.swift"), /visibleHeightFraction: LibraryDocumentPreview\.phoneGalleryHeightFraction\s+\?\? \(workspace == nil \? 1 : PadWorkspaceMetrics\.galleryPreviewHeightFraction\)/);
    const pad = await read("Vellix/App/PadWorkspaceModel.swift");
    assert.match(pad, /static let galleryPreviewHeightFraction: CGFloat = 0\.8 \/ galleryWidthIncrease/);
    for (const file of ["Vellix/App/PadWorkspaceSidebar.swift", "Vellix/Documents/HomeView.swift", "PennedMac/Browser/MacDocumentBrowser.swift"]) {
        assert.doesNotMatch(await read(file), /phoneGalleryHeightFraction/);
    }
});

test("only iPhone All Docs restores ten percent of the original preview height", async () => {
    const browser = await read("Vellix/Documents/DocumentBrowserView.swift");
    assert.match(browser, /private var previewHeightFraction: CGFloat \{\s+if let phoneFraction = LibraryDocumentPreview\.phoneGalleryHeightFraction \{\s+return mode == \.all && displayTitle == nil \? 0\.7 : phoneFraction\s+\}\s+return workspace == nil \? 1 : PadWorkspaceMetrics\.galleryPreviewHeightFraction\s+\}/);
    const fraction = Number(browser.match(/mode == \.all && displayTitle == nil \? (\d\.\d+) : phoneFraction/)[1]);
    for (const width of [138, 194, 260]) {
        for (const snapshotWidth of [360, 376]) {
            const original = width * 740 / snapshotWidth;
            const previous = original * 0.6;
            const restored = width / ((snapshotWidth / 740) / fraction);
            assert.ok(Math.abs((restored - previous) / original - 0.1) < 1e-12);
        }
    }
});

test("library startup uses the purple circular-dot animation on both mobile device types", async () => {
    const app = await read("Vellix/VellixApp.swift");
    assert.match(app, /else if startup\.isSwitching \|\| startup\.errorMessage == nil \{\s+PennedLibraryLoadingView\(\)/);
    assert.doesNotMatch(app, /ProgressView\("Opening library"\)/);
    const loader = await read("Vellix/Resources/PennedLibraryLoadingView.swift");
    assert.match(loader, /private let dotCount = 12/);
    assert.match(loader, /TimelineView\(\.animation\(minimumInterval: 0\.08, paused: reduceMotion \|\| scenePhase != \.active\)\)/);
    assert.match(loader, /Circle\(\)\s+\.fill\(VellixSurface\.violet\)/);
    assert.match(loader, /\.offset\(y: -15\)\s+\.rotationEffect\(\.degrees\(Double\(index\) \* 360 \/ Double\(dotCount\)\)\)/);
    assert.match(loader, /\.opacity\(reduceMotion \? 0\.8/);
    assert.match(loader, /\.accessibilityLabel\("Opening library"\)/);
    assert.doesNotMatch(loader, /\bProgressView\(|userInterfaceIdiom|#if os|Task\.sleep|Timer/);
    assert.doesNotMatch(await read("PennedMac/PennedMacApp.swift"), /PennedLibraryLoadingView/);
});
