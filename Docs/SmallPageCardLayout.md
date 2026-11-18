# Small Page Cards Side by Side

## Cause

Small page cards already rendered their button at the configured card width, but their outer `pageReference` node remained a full-width block. Each card therefore started a new row even when two card images could fit side by side.

These are nested-page cards, not collection-gallery cards. The collection property-preview sizing change is unrelated and remains intact.

## Change

- The page-reference node marks only non-full-width cards for inline layout and exposes their existing saved card width to CSS.
- Small cards use width-constrained, top-aligned inline-block wrappers. Adjacent cards share a row when they fit and naturally wrap when they do not.
- Horizontal spacing is capped at 12 pixels and reduces when needed to fit two cards without shrinking their configured width. A single oversized card remains constrained to its container.
- Wide and Large cards remain full-width. Ordinary nested-page rows keep their existing layout.
- Cards remain independent editor nodes. No document/schema reconstruction, automatic reparenting, selection changes, or content deletion is introduced. Existing explicit paragraphs and other blocks still separate rows.
- Card artwork, dimensions, photo credits, opening, long-press actions, swipe selection, saving, and undo/redo code are unchanged.

## Files Changed

- `penned-editor/src/page-reference-node.js`: exposes the small-card layout class and existing card width; both update when card style changes.
- `penned-editor/src/tiptap.html`: adds the inline wrapping layout for small page cards only.
- `Docs/SmallPageCardLayout.md`: records the cause, scope, and required bundle update.

## Bundle and Validation

No builds, tests, simulators, launches, or automated verification commands were run, as requested.

**Run `npm run build` in `/Users/asteriasmoons/Desktop/penned-editor` before your next Xcode app build.** This change includes JavaScript, so the existing build/sync workflow must regenerate `VellixEditor.bundle`. The compiled bundle was not manually edited or rebuilt.

On-device checks remain: two adjacent Small Portrait or Small Landscape cards should share a row when space permits, wrap on narrower surfaces, and retain independent opening, selection, and style actions. Wide/Large cards and surrounding text should remain on separate document rows.

## Native Fallback and Deletion Correction

The earlier CSS change was incomplete. The native editor also rendered child pages absent from the current editor JSON in a separate fallback stack. Deleting a card block removed only its reference, leaving its child document active. That made the same card reappear in the native stack, which could center it. Cards split between the WebView and the native fallback could not share a row.

- On opening a document, existing legacy child pages without reference blocks are materialized as real page-reference blocks at the end of the saved body, where the fallback already displayed them. Trailing blank editing paragraphs are preserved after these cards rather than splitting the card row. Document-root attributes and placeholder guidance are preserved, archived/trashed documents are not migrated, and collection entries are excluded. Those cards then share the editor's existing small-card wrapping layout and normal selection/deletion path.
- Removing the last editor reference to an owned child now moves that child and its subtree to the existing Trash, rather than redrawing it below the editor. No files or documents are permanently deleted.
- Editor undo restores only the exact Trash batch created by this editor when its page reference returns. Redo removes it again. Moved/reparented children and unrelated documents are not trashed; independently deleted pages are not restored.
- The remaining native fallback uses a leading-aligned wrapping layout for small cards on iOS and Mac. Full-width cards and ordinary nested-page rows retain full-row placement.
- Reconciliation is skipped when page-reference IDs are unchanged; ordinary typing does not perform child Trash/restore queries.

Additional files changed:

- `Vellix/Editor/PageReferenceLifecycle.swift`: shared legacy materialization and guarded Trash/undo handling.
- `Vellix/Editor/TipTapEditorSession.swift` and `PennedMac/Editor/MacTipTapEditorSession.swift`: prepare real references before loading and reconcile removed/restored references with content updates.
- `Vellix/Editor/PageCardView.swift`: native small-card wrapping layout.
- `Vellix/Editor/DocumentEditorView.swift` and `PennedMac/Editor/MacDocumentEditorContainer.swift`: use that layout instead of stacking fallback cards.

No builds, tests, or automated verification commands were run for this correction. It requires your normal Xcode build. The earlier web layout still requires your `npm run build` if that source change has not yet been bundled. On-device checks remaining: open an affected document, delete one card, undo/redo, reopen, and confirm the remaining adjacent small cards share a row when space permits.

## CSS Cascade Correction

The earlier inline layout still lost to an existing, more-specific rule:

```css
.tiptap-editor [data-vellix-block-id] { width: 100%; } /* specificity 0-2-0 */
.vellix-page-card-inline { width: var(--vellix-page-card-width, 154px); } /* 0-1-0: loses */
```

That left every card's wrapper full-width even when `display: inline-block` applied. This is a confirmed conflict in the stylesheets, not a guessed WebKit defect. The callout row styles already avoid the problem by using editor-scoped selectors that override the generic block width.

The card rule now uses `.tiptap-editor .vellix-page-reference.vellix-page-card` (specificity 0-3-0). Its configured small-card width wins, so adjacent cards can occupy the same line. Wide/Large cards retain `width: 100%` through the existing button's explicit full-width presentation. Hidden references stay hidden. No global block widths, callout layouts, document structure, selection logic, or deletion behavior were changed in this correction.

The rule deliberately matches the existing shipped `.vellix-page-card` DOM, not only the newly added `.vellix-page-card-inline` marker. It therefore works with the already bundled JavaScript as well as a future source rebuild.

Files changed for this correction:

- `penned-editor/src/tiptap.html`: corrects card selector specificity and preserves full-width/hidden cases.
- `Vellix/VellixEditor.bundle/tiptap.html`: applies the same static CSS directly to the editor shipped by Xcode.
- `Docs/SmallPageCardLayout.md`: records the actual CSS conflict and superseding bundle instructions.

**This CSS correction does not require `npm run build`.** Both source and shipped HTML were updated without changing the compiled JavaScript. This supersedes the earlier requirement to bundle the new marker before the horizontal layout can work. Use your normal Xcode build. No builds, tests, app launches, or automated verification commands were run; on-device layout remains for you to check.

Reference: [MDN CSS specificity](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Cascade/Specificity), which documents why class and attribute selector weights determine which width declaration wins.

## Responsive Two-Card Sizing

Small cards now divide their containing row into two equal slots: `(available width - 12px gap) / 2`. Their button and image scale to the slot using the existing card aspect ratio, so both outer edges align with the document content instead of leaving the old fixed-width remainder on the right. Wide/Large cards remain full-width; an odd final small card keeps its half-row slot.

The node view marks alternating cards within each consecutive small-card run. Only the first card in each pair receives the horizontal gap, so the second card ends flush with the row's right edge. Adding/removing a card or intervening block resets the pairing. Normal paragraphs and other blocks still separate runs, and cards remain independent document nodes.

Presentation updates are coalesced into one animation-frame callback, without geometry reads, a document-wide MutationObserver, or changes to the editor's parent layout. Ordinary typing/formatting does not rebuild card pairing. Native fallback cards use matching half-width slots and proportional scaling without changing the saved card style or native card-image generation.

Files changed for responsive sizing:

- `penned-editor/src/page-reference-node.js`: coalesces row-pair presentation updates on card/style changes and block-structure edits.
- `penned-editor/src/tiptap.html`: half-width slots, one gap per pair, proportional button/image sizing, and consistent vertical alignment.
- `Vellix/Editor/PageCardView.swift`: responsive native fallback slots and opt-in proportional card scaling.
- `Vellix/Editor/DocumentEditorView.swift` and `PennedMac/Editor/MacDocumentEditorContainer.swift`: enable slot scaling only for fallback small cards.
- `Docs/SmallPageCardLayout.md`: records this sizing change.

**This responsive-sizing change includes JavaScript. Run your `npm run build` in `/Users/asteriasmoons/Desktop/penned-editor` to regenerate/sync the editor bundle before your Xcode build.** This supersedes the earlier CSS-only instruction for the new sizing behavior. No builds, tests, simulators, launches, or automated verification commands were run. The compiled bundle has intentionally not been manually edited.
