# Template Authoring and Document Filling

## Template Gallery Actions

The gallery presents regular users' personal templates only under My Templates.
Unsorted, category creation, publishing, and long-press category moves are
reserved for the existing publisher account, with management restricted to
template-authoring contexts.
Public templates have a Save Template context action that creates an independent
personal template, not an ordinary document. Saving an existing template is also
available from the ordinary document's gallery without enabling authoring tools.
See [TemplateGalleryUsability.md](TemplateGalleryUsability.md) for the changed
files, persistence and ownership integration, and unrun verification checklist.
See [TemplateGalleryPermissions.md](TemplateGalleryPermissions.md) for the
publisher-only category policy and corrected private-template defaults.

## Selected Placeholder Deletion

Selected placeholders can be deleted or cut without enabling Placeholder Mode,
including through block selection and Select All. Only editing or overwriting
their guidance is restricted while that mode is off. The earlier blanket
deletion restriction has been corrected. See
[PlaceholderDeletion.md](PlaceholderDeletion.md) for the implementation, changed
files, history behavior, and unrun regression coverage.

## Latest Selection Correction

Selection is not editing permission. The placeholder caret guard now applies
only to collapsed insertion carets, not highlighted text ranges. Its blanket
click interception has been removed. Node selection and Select All remain
available. The transaction guard protects surviving placeholder contents while
allowing deliberate selected removals as described above.
See [TemplateSelectionFix.md](TemplateSelectionFix.md) for the confirmed source
cause, changed files, regression coverage, and pending bundle/device verification.

## Latest Change Record

Date: 2026-11-01

Request: template editing must use the original editor's caret, typing, selection,
and block-insertion behavior, with only actual placeholders protected while
Placeholder Mode is off.

Source changes:

- Removed automatic fallback paragraphs and the page-wide search for another
  typing position from placeholder protection.
- Restored the original blank-space insertion and document serialization paths.
- Scoped the empty-paragraph reuse exception to currently locked placeholders.
  Ordinary documents and active placeholder authoring retain their original behavior.
- Kept placeholder overwrites and collapsed insertion carets inside guidance
  blocked. Nonempty selections, normal clicks, and selected deletion are allowed.
  Newly locked guidance cannot retain an internal editing caret.
- Kept regular-document/template permission separation and template duplication
  behavior unchanged.

Files touched by this correction:

- `../penned-editor/src/structured-placeholders.js`: local placeholder protection,
  removal of automatic insertion/redirection, and original serialization restored.
- `../penned-editor/src/caret-slots.js`: original insertion helper restored with
  a permission check only when reusing a locked placeholder paragraph.
- `../penned-editor/src/editor.js`: removes the temporary fallback-helper wiring.
- `../penned-editor/tests/structured-placeholders.test.js`: updates regression
  coverage for ordinary caret behavior, protected guidance, and document filling.
- `Docs/TemplateAuthoring.md`: records this correction and its verification limits.

Status: source changes implemented; runtime behavior is not verified. No builds,
tests, simulators, launches, or linters were run. Regression tests remain unrun.
The shared editor bundle must be regenerated before these source changes reach
the installed application; see Verification Boundary below.

## Intended Behavior

Template creation and editing belong exclusively to Templates. Ordinary
documents are for writing and using completed templates, not authoring them.
Both contexts continue using the existing shared editor.

| Context | Placeholder Mode | Placeholder behavior |
| --- | --- | --- |
| Ordinary document | Not available | Existing placeholder-filling behavior remains available. |
| Template editor, mode off | Available but disabled | Guidance is protected from overwrites and caret placement; selected blocks may be deleted or cut. |
| Template editor, mode on | Enabled | Existing guidance-authoring tools can edit placeholder content and configuration. |

Use Template creates an independent ordinary document. It does not turn on
template-authoring permissions or modify the original template.

## Editor Context

The editor context comes from the saved document record: `templateID != nil`
enables template authoring, and `templateID == nil` means ordinary document
editing. `templateOriginID` records where a copy came from; it never grants
authoring permissions. The native adapters configure document and template IDs
before loading content and replay the same context after WebView recovery.
Loading a different document without a matching context defaults to ordinary
editing. The shared JavaScript bridge rejects a bare authoring-mode toggle that
does not supply a template identity.

Regular documents have no Template Mode, Placeholder Mode, guidance conversion,
template-component authoring, or Save as Template controls. Creating and editing
templates remains on Templates. Use Template retains the existing independent
tree/asset copying pipeline and produces ordinary documents with fillable
placeholders, formatting, and nested pages intact.
The regular editor's template picker can use existing templates and save public
templates to the personal gallery; category management and publishing controls
require publisher eligibility as well as a template-authoring context. Switching
documents also clears pending guidance-conversion and component-authoring sheets.

## Legacy Template Mode Documents

Older personal templates may reference an ordinary document directly. Opening
one for editing from Templates now copies its tree and assets into an actual
template-owned document tree, then updates that template's root reference in the
same database transaction. The template ID and category remain unchanged. The
original document and its children are not moved or converted into templates.
The conversion happens on template edit, not by adding startup migration work.

## Placeholder Protection

In template authoring with Placeholder Mode off:

- Placeholder nodes are rendered non-editable.
- Ordinary caret placement, typing, selection, and blank-space insertion use the
  original shared editor paths. Protection does not create paragraphs, search the
  page for a different typing position, or change ordinary-document caret behavior.
- Normal selection clicks are not consumed by placeholder protection. Nonempty
  text ranges, node selections, and Select All remain available. A collapsed
  insertion caret entering guidance retains the previous valid ordinary selection.
  If guidance is newly locked
  while its caret is inside, the guidance receives a block selection instead of
  retaining an editing caret. Normal taps elsewhere remain available.
- Selected placeholder blocks may be deleted or cut, including within larger
  selections or Select All. Block removal does not require Placeholder Mode.
- Transaction validation prevents typing, paste, formatting, and partial
  internal edits from changing surviving guidance or its configuration.
- Established whole-document block commands remain allowed when each protected
  node survives unchanged with its identity intact. Surrounding text stays editable.
- Guidance conversion/clearing requires Placeholder Mode to be enabled. Existing
  history can undo and redo selected block removals; changing the contents of a
  surviving protected placeholder still requires Placeholder Mode.

Placeholder Mode projects guidance for editing using the existing metadata
representation and history. Disabling it canonicalizes that projection and locks
the region immediately. Native document loading and internal projection updates
have explicit transaction markers; ordinary input does not receive those markers.
The protection index uses the existing incremental-node helpers and does not scan
all ordinary textblocks for each keystroke.

Ordinary documents are not subject to this authoring lock. Typing an answer into
a copied placeholder preserves its guidance metadata and does not enable
template-authoring tools.

## Template Caret Regression Fix

The automatic fallback paragraphs and page-wide caret redirection added during
the initial correction have been removed. Template editing is not a separate
caret or input system. Its only additional restriction is that actual placeholder
regions cannot be edited while Placeholder Mode is off.

The original blank-space insertion helper now checks the placeholder extension's
local protection permission before reusing an empty paragraph. Only a locked
placeholder is excluded. Ordinary paragraphs, active guidance authoring, and
ordinary-document placeholder filling keep their original reuse behavior.
Nothing is inserted automatically by placeholder protection, and the existing
document serialization path is unchanged.

Native document loading, WebView ownership, and stored placeholder metadata are
not changed by this correction.

## Manual Acceptance Checks

These checks are provided for device verification; they have not been run.

1. Open an ordinary document, including one previously created from a template.
   Confirm Template Mode, Placeholder Mode, guidance conversion, Save as Template,
   and template-component authoring are absent. Existing writing controls remain.
2. Open Use Template from an ordinary document. Confirm search, previews, and
   duplication work, without category-management or publishing controls.
3. Create or edit a template from Templates with Placeholder Mode off. Tap and
   navigate through guidance, including a template containing only placeholders.
   Confirm no text caret remains inside protected guidance.
4. Delete or cut selected placeholder blocks with Placeholder Mode off, including
   mixed selections and Select All. Confirm removal works and undo/redo restores
   the correct content. Separately attempt typing, paste, and formatting over
   guidance; surviving placeholders must retain their content and configuration.
5. Enable Placeholder Mode, edit guidance, and disable it while the caret is
   inside. Confirm protection returns immediately. Re-enable the mode and confirm
   the guidance remains editable.
6. Use the template. Confirm the copy retains formatting, guidance, nested pages,
   and attachments; fill its placeholders without authoring controls. Confirm the
   source template remains unchanged after editing the copy.
7. Edit a legacy template linked to an ordinary document. Confirm an independent
   template-owned tree is used, with the original document and children unchanged
   and the existing template identity and category preserved.
8. Save and reopen both contexts on iPhone, iPad, and macOS. Confirm context,
   normal editing, selection, undo/redo, and existing document opening still work.
9. Open a blank template with Placeholder Mode off. Confirm tapping and typing
   behave like the ordinary editor, without automatically inserted blocks.
   In a template containing guidance, tap normal text and blank space above,
   between, and below blocks. Confirm the original caret/insertion behavior works,
   locked guidance stays unchanged, and protection does not move the caret to a
   different ordinary block. Confirm enabling Placeholder Mode permits guidance
   editing and ordinary-document copies retain their original filling behavior.
10. Highlight text with range endpoints in guidance, move selection handles, use
    Select All, and swipe-select blocks. Confirm selections are not collapsed or
    canceled. Selected deletion is permitted; ordinary overwrites remain blocked.

## Files Changed

- `Vellix/Editor/DocumentEditorView.swift`: removes regular-document authoring
  controls and restricts guidance actions to enabled Placeholder Mode.
- `PennedMac/Editor/MacDocumentEditorContainer.swift`: same toolbar separation.
- `Vellix/Templates/TemplateGalleryView.swift`: keeps the ordinary-document
  picker use-only while retaining management for template authoring.
- `Vellix/Editor/TipTapEditorSession.swift` and
  `PennedMac/Editor/MacTipTapEditorSession.swift`: configure authoritative record
  context, replay it on recovery, and gate authoring commands/requests.
- `Vellix/App/AppEnvironment.swift`: removes regular-document Template Mode and
  Save as Template entry points and centralizes template-editor preparation.
- `Vellix/Documents/DocumentRepositories.swift`: isolates legacy linked template
  roots on edit using existing tree/asset cloning and transaction cleanup.
- `PennedMac/Settings/MacSettingsPanes.swift` and
  `PennedMac/Browser/MacDocumentBrowser.swift`: open templates through that
  preparation path, including existing context-menu entry points.
- `PennedMac/Inspector/MacInfoInspector.swift` and
  `PennedMac/Workspace/MacWorkspaceCommands.swift`: remove Save as Template from
  ordinary-document interfaces.
- `../penned-editor/src/structured-placeholders.js`: transaction-level protection,
  caret guards, incremental indexing, and explicit context validation.
- `../penned-editor/src/editor.js`: marks native content-loading transactions
  explicitly and passes normal block-selection support to placeholder protection.
- `../penned-editor/src/caret-slots.js`: retains the original insertion path and
  excludes only currently protected placeholders from blank-paragraph reuse;
  ordinary-document behavior and column bookmarks are unchanged.
- `../penned-editor/src/template-components.js`: uses the same explicit template
  identity before enabling authoring behavior.
- `../penned-editor/tests/structured-placeholders.test.js`: context, cross-region
  editing, caret navigation, mode transition, formatting, and filling regressions.
- `../penned-editor/tests/template-components.test.js`, `formatting-state.test.js`,
  `callout-runtime.test.js`, and `attachments.test.js`: supply explicit template
  identities in existing authoring fixtures.
- `Vellix/VellixTests/VellixTests.swift`: ordinary-context and legacy-template
  isolation/duplication regression coverage.
- `Docs/TemplateAuthoring.md`: implementation and compatibility notes.

## Verification Boundary

No builds, tests, simulators, launches, or linters were run. Regression tests were
added/updated but remain unrun. Generated JavaScript bundles were not hand-edited.
Regenerate the shared editor bundle with `npm run build` in
`/Users/asteriasmoons/Desktop/penned-editor` before building Penned. The existing
`VellixEditor.bundle` copy step is part of that command. No database reset or
schema migration is required.
