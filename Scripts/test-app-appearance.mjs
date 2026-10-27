import { readFile, readdir } from "node:fs/promises";
import { createHash } from "node:crypto";
import assert from "node:assert/strict";
import test from "node:test";

const root = new URL("../Vellix/", import.meta.url);
const read = file => readFile(new URL(file, root), "utf8");

test("one persisted appearance preference reaches the app presentation boundary without changing workspace identity", async () => {
  const app = await read("VellixApp.swift"), source = await read("Resources/PennedAppearance.swift");
  assert.match(app, /\.pennedApplicationAppearance\(\)/);
  assert.match(source, /case light, dark, system/);
  assert.match(source, /static let defaultValue: Self = \.dark/);
  assert.match(source, /@AppStorage\(PennedAppearancePreference.storageKey\)/);
  assert.match(source, /content.preferredColorScheme\(preference.colorScheme\)/);
  assert.match(source, /case \.system: return nil/);
  assert.doesNotMatch(app, /\.id\([^\n]*[Aa]ppearance/);
  const project = await readFile(new URL("../Vellix.xcodeproj/project.pbxproj", root), "utf8");
  assert.doesNotMatch(project, /UIUserInterfaceStyle = Dark/);
});

test("iPhone and iPad Settings use the same selection page and storage", async () => {
  assert.match(await read("Spaces/PennedSettingsView.swift"), /case \.appearance: PennedAppearanceSettingsView\(\)/);
  assert.match(await read("App/PadSettingsView.swift"), /case \.appearance: PennedAppearanceSettingsView\(\)/);
  const page = await read("Spaces/PennedAppearanceSettingsView.swift");
  assert.match(page, /@AppStorage\(PennedAppearancePreference.storageKey\)/);
  assert.match(page, /preference = option/);
  assert.match(page, /\.isSelected/);
  assert.match(page, /LibraryIcon\(name: "checkwavy"/);
});

test("no application presentation overrides the selected appearance with a forced dark scheme", async () => {
  async function walk(url) {
    for (const entry of await readdir(url, { withFileTypes: true })) {
      if (entry.name.includes("Tests") || entry.name.endsWith(".bundle") || entry.name.endsWith(".xcassets")) continue;
      const next = new URL(entry.name + (entry.isDirectory() ? "/" : ""), url);
      if (entry.isDirectory()) await walk(next);
      else if (entry.name.endsWith(".swift")) {
        const source = await readFile(next, "utf8");
        assert.doesNotMatch(source, /preferredColorScheme\(\.dark\)|overrideUserInterfaceStyle = \.dark|environment\(\\\.colorScheme, \.dark\)/, next.pathname);
      }
    }
  }
  await walk(root);
});

test("native WebView hosting and workspace lifecycle code remain byte-for-byte unchanged", async () => {
  for (const [file, hash] of Object.entries({
    "Editor/TipTapWebView.swift": "afe44d39157d7ac814f6b270e4ae39934cfec0d2071f3a35ff28f03a62b5cb8c",
    "Editor/DocumentEditorCache.swift": "2c7a63fd0c81e6675fa0e56e56b4424d277b3b14b6194e0cae532a81cdccb16e",
    "App/PadWorkspaceModel.swift": "0271ec48639984adfc6ee36b6932d754c8c07f1d7c145a9a05207e4362b69937",
    "App/PadWorkspaceView.swift": "b38f331dc5969a31112ef86ac1ab5efdfc8b81f604b474d401eb9d00b0b1d564",
  })) assert.equal(createHash("sha256").update(await read(file)).digest("hex"), hash, file);
});

test("live editor theme changes use the existing appearance bridge, never saved styling or content loading", async () => {
  const source = await read("Editor/DocumentEditorView.swift");
  assert.match(source, /\.onChange\(of: colorScheme\) \{ _, scheme in model.session.setApplicationColorScheme\(scheme\) \}/);
  assert.match(source, /let appearance = localAppearance.resolved\(for: colorScheme\)/);
  assert.doesNotMatch(source, /localAppearance = .*resolved|updateAppearance\([^\n]*resolved|selectedCalloutColor = VellixSurface/);
  const session = await read("Editor/TipTapEditorSession.swift");
  const update = session.slice(session.indexOf("func setApplicationColorScheme"), session.indexOf("func setPageReferences"));
  assert.match(update, /setAppearance\(currentAppearance\)/);
  assert.doesNotMatch(update, /load\(|resetPresentation|save\(|prepare\(document|flushPendingSave/);
});

test("theme-aware preview keys reach both fallback and WebKit rendering without changing gallery dimensions", async () => {
  const preview = await read("Documents/LibraryDocumentPreview.swift");
  assert.match(preview, /cacheKey\(for: colorScheme\)/);
  assert.match(preview, /presentationImage\(for: current, colorScheme: colorScheme\)/);
  assert.match(preview, /image\(for: current, colorScheme: colorScheme\)/);
  assert.match(preview, /environment\(\\\.colorScheme, colorScheme\)/);
  const key = await read("Documents/DocumentPreviewContent.swift");
  assert.match(key, /appearance.isThemeDependent/);
  assert.match(key, /-appearance-light-v1/);
  assert.match(key, /-appearance-dark-v1/);
});
