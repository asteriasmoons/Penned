import test from "node:test";
import assert from "node:assert/strict";
import { readFile, access } from "node:fs/promises";

const root = new URL("../../", import.meta.url);
test("publishing advanced controls use an existing Penned asset", async () => {
  const sheet = await readFile(new URL("Vellix/Publishing/PublishingSheet.swift", root), "utf8");
  assert.match(sheet, /option\("Advanced Options", "settingswavy"/);
  await access(new URL("Vellix/Assets.xcassets/settingswavy.imageset/Contents.json", root));
});
test("sheet blur reattachment does not depend on another appearance callback", async () => {
  const source = await readFile(new URL("Vellix/Resources/PennedSheetStyle.swift", root), "utf8");
  const callback = source.slice(source.indexOf("override func didMoveToWindow()"), source.indexOf("override func layoutSubviews()"));
  assert.match(callback, /if window == nil \{ endPresentation\(\) \}/);
  assert.match(callback, /isPresentationReady = true\s+updateBlur\(force: true\)/);
});
