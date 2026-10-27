import { readFile } from "node:fs/promises";
import assert from "node:assert/strict";
import test from "node:test";

const root = new URL("../Vellix/", import.meta.url);
const read = file => readFile(new URL(file, root), "utf8");

test("Penned icon menus explicitly select button-backed, borderless native triggers", async () => {
  const source = await read("Resources/VellixDesignSystem.swift");
  assert.match(source, /extension Menu \{\s+func pennedIconMenuStyle\(\) -> some View \{\s+menuStyle\(\.button\)\.buttonStyle\(\.borderless\)/);
});

const menus = {
  "Documents/LibraryChrome.swift": 2,
  "Documents/HomeView.swift": 3,
  "Documents/DocumentBrowserView.swift": 1,
  "Spaces/SpaceViews.swift": 1,
  "App/PadWorkspaceSidebar.swift": 1,
  "App/PadWorkspaceView.swift": 1,
  "App/VellixShellView.swift": 1,
  "Collections/CollectionViewSheets.swift": 2,
  "Collections/CollectionKanbanView.swift": 1,
  "Editor/InlinePropertyEditorSheet.swift": 2,
  "Editor/DocumentEditorView.swift": 3,
};
for (const [file, count] of Object.entries(menus)) {
  test(`${file} uses the shared style for its icon-bearing menu triggers`, async () => {
    const source = await read(file);
    assert.equal([...source.matchAll(/\.pennedIconMenuStyle\(\)/g)].length, count);
    assert.doesNotMatch(source, /\.menuStyle\(\.borderlessButton\)/);
  });
}

test("masked chevrons are flattened only in the read-only PDF preview with scoped cache invalidation", async () => {
  const preview = await read("Documents/DocumentPreviewCache.swift");
  assert.match(preview, /async function rasterizedIcon\(/);
  assert.match(preview, /getComputedStyle\(button, '::before'\)/);
  assert.match(preview, /mask === 'none'\) continue/);
  assert.match(preview, /icon.backgroundColor/);
  assert.match(preview, /context.globalCompositeOperation = 'source-in'/);
  assert.match(preview, /mask-image: none !important/);
  assert.match(preview, /button.removeAttribute\('data-penned-preview-icon'\)/);
  assert.match(await read("Documents/DocumentPreviewContent.swift"), /hasToggles\(in: \$0.tipTapJSON\).*toggle-icon-presentation-v1/);
  assert.doesNotMatch(await read("VellixEditor.bundle/tiptap.html"), /penned-preview-toggle-icon/);
});
