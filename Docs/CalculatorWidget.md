# Calculator Document Widget

## Entry Points and Scope

Insert through **Add Block > Widgets > Calculator** or the slash menu's
**Calculator** entry. This is an atomic, selectable `calculator` document block,
not a separate application screen or a picture of a calculator.

The implementation extends the existing Mood Bar/Countdown infrastructure. No
database migration, new data layer, editor lifecycle replacement, drag-selection
rewrite, preview-cache change, or document-opening change is included.

## Calculation Behavior

The real keypad supports digits, decimal entry, addition, subtraction,
multiplication, division, percentage, positive/negative, AC, backspace, equals,
and result copying. The display shows the current calculation and result.

- Arithmetic uses Penned's existing bundled `fast-formula-parser` `1.0.19`.
  There is no `eval`, dynamic code generation, new arithmetic parser, remote
  calculation service, or calculator-specific dependency install.
- This is a basic pocket-calculator interaction: entering another operator
  completes a pending binary operation from left to right. It is not a typed
  scientific-expression editor with parentheses or operator-precedence input.
- A repeated operator replaces the pending operator. Repeated equals reuses
  the last operation and operand. Digits after equals start a new calculation;
  operators after equals continue from the result.
- Percentage divides the current entry by 100. For a pending addition or
  subtraction it uses the left operand as the percentage base, so `200 + 10 % =`
  produces `220`, and `200 * 10 % =` produces `20`.
- Decimal entry prevents duplicate decimal points and retains a trailing decimal
  while entering a number. Entry is bounded to 15 significant input digits;
  arithmetic results are displayed at up to 15 significant digits to avoid
  exposing ordinary binary-floating-point tails such as `0.30000000000000004`.
  This remains a JavaScript-number calculator, not an arbitrary-precision or
  financial-accounting engine.
- Division by zero, nonfinite results, and unavailable/failed arithmetic produce
  an explicit error display. AC, backspace from an error, or a new numeric entry
  can recover. Errors are not copied as numeric results.
- Copy uses the existing platform pasteboard APIs; it does not request document
  editing focus or route a paste action through WebKit.

Each block independently stores the entry, accumulator, pending operation,
waiting/evaluated state, calculation display, result, error code, and repeated-
equals operand/operation. Copying a block starts the new instance with the copied
state; subsequent interactions update only the instance's persistent block ID.

## Customization

Every persistent colored element has its own setting:

| Element | Independent Colors |
| --- | --- |
| Widget | Background, border |
| Display | Background, border, calculation text, result text |
| Number buttons | Background, border, text |
| Operator buttons | Background, border, text |
| Function buttons | Background, border, text |
| Equals button | Background, border, text |
| Copy button | Background, border, icon |

Widget and display border thickness/corner radius are configurable, as are
border thickness/corner radius for each of the four keypad categories. The
display and buttons have independent font family and weight settings. Result,
calculation, and button text have separate size settings.

The font controls reuse `HeadingLabelDropdown` and the existing
`DocumentFontStyle` choices: System, Serif, Monospaced, Rounded, and Hachi Maru Pop.
The shared dropdown was made module-visible without changing existing Label
behavior. Colors reuse the existing SwiftUI ColorPicker, Penned sheet field
styling, and project hex conversion helpers. No new font catalog or font assets
were introduced.

Full and half widths reuse existing document-widget grouping, including mixed
half-width Mood Bar/Countdown/Calculator pairs. The current
[Shared Document Widget Layout](WidgetLayoutSystem.md) gives both widths the
same 192-point outer height as other widgets, a 40-point display, and five rows
that share the remaining space. Four fixed keypad columns retain their layout
as text changes. Text fits the actual container; requested font settings remain
stored, with rendered sizes constrained by the available key/display space.

## Native Settings and Live Preview

Long-press the widget for approximately 550 ms, or select the block and use the
existing `settingswavy` action beside Style. The existing mixed-selection rules
remain unchanged. No visible settings button or new block-selection gesture was
introduced.

The shared widget settings binder now accepts an optional short-activation
callback for the Calculator. Mood Bar and Countdown do not supply it and retain
their prior behavior. It still prevents editor-focus defaults and owns the
long-press customization request. Calculator key presses are short, completed
contacts; a moved, cancelled, consumed selection, or held contact is not executed
as a key press. Touch activation consumes the finished event and suppresses its
compatibility click to prevent duplicate digits. Mouse/keyboard/accessibility
button clicks use the same action path. Long-press release cannot enter a number
or insert a paragraph.

The noneditable node view stops ordinary widget interaction events from entering
ProseMirror while allowing drag/drop passthrough. Existing selection-mode CSS
disables widget controls so they do not compete with whole-block selection. The
global selection engine, range calculations, scrolling and reorder recognizers
were not changed.

The settings sheet includes the existing keyboard-dismiss button, Done, Close,
and an interactive live preview. Its preview calls the same JavaScript
`PennedCalculator.press` function with a local state object. It does not duplicate
arithmetic in Swift or dispatch document transactions while previewing. Preview
calculations/copies are interactive; their calculation state is intentionally
local to the sheet and does not replace the document's live calculation on Done.

Appearance edits remain a native draft until Done; Close discards them. Saving
validates the owning editor/request, loaded document generation, block ID, and
original settings. It updates settings only, preserves the current calculation
state, retrieves a canonical document snapshot, and persists through the existing
`saveCurrentContent` path. Stale/conflicting settings are reported rather than
silently overwriting another edit.

## Sound and Haptics

Both are **disabled by default**, independently per Calculator.

- The sound picker offers Soft Click, Pop, Tick, and Chime, with a dedicated
  preview button on every choice. Selecting a sound also previews it explicitly,
  even if document button sounds are currently disabled.
- Volume is adjustable from 0 to 100 percent and applies to previews and actual
  key presses. At zero, playback is skipped.
- Short PCM sound data is generated locally with distinct envelopes/frequencies
  and played using `AVAudioPlayer`. Cached players/data are reused; no network,
  microphone, Photos/Files permission, external sound file, or startup audio
  preparation is needed.
- On iOS the default solo-ambient session can be changed to ambient for these
  effects, allowing other audio and honoring Silent Mode. An existing playback
  or recording session policy is not replaced. The system's audio route, volume,
  and current shared session category still affect audibility.
- iPhone haptics use a retained light `UIImpactFeedbackGenerator`, independently
  of audio. Device/system haptic settings and hardware availability still apply.
  No unsupported macOS vibration is simulated.
- Native feedback requests are accepted only for an active, ready, editable
  editor outside block-selection mode. Disabled sound/haptics do not generate
  per-key native feedback messages. Copy still sends its bounded numeric result
  to native pasteboard handling.
- Playback failures do not fail the calculation or set a document bridge error.
  They emit a content-free **`[Penned Calculator]`** error with domain/code.

## Persistence, Undo, and Performance

Each actual calculation change is a block-attribute transaction, using the
existing document JSON, undo/redo, autosave and synchronization machinery.
`closeHistory` makes keypad operations individually undoable instead of merging
an entire sequence into one typing event. Settings are a separate guarded
transaction. No per-key synchronous database save or full-document bridge
snapshot is requested by the Calculator; normal update debouncing remains in
place. Settings Done explicitly saves the returned snapshot like other sheets.

Regular calculation changes update only the expression and result text in the
node view. They retain the keypad DOM and copy icon. Appearance changes rebuild
only this widget. Resize observation fits text, with no polling loop, timer-based
calculation, or whole-document scan per key. Destruction removes the settings
binder, resize observer and local touch listeners.

The block's existing identity and atomic schema enable whole-block selection,
deletion, copy/paste, nested movement, and grouping. HTML clipboard serialization
includes both canonical settings and calculation state. There are no custom
attachment files to remap. Older application versions lacking the new Calculator
schema should not edit documents containing it.

## Preview Coverage

- The live editor and WebKit-generated document/PNG previews use the same bundled
  Calculator node/HTML rendering, including saved calculation state and colors.
- Immediate document-body and template-gallery previews render the native
  Calculator preview at its selected size.
- Miniature/nested-page previews resolve the same native view as a bounded Canvas
  symbol rather than substituting a generic empty block.
- Native half-widget grouping and miniature layout now recognize Calculator.
- The loader inlines the new script before editor initialization. Future bundle
  builds copy it through the existing resource list. The source and shipping
  JavaScript/HTML integration were synchronized without running a build.
- No PNG cache key, persistence, pruning, generation scheduling, old-preview
  retention, document opening/readiness, or preview-renderer lifecycle changed.

## Changed Files

| File | Purpose |
| --- | --- |
| `penned-editor/src/calculator-widget.js` | Validated settings/state, existing-parser arithmetic, keypad, styling, nonediting interactions, guarded settings command, saved HTML. |
| `penned-editor/src/document-widgets.js` | Optional short-activation callback; existing widget behavior unchanged without it. |
| `penned-editor/src/editor.js` | Register Calculator, slash item, IDs, selection settings, nonfocusing insertion, save command. |
| `penned-editor/src/tiptap.html` | Load Calculator before the main editor. |
| `penned-editor/esbuild.mjs` | Include Calculator in future static resource copying. |
| `Vellix/Editor/CalculatorSettings.swift` | Native settings/state, local-draft customization, shared font/color controls, interactive/static previews. |
| `Vellix/Editor/CalculatorButtonFeedback.swift` | Sound choices/previews, bounded local sound synthesis, cached playback, haptics, result copying. |
| `Vellix/Editor/HeadingLabelSettings.swift` | Make the existing dropdown reusable; no visual or behavioral change to Labels. |
| `Vellix/Editor/MoodBarSettings.swift` | Extend the shared half-widget classifier to Calculator only. |
| `Vellix/Editor/TipTapBridgeTypes.swift` | Typed Calculator settings/action bridge messages and selection-toolbar title. |
| `Vellix/Editor/TipTapEditorSession.swift` | Active-editor settings/action guards, preview calculation bridge, generation-checked commit, model saving and sheet cleanup. |
| `Vellix/Editor/DocumentEditorView.swift` | Widgets menu item, native sheet, active-document save guard and sheet keyboard ownership. |
| `Vellix/Editor/TipTapWebView.swift` | Inline the Calculator resource with the existing dependencies. |
| `Vellix/Documents/ImmediateDocumentPreview.swift` | Native document preview. |
| `Vellix/Templates/GalleryDocumentPreview.swift` | Template-gallery preview. |
| `Vellix/Editor/DocumentThumbnailLayout.swift` | Calculator shape/size and shared half-widget placement. |
| `Vellix/Editor/NestedPageThumbnail.swift` | Render the saved Calculator in miniature/nested-page Canvas previews. |
| `Vellix/VellixEditor.bundle/calculator-widget.js` | Shipping copy of the Calculator resource. |
| `Vellix/VellixEditor.bundle/document-widgets.js` | Shipping copy of the updated shared binder. |
| `Vellix/VellixEditor.bundle/tiptap.bundle.js` | Narrow corresponding registration/menu/settings/insertion integrations. |
| `Vellix/VellixEditor.bundle/tiptap.html` | Shipping script loading order. |
| `Docs/CalculatorWidget.md` | Feature behavior, architecture, limits and file inventory. |

## Verification Limits

Only source inspection, reference/diff checks and source/shipping resource
comparisons were performed. No builds, tests, compilation checks, simulators,
browser/app launches, audio playback, or physical-device runs were performed.

The implementation still needs device confirmation for arithmetic sequences and
error recovery, repeated equals, rapid taps without duplicate digits, copying,
long-press without focus/paragraph insertion, existing swipe/range selection,
deletion/undo/redo, reopen/sync, all typography/size combinations, all preview
paths, actual sound previews/volume/Silent Mode, and haptic availability. No
runtime behavior is claimed as verified from source inspection alone.

## API References

- [Existing formula parser and usage](https://github.com/LesterLyu/fast-formula-parser).
- [FormulaParser.parse API](https://lesterlyu.github.io/fast-formula-parser/FormulaParser.html).
- [Apple AVAudioPlayer](https://developer.apple.com/documentation/avfaudio/avaudioplayer).
- [Apple AVAudioPlayer volume](https://developer.apple.com/documentation/avfaudio/avaudioplayer/volume).
- [Apple prepareToPlay](https://developer.apple.com/documentation/avfaudio/avaudioplayer/preparetoplay()).
