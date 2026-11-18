# Scripts

## `generate_icon_library.sh` — auto-generate the icon library

Regenerates `Vellix/Resources/VellixAssetIconLibrary.swift` from the **folder
structure** of `Vellix/Assets.xcassets`:

- Each **group folder** in the catalog becomes one `VellixAssetIconCategory`.
- Each `*.imageset` becomes one `VellixAssetIcon(name: "<id>")`.
- Imagesets left at the **catalog root** land in an `"Unsorted"` category (last).
- Icons are **alphabetical within a category** unless an order override exists (below).

It runs automatically as the **"Generate Icon Library"** Run Script build phase
(first phase, before Compile Sources). It is **idempotent**: it only rewrites the
Swift file when the output actually changes, so normal builds are cheap.

### Your workflow for adding / recategorizing icons

1. Drag the new `*.imageset` into the matching **category folder** inside
   `Vellix/Assets.xcassets` (or into the catalog root to park it in "Unsorted").
2. Build. The Swift file regenerates — **no Swift editing**.

To move an icon to a different category, just move its imageset to that category's
folder. To create a new category, make a new group folder and drop imagesets in it
(it appears after the known categories; add it to `ORDER` in the script to pin its
position).

### CRITICAL — namespace must stay OFF

The app references icons by **bare name** (`LibraryIcon(name: "couch")`,
`Image("couch")`), and stored model values are bare ids. The category group folders
are **organizational only**: their `Contents.json` must NOT contain
`"provides-namespace": true`. If namespace were ON, the runtime asset name would
become `"Rooms/couch"` and every icon reference + every saved icon id would break.
**Never enable "Provides Namespace" on a category folder.**

### Per-category order override (optional)

Alphabetical is the default. For a category whose order is meaningful, add
`Scripts/icon_category_order/<Category Name>.txt`, one icon id per line in the
desired order. Listed ids (that exist) come first in that order; any remaining
icons in the category follow alphabetically. Example already in place:
`Scripts/icon_category_order/Moon Phases.txt` keeps the lunar cycle
(new → waxing → full → waning) instead of alphabetical.

### SF Symbols are NOT handled here

`VellixAssetIconLibrary` is **custom assets only**. SF-symbol entries live in the
separate `VellixSymbolCatalog`; this script never touches them.

### Manual run / notes

- Run manually: `bash Scripts/generate_icon_library.sh`
- Written for macOS `/bin/bash` (3.2); `LC_ALL=C` keeps output byte-identical.
- The script lives at the **repo root** (outside the synchronized `Vellix` app
  folder) on purpose, so Xcode's file-system-synchronized groups don't bundle it as
  an app resource. The generated Swift file stays inside `Vellix/` (it's a source).
