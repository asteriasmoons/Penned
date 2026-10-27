import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = path => readFile(new URL("../" + path, import.meta.url), "utf8");

test("Mac Apple sign-in uses the full available width without the decorative purple outline", async () => {
    const source = await read("PennedMac/Accounts/MacSignInView.swift");
    const button = source.slice(source.indexOf("private var appleButton"), source.indexOf("@ViewBuilder private var emailFields"));
    assert.match(button, /MacAppleSignInButton/);
    assert.match(button, /frame\(maxWidth: \.infinity\)/);
    assert.doesNotMatch(button, /strokeBorder|stroke\(/);
    assert.match(button, /handleAppleSignIn\(result\)/);
    const native = await read("PennedMac/Accounts/MacAppleSignInButton.swift");
    assert.match(native, /ASAuthorizationAppleIDButton\(type: \.continue, style: \.black\)/);
    assert.match(native, /width: proposal\.width/);
    assert.match(native, /focusRingType = \.none/);
    assert.match(native, /parent\.onRequest\(request\)/);
    assert.match(native, /parent\.onCompletion\(\.success\(authorization\)\)/);
});

test("iPhone, iPad and Mac collection management exposes confirmed Delete Collection", async () => {
    for (const [path, confirmation] of [["Vellix/Collections/CollectionViewSheets.swift", "confirmationDialog"], ["PennedMac/Collections/MacCollectionViewSheets.swift", "macConfirmationDialog"]]) {
        const source = (await read(path)).split("struct CollectionAddViewSheet")[0];
        assert.match(source, /Text\("Delete Collection"\)/);
        assert.ok(source.includes(`.${confirmation}("Delete this collection?"`));
        assert.match(source, /Button\("Delete Collection", role: \.destructive\)/);
        assert.match(source, /CollectionDeletion\.delete\(collectionID, in: environment\)/);
        assert.match(source, /interactiveDismissDisabled\(isDeleting\)/);
        assert.match(source, /Entry documents will be kept as ordinary pages/);
    }
});

test("collection deletion drains pending edits and edits the existing live editor without recreating it", async () => {
    const source = await read("Vellix/Collections/CollectionDeletion.swift");
    assert.match(source, /prepareForWorkspaceNavigation\(\)/);
    assert.match(source, /beginPersistentOperation\(\)/);
    assert.match(source, /captureAndSave\(\)/);
    assert.match(source, /setMeta\('addToHistory', false\)/);
    assert.doesNotMatch(source, /WKWebView\(|detach\(|loadHTMLString/);
});
