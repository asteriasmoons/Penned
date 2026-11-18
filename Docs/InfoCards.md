# Collapsible InfoCards

Tap the title, description, or body text, then use **Information Card
Settings** left of **Bold** to open the sheet. The sheet's **Dismiss Keyboard**
action keeps it open.

Enable **Collapsible** in Information Card Settings on iPhone or iPad. A button
appears in the card's top-right corner. It uses the existing `chevup` asset when
expanded and `chevdown` when collapsed. The button uses the card's **Title Color**.

The title and description stay visible unless their independent hide options
are enabled. Collapsing hides the existing body,
including the divider below the description, without removing any blocks or
task data. New and existing cards have the option off by default. Turning it off
reopens the body. Both the option and the disclosure state are stored with the
card in TipTap JSON. Static HTML and PDF/image exports keep the complete body
visible, without the editor's disclosure control.

The native settings sheet uses the existing `informationCardSetAttr` bridge.
The TipTap node view handles disclosure without opening the settings or forcing
focus. If the caret becomes hidden, it moves to visible card content or a visible
header; when the entire collapsible card is hidden, the card itself is targeted.
Keyboard navigation into a hidden body reopens it.

## Independent Visibility Options

The existing settings sheet now includes **Hide Title**, **Hide Description**,
and **Hide Divider**. These use the persisted InfoCard attributes `hideTitle`,
`hideDescription`, and `hideDivider`, all defaulting to `false`. They are
independent: hiding the description does not implicitly change the divider.

Title and description nodes remain in the document with their text and marks.
Showing them again restores their existing content. The divider toggle removes
the actual body `border-top`, not an overlay. Layout closes the unused header
spacing while retaining room for a collapsible card's disclosure control.
Native immediate/gallery fallback previews also omit hidden headings. No cache
keys, cache pruning, PNG persistence, database schema, or sync protocol changed.

The schema, HTML parsing/serialization, node-view attributes, native settings
payload, and sheet controls share the same flags. The editor source changes are
in `penned-editor/src/information-card.js` and `src/tiptap.html`. The generated
editor bundle must be rebuilt/synchronized to activate these web changes; this
was not run because builds and tests were prohibited. Older editor bundles do
not understand the new controls. No build, test, or device verification was run.

The browser regression in `penned-editor/tests/information-card-browser.mjs`
exercises the shipped bundle at phone and tablet widths. Native settings-sheet
interaction and physical-device touch behavior still require an iOS check.
