# Smaller Four-Dot Divider

The existing `fourCircles` divider (including legacy `fourDots`) still displays
exactly four solid, centered dots in the document's text color. Dot diameter is
now 4px, replacing the initial 2.5px adjustment at the user's request. This
is 40% of the original 10px diameter. Native previews use matching 4pt dots.

The existing 18px/pt gap, divider height, vertical margins, insertion choices,
selection behavior, and stored divider style are unchanged. The continuous
dotted divider, thin/thick line dividers, and ordinary list bullets are unchanged.

## Files Changed

- `../penned-editor/src/tiptap.html`: changes only the four-dot circle width,
  height, and flex basis to 4px.
- `Vellix/VellixEditor.bundle/tiptap.html`: matching targeted change in the
  actual HTML resource used by Penned. No JavaScript bundle rebuild is required
  for this size change; the next native app build includes this resource.
- `Vellix/Documents/ImmediateDocumentPreview.swift`: matching dot size for
  immediate document previews.
- `Vellix/Templates/GalleryDocumentPreview.swift`: matching template previews.
- `Vellix/Editor/DocumentThumbnailLayout.swift`: reduces four-dot thumbnail
  symbols proportionally from 1.5 to 0.6 thumbnail units, retaining four dots
  and their pitch while centering the smaller group. Other thumbnail marks are
  unchanged.
- `Vellix/Editor/TipTapContentAnalyzer.swift`: detects the four-dot divider,
  including nested blocks and its legacy style name.
- `Vellix/Documents/DocumentPreviewContent.swift`: adds a four-dot-only renderer
  revision so affected cached previews refresh without invalidating unrelated
  previews or changing document data. The current revision is
  `four-dot-presentation-v3-4px`, replacing the cached 2.5px rendering.
- `Vellix/VellixTests/DocumentLaunchTests.swift`: detection regression cases
  covering nested four-dot dividers, legacy naming, and unaffected styles.
- `Docs/FourDotDividerSize.md`: this change record.

No editor JavaScript, list/caret behavior, template permissions, document
schemas, persistence, or unrelated UI was changed. Published website styling
is outside this editor/preview change and was left unchanged.

No builds, tests, linters, launches, simulators, or runtime verification commands
were run. The regression case is added but unexecuted; physical-device
appearance remains unverified.
