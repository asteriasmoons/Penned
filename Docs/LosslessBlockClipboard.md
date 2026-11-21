# Lossless Block Copy/Paste (swipe-select + tap-paste) — Implementation Report

**Date:** 2026-11-19
**Project:** Penned — editor source (`~/Desktop/penned-editor`) + iOS app (`~/Desktop/Vellix`)
**Goal:** When you swipe-select across a block (e.g. an infoCard with a label, divider, and text) and tap **Paste**, the pasted block keeps all its nested content, settings, and styles — instead of degrading to plain text.
**Status:** Implemented. Editor round-trip verified lossless (automated, both closed and open selections). App builds (`** BUILD SUCCEEDED **`). **Needs your on-device test** (see §6). **Not committed to git.**

---

## 1. Root cause (proven, not guessed)

I reproduced your exact flow against the real editor bundle in a headless browser:

- **In a clean browser the editor's copy→paste is already perfect** — the serialized clipboard HTML carries `data-information-card`, every `data-ic-*` setting, and `data-pm-slice`; after paste the card is rebuilt with all settings and all children intact (card count 1→2, colors/padding/corner-radius preserved).
- **On iOS it degrades because WebKit's clipboard sanitizer strips those `data-*` attributes** when the HTML is read from the system pasteboard. With the attributes gone, the editor no longer recognizes the card and it collapses to plain paragraphs/text.

This is a WebKit-level issue, not an editor bug — which is exactly why Penned already had a **sanitizer-proof native pasteboard channel** (`im.lystaria.penned.blocks+json`), but only wired for *block-selection* copy. Your swipe-select + tap-paste used ProseMirror's normal HTML clipboard, which never touched that channel.

## 2. The fix (native clipboard route)

Extend that same sanitizer-proof channel to ordinary text-range copy/paste:

- **On copy**, when the selection contains a structured block, stash a **lossless ProseMirror slice** (`format: "penned-slice"`) on the native pasteboard alongside the normal HTML/text. WebKit never touches a private pasteboard type, so nothing is stripped.
- **On paste**, route the gesture to the native layer, which reconstructs the exact slice from that payload (fresh block IDs, dropped at your caret) when present, and otherwise re-issues an ordinary WebKit paste.

## 3. What changed (files)

**Editor — `penned-editor/src/editor.js`** (then rebuilt → synced into `Vellix/Vellix/VellixEditor.bundle/`):
- Added `editorProps.handleDOMEvents.copy` — for a selection containing a non-paragraph block, serializes the slice and posts it to the native layer as a `penned-slice` payload (plus normal HTML/text). **Plain inline/paragraph copies are left entirely to the browser — unchanged.**
- Added `editorProps.handleDOMEvents.paste` — routes editor pastes to the native layer (`editorSmartPaste`) with a one-shot guard so the native fallback's own WebKit paste passes straight through (no loop).
- Extended the existing `pastePennedBlocks` command to also reconstruct the `penned-slice` format via `Slice.fromJSON` + `replaceSelection`.

**App — `Vellix/Vellix/Editor/TipTapEditorSession.swift`:**
- In `handleRawMessage`, route `kind == "editorSmartPaste"` to the existing `paste()` method (which already reads the native pasteboard type and reconstructs losslessly, else falls back to a normal paste). One small addition; reuses the existing copy-write handler (`attachmentClipboard`) and the existing `paste()` logic.

## 4. Why this respects your constraints

- **Your selection system is untouched.** Copy only *reads* the selection; paste inserts at your existing caret. Both handlers early-return in block-selection mode (`selectionMode !== "off"`), so block selection/copy/paste is completely unchanged. Cut was intentionally left alone.
- **Targeted & fail-safe.** Copy is intercepted only when the selection actually contains a structured block; everything is wrapped in try/catch and falls back to normal browser behavior on any error. The paste interceptor degrades to a normal WebKit paste for non-Penned content.

## 5. Verification performed

- **Editor round-trip, closed (select-all) selection:** lossless — pasted card kept titleColor/backgroundColor/padding/cornerRadius and all children (title, description, body, label, paragraphs, divider); label's **bold** mark preserved.
- **Editor round-trip, open (swipe) selection (open depths 1/1):** lossless — same result.
- **App build:** `** BUILD SUCCEEDED **`, 0 errors.
- **Bundle:** rebuilt with `node esbuild.mjs && node scripts/sync-bundle.mjs`; the synced app bundle contains the new `penned-slice` / `editorSmartPaste` paths.

## 6. What still needs your test (on device / simulator)

The one thing I can't exercise off-device is the real iOS pasteboard + WebKit paste gesture. Please verify on your iPhone:
1. Swipe-select across an infoCard (label + divider + text), **Copy**, place the caret elsewhere, tap **Paste** → the whole card with all settings should appear.
2. Paste **plain text copied from another app** (Notes/Safari) → should paste normally as before.
3. Paste **an image/file** from the clipboard → should still import as before.

If #2 or #3 misbehaves, tell me and I'll adjust the fallback — the native paste path is designed to hand those straight back to the normal WebKit paste.

## 7. Backups / git

- Backups before editing: `penned-editor/.clipboard_fix_backup/editor.js.bak`, `Vellix/.clipboard_fix_backup/tiptap.bundle.js.bak`, `Vellix/.clipboard_fix_backup/TipTapEditorSession.swift.bak`.
- **Nothing committed to git** — left for your review.
