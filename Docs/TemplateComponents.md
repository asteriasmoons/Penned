# Template Components

## Compact Slider And Interaction Boundary

Rating, single-select, multi-select, and slider components share the existing TipTap `templateComponent` node view. Component controls, labels, output, endpoint labels, and empty component space belong to that node view, not document caret placement. Pointer/mouse down prevents text-host focus except on the native range input. Touch start/move remain passive so document scrolling can begin on components; only a completed stationary touch cancels native focus and activates the corresponding button. Moved, cancelled, multi-touch, and long-press contacts do not activate a choice. A compatibility click after touch activation cannot toggle a multi-select answer twice. Keyboard/assistive button activation remains available.

The range input retains native focus, keyboard adjustment, dragging, and input/change events. Response updates keep the same slider DOM node and preserve the document's existing selection. Editing and block-selection guards remain in force. The node view releases its event boundary during block selection and removes its local listeners on destruction. No global gesture recognizer, WebView ownership, host lifecycle, document schema, response format, or persistence changes are introduced.

An answered slider shows its current value in bold at the center of the endpoint row directly below the track, with minimum and maximum labels on either side. Unanswered sliders still hide the value. The old separate value row above the track and range margins are removed. Native fallback previews use the same lower centered-value arrangement. Existing colors, range bounds/step, choices, selected states, and template configuration behavior remain unchanged.

## Changed Files

- `../Vellix-backend/src/template-components.js`: component-local focus/tap boundary for all four types, full-surface ProseMirror event ownership, native range preservation, cleanup, and compact slider DOM.
- `../Vellix-backend/src/tiptap.html`: matching component selection CSS and slider/footer layout.
- `Vellix/VellixEditor.bundle/tiptap.html`: the same CSS in the resources actually loaded by the apps.
- `Vellix/VellixEditor.bundle/tiptap.bundle.js`: only the existing component factory is replaced mechanically from maintained source, with no bundler or compiler.
- `Vellix/Documents/ImmediateDocumentPreview.swift`: keeps native fallback preview value placement consistent with the live component.
- `Scripts/install-template-component-hooks.mjs`: syntax-checked AST replacement of that one factory, retaining the rest of the existing shipping artifact.
- `../Vellix-backend/tests/template-components.test.js`: existing persistence/configuration tests plus focus, selection, scroll, cancellation, compatibility-click, range, compact layout, and teardown regressions; supports testing the shipping runtime directly.
- `Scripts/test-component-browser.mjs`: isolated headless-browser rendering and interaction checks at phone, tablet, and desktop widths using the actual shipping resources and mobile adapters.
- `Docs/TemplateComponents.md`: behavior, file inventory, and verification boundary.

## Verification

Run against the actual shipping JavaScript without building:

```sh
PENNED_EDITOR_RUNTIME=/Users/asteriasmoons/Desktop/Vellix/Vellix/VellixEditor.bundle node --test tests/template-components.test.js
```

Run that command from `../Vellix-backend`. JavaScript DOM tests can verify event cancellation, focus/selection state, answer persistence, layout structure/CSS, and component teardown. They do not establish physical WKWebView behavior. No Swift compilation, application build, native app launch, or simulator is run; physical iPhone/iPad verification is still required for the keyboard, slider touch dragging, scroll momentum, VoiceOver, and component taps after ordinary editing.

The component suite passes 27 checks against the shipping artifact. The existing Calendar, text-color, tasks, mobile editing, block selection, gallery, Mac navigation/scrolling, and iPad workspace suites pass 184 checks. The Browser plugin is not available; `node Scripts/test-component-browser.mjs` uses isolated headless Chromium instead and checks the value's actual geometry/bold styling, once-only control responses without editor focus or caret changes, native range touch/drag and keyboard adjustment, scrolling initiated on components, and ordinary typing at 390, 834, and 1100 pixels. Screenshots are stored in `/tmp/vellix-component-layout` and the phone/tablet renders were visually inspected. These browser results are not physical iOS/iPadOS keyboard proof.
