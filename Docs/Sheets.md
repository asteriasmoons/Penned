# Universal Sheet Presentation

## Shared Components

`Resources/PennedSheetStyle.swift` owns the app's sheet styling. Apply
`pennedSheet(title:closeDisabled:close:actions:)` to a sheet's content. Pass the
existing cancellation closure to `close` and its commit/Edit/Back buttons to the
actions builder. Native toolbar buttons stay hidden. The custom `xmarkwavy`
close button and adjacent capsule actions sit at the top right in the sheet's
top safe-area inset, beside the title when space permits. On narrow layouts the
title moves below the controls, which remain at the top right.
Long action groups can scroll horizontally rather than overlap or separate the
close button onto another row. Content remains clear of these controls.

The Space switcher has a user-requested exception: its search field shares the
header with the custom close button, while Create Space stays in a bottom
safe-area inset. Other sheets' primary actions remain beside the close button.

The title is a noninteractive, black-weight rounded header. No native navigation
toolbar is visible inside app-owned sheets. Explicit Edit-mode ownership keeps
list reordering functional after moving Edit buttons out of toolbars. Nested
option editors retain Back/Done actions and receive the enclosing sheet's close
action, so the x dismisses the sheet rather than merely popping a page.

The iPhone/iPad presentation surface uses
[`presentationBackground(alignment:content:)`](https://developer.apple.com/documentation/swiftui/view/presentationbackground(alignment:content:))
with `PennedSheetBlurSurface`, a native `UIVisualEffectView` containing
`UIBlurEffect(style: .systemUltraThinMaterialLight)`. It fills the entire sheet,
including safe areas and empty space. There is exactly one live background blur,
not a static image, foreground blur, or glass card behind some of the content.

`PennedSheetStyle.blurIntensity` is `0.35`. A retained, linear
[`UIViewPropertyAnimator`](https://developer.apple.com/documentation/uikit/uiviewpropertyanimator)
interpolates the effect from `nil` to the light blur and is immediately paused at
[`fractionComplete = 0.35`](https://developer.apple.com/documentation/uikit/uiviewanimating/fractioncomplete).
This is 35% of the native effect transition, not a promised pixel radius or
35% view opacity. The effect view stays at its default alpha of 1, as required
by [Apple's visual-effect guidance](https://developer.apple.com/documentation/uikit/uivisualeffectview).
No opaque tint or color overlay is added. The system's existing modal dimming
and the foreground controls are unchanged. The researched intensity technique
also appears in [Dariusz Rybicki's native implementation](https://gist.github.com/darrarski/29a2a4515508e385c90b3ffe6f975df7);
Penned retains and reuses its animator rather than recreating it in `draw`.

The animator is started and paused in the same update, so its duration is not a
visible one-second animation. The blur surface is hosted by a native child
view controller. Initial installation is gated until
[`viewIsAppearing(_:)`](https://developer.apple.com/documentation/uikit/uiviewcontroller/viewisappearing(_:)),
where UIKit documents that the view is in its hierarchy with accurate geometry
and traits. Configuration or layout before that point cannot mark the partial
effect as installed. The surface is explicitly rebound in `viewDidAppear(_:)`,
after the presentation transition, as is the sheet's transparent native base.
This repeats the refresh that previously happened only after app reactivation,
without depending on the user taking a screenshot or leaving the sheet.

Size transitions use UIKit's transition-coordinator completion to refresh the
settled surface and native base. They do not replace a presentation delegate or
use estimated delays. Ordinary layout reuses the installed partial effect.
Reentry guards prevent effect changes during layout from recursively creating
animators. Window removal and SwiftUI dismantling stop and release the animator.
Foreground activation and contrast changes refresh it, avoiding an unintended
reset to full strength. Reduce Transparency uses the full native accessibility
effect rather than interpolating away the user's accessibility preference.

The native sheet's automatic background is disabled using
[`UIPresentationController.backgroundEffect`](https://developer.apple.com/documentation/uikit/uipresentationcontroller/backgroundeffect)
and every existing
[`UISheetPresentationController.Detent.backgroundEffect`](https://developer.apple.com/documentation/uikit/uisheetpresentationcontroller/detent/backgroundeffect).
Their `UIColorEffect(color: .clear)` is only a zero-alpha base beneath the live
blur, not the visible rendering or the rejected `UIGlassEffect(style: .clear)`.
It prevents a second full-strength blur or opaque large-detent default from
covering the adjustable effect. No custom detents or transitions are introduced.
The dark color scheme, 32-point native presentation corner radius, and subtle
noninteractive edge stroke remain.
The backdrop covers empty space as well as content. There is no black background
fill, static blur image, custom blur simulation, decorative gradient, foreground
blur, or second full-sheet material layer.
`scrollContentBackground(.hidden)` exposes the material behind forms/lists.
Collection form/list row surfaces use the tinted frosted material described below.
Other intentional field/card/preview backgrounds remain unchanged; the inline
property editor's field surfaces are translucent rather than opaque root panels.

## Universal Field Surfaces

App-owned sheet fields and grouped settings use `PennedFrostedMaterial`, copied
from the requested Voxiverse component. The original tinted native Liquid Glass,
internal pigment, surface frost, blur radii, and opacity values are retained.
The only theme dependency is translated from `VoxiverseColor.background` to
Penned's existing `VellixSurface.appBackground`. The source's icon-only material
and icon wrapper are not copied because they were not requested.

`Resources/PennedFrostedCard.swift` provides both reusable types:

- `PennedFrostedMaterial(tint:cornerRadius:)`: content-free background, default
  radius 17. It uses `.glassEffect(.regular.tint(...), in:)` and the source's
  clipped pigment/frost layers. Its local `.blur` calls affect only those layers,
  never foreground fields or the whole sheet.
- `PennedFrostedCard(tint:cornerRadius:contentPadding:minHeight:alignment:content:)`:
  compatible content wrapper retaining the source's 17-point radius, 15-point
  default content padding, optional minimum height, alignment, and two shadows.
  Existing fields use the material alone, not the card's padding or shadows.

`PennedSheetStyle.fieldTint` is neutral dark gray (`Color(white: 0.2)`, #333333).
Both custom fields and native grouped rows use this one tint. This requested
material replaces the previous full-strength dark `UIBlurEffect` field surface;
it does not add another effect above that old surface. The full-sheet native
light `UIBlurEffect`, its `0.35` intensity, and its presentation lifecycle remain
unchanged. The deployment target (iOS/macOS 26.5) supports the copied glass API.

`pennedSheetField(cornerRadius:)` supplies the background for custom text fields,
editors, search fields, pickers, date controls, and grouped option controls.
Existing field radii are passed to the material rather than adopting the card's
default radius. Foreground preview clipping and disabled-icon opacity happen
before the field background is attached. No field content, sizing, padding,
font, icon, separator, or header-control changes accompany this material swap.

`pennedSheetRows(showsSeparator:when:)` uses native
[`listRowBackground(_:)`](https://developer.apple.com/documentation/swiftui/view/listrowbackground(_:))
on the actual sections and standalone rows, not the outer Form.
`collectionFormRows(showsSeparator:)` delegates to that same implementation.
Input bindings, menus, selection, row moves/deletion, and scrolling remain. The background
cannot intercept touches or accessibility focus. Native Form/List layout owns
the existing section corner treatment. Both iOS and macOS use the copied field
material; no new sheet presentation system is introduced.

Native row separators are hidden on these rows. `PennedSheetRowBackground`
draws `PennedSheetFieldDivider` above its blur, inset horizontally and one pixel
inside the lower edge. The shared divider now wraps SwiftUI's native `Divider`,
without a hard-coded white fill, opacity or custom shape rendering, sized using
the environment's native
[`pixelLength`](https://developer.apple.com/documentation/swiftui/environmentvalues/pixellength)
so it retains the platform's subtler separator appearance. Keeping it above the
blur and inside the row avoids placing it on the boundary between neighboring
effect views, where the screenshot showed
missing/clipped segments. The exact system compositing failure was not reproduced
locally; this replaces that rendering path rather than relying on its draw order.
Rows explicitly identify whether another row follows, so single/last rows have
no unwanted bottom border and dynamic groups retain correct separators after
insertion, deletion, and reordering. Inline property options instead use separate
material surfaces per row, with no enclosing group material or inter-row divider.

Coverage includes collection sheets, property/option sheets, tables, tasks,
attachments, templates, folders, Spaces, page/card styling, icon/category
selection, search fields, and Calendar detail fields. Daily Notes applies row
styling only when presented as a sheet, retaining its ordinary Settings path.
Document content and previews, color swatches, selected-state accents, the
collection views embedded in documents, and the light sheet frosting are unchanged.
The OS-owned color palette and file/photo/Quick Look controllers keep their
native internal controls; no private view hierarchy is restyled.

## Presentation Compatibility

The previous `presentationBackground(.ultraThinMaterial)` ShapeStyle path is not
used on current iOS/iPadOS. It can produce a flat fill on iOS 26, as independently
documented in [Expo's native SwiftUI reproduction](https://github.com/expo/expo/pull/49767).
Simply removing that modifier is insufficient: Apple's
[WWDC25 sheet guidance](https://developer.apple.com/videos/play/wwdc2025/323/)
describes the default full-height transition becoming opaque. This is why the
native effect is explicitly configured at both presentation and detent levels.

`PennedSheetBackdrop` is a transparent, noninteractive controller probe, not a
custom presenter. It walks parent controllers only until the nearest actual
modal owner, clears backing container colors inside that sheet, and configures
its existing `UISheetPresentationController`. It never changes the presenting
document, walks private subviews, replaces delegates/detents, or polls. Parent
attachment, appearance, layout, and SwiftUI updates recheck configuration so
replaced detents and nested navigation retain the transparent base. One shared
base identity and guarded setters prevent repeated allocations/assignments and avoid
competing updates from nested sheet views. No alpha reduction or masking is
applied to the native effect.

Older iOS targets and other platforms retain the SwiftUI presentation material
fallback. Penned currently deploys to iOS/macOS 26.5, so supported iPhones/iPads
always use the native effect API. Apple documents that native macOS SwiftUI
sheets do not support translucent presentation backgrounds; this change does
not introduce a replacement macOS presentation system. System accessibility
preferences such as Reduce Transparency remain respected by the native effect.

[`GlassEffectContainer`](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
groups only the related foreground action controls. Capsule actions use native
`.buttonStyle(.glassProminent)`; the close control uses
`.glassEffect(.regular.interactive(), in: .circle)`. No glass effect is applied to
the entire content hierarchy. Availability checks provide native material/button
fallbacks below iOS/macOS 26. Penned currently deploys to iOS/macOS 26.5.
Sheet accents use the existing `VellixSurface.violet`; no document colors change.

Compact tag actions use the shared chrome's actionable-header overload: Go to
Tag and the top-right close button share the first row. Swap Tag and Turn into
Text follow directly below with matching horizontal insets. There is no empty
header row above the actions; the compact detent is calculated from their actual
scaled minimum row height. All three original actions and icons are retained.

`PennedSheetToggleStyle` applies through the shared presentation modifier to
every descendant Toggle. It retains the original Bool binding and enabled
state. Its thumb is a round button-shaped surface containing the existing
`checkwavy`/`xmarkwavy` assets, inside a purple/off-state capsule track. Animation
respects Reduce Motion; a native Toggle accessibility representation retains
VoiceOver semantics and On/Off state without a second persistence path.

`PennedSheetSearchField` keeps icon/folder searches in visible content after
hiding their navigation bars. Daily Notes uses the same content search only
when presented in the calendar sheet, retaining its normal navigation search
when opened in Settings. Apple's color palette is embedded as a native child
controller, with clear root backgrounds and shared close controls; its actual
color modes and original color bindings remain native.

## Coverage and File Inventory

This inventory is limited to the universal-sheet change; the workspace contains
unrelated and earlier feature edits that are intentionally preserved.

| File | Change |
| --- | --- |
| `Vellix/Resources/PennedSheetStyle.swift` (new) | Shared presentation material, title/chrome, glass controls, asset toggle style, nested close environment, and content search field. |
| `Vellix/Attachments/AttachmentEditorSheet.swift` | File settings: close/Save group and inherited custom size toggle. |
| `Vellix/Calendar/CalendarEventDetailSheet.swift` | Continuous material; close moved out of the event header. |
| `Vellix/Calendar/CalendarView.swift` | Calendar's Daily Notes configuration sheet uses shared chrome. |
| `Vellix/Collections/CollectionDocumentIntegration.swift` | Collection creation and entry creation/actions retain commit operations in shared controls. |
| `Vellix/Collections/CollectionPropertySheets.swift` | Value/field sheets, Edit/Save, custom toggles, nested option closing, and transparent form roots. |
| `Vellix/Collections/CollectionViewSheets.swift` | Management, add/edit view and filter sheets; Edit-mode, Save, and all visibility/gallery toggles. |
| `Vellix/Collections/CollectionKanbanView.swift` | Column list/editor, Edit/Save controls, and native color sheet integration. |
| `Vellix/DailyNotes/DailyNotesSettingsView.swift` | Visible search and purple controls when used in a sheet; ordinary Settings navigation remains intact. |
| `Vellix/DailyNotes/TemplateComponentEditorSheet.swift` | Component Add/Save and close controls. |
| `Vellix/Documents/FolderLibraryViews.swift` | Folder edit/move sheets and content search; reuse shared native color picker instead of duplicate presentation wrapper. |
| `Vellix/Documents/HomeView.swift` | Customize Home uses shared chrome and custom toggles. |
| `Vellix/Editor/CardBackdropSheet.swift` | Remove opaque panel root and duplicate close button. |
| `Vellix/Editor/CardPhotoSearchSheet.swift` | Unsplash sheet: shared surface and close control. |
| `Vellix/Editor/CardThreeModeColorPicker.swift` | Native color controls embedded beneath shared chrome, including folder icon colors. |
| `Vellix/Editor/DocumentEditorView.swift` | Inline blockquote/callout color sheets, icon library, snapshots, and selected-block action sheet; remove opaque sheet roots and keep searches visible. |
| `Vellix/Editor/DocumentStyleSheet.swift` | Page/font/cover/backdrop/style panels, Back/Reset/Save group, custom Blur Image toggle, and removal of redundant material. |
| `Vellix/Editor/InlinePropertyEditorSheet.swift` | Property/option editors, close/Back/Done, translucent fields, and custom Bool/date/time toggles. |
| `Vellix/Editor/PageCardEditorSheet.swift` | Close/Done group, saving guard, and transparent root. |
| `Vellix/Editor/TableEditorSheet.swift` | Table panels, Back and insert/apply/Save actions, custom header toggles, removal of redundant material. |
| `Vellix/Editor/TaskEditorSheet.swift` | Task panels, Back/Set/Confirm beside close, existing validation/saving guards, removal of redundant material. |
| `Vellix/Spaces/PennedSettingsView.swift` | Space picker becomes a full-sheet material instead of an inset material card; Create Space beside close. |
| `Vellix/Spaces/SpaceViews.swift` | Space editing/transfer Save/Move/Copy groups, preserving import/saving guards. |
| `Vellix/Tags/TagBrowserView.swift` | Matching-block sheet uses continuous material and shared close control. |
| `Vellix/Tags/TagEditorIntegration.swift` | Tag action/selector sheets use the same material/chrome without duplicate surfaces; existing detents and mutation guards retained. |
| `Scripts/test-collections.mjs` | Include the real shared sheet source in the existing headless native harness. |
| `Scripts/test-sheet-style.mjs` (new) | Static checks for all 34 named sheet/content views, inline presenters, material ownership, toolbar/root-background removal, toggle semantics and content searches. |
| `Docs/Sheets.md` (new) | Usage, coverage, verification and limitations. |

Detents, selected detent bindings, drag indicators, native `.sheet` presentation,
interactive-dismiss guards, save closures, data models, persistence, and document
background/rendering code are not replaced. OS-owned Files, Photos, Quick Look,
system color subdialogs and permission prompts retain their Apple interfaces;
the app does not intercept private UIKit internals to restyle those controllers.

## Field Rollout Files

This follow-up extends the approved full-strength collection fields to other
app-owned sheets and replaces the affected divider rendering. Only these files
change for this follow-up; earlier workspace changes remain intact.

| File | Field/divider change |
| --- | --- |
| `Vellix/Resources/PennedSheetStyle.swift` | Universal full-strength field/row backgrounds, native effect bounds/corners, pixel-sized foreground separators, and search-field styling. The light sheet stays at 0.35. |
| `Vellix/Collections/CollectionPropertySheets.swift` | Delegate to universal rows; explicit dividers for field options, number settings, and date/value controls. |
| `Vellix/Collections/CollectionViewSheets.swift` | Management/views/filters use explicit row separators with correct final-row handling. |
| `Vellix/Collections/CollectionDocumentIntegration.swift` | Collection/entry form separators without changing persistence or actions. |
| `Vellix/Collections/CollectionKanbanView.swift` | Column-list and column-editor separators; document Kanban cards stay unchanged. |
| `Vellix/Attachments/AttachmentEditorSheet.swift` | File metadata, display/size/alignment, and removal form row surfaces/separators. |
| `Vellix/Calendar/CalendarEventDetailSheet.swift` | Dark field surface for read-only event details, preserving document previews. |
| `Vellix/DailyNotes/TemplateComponentEditorSheet.swift` | Template question/range/choice/endpoint/action form row backgrounds and separators. |
| `Vellix/DailyNotes/DailyNotesSettingsView.swift` | Template selection row styling only in its sheet presentation; ordinary Settings remains unchanged. |
| `Vellix/Documents/FolderLibraryViews.swift` | Folder name/icon/color fields and destination rows. |
| `Vellix/Documents/HomeView.swift` | Customize Home's three toggle rows only. |
| `Vellix/Spaces/SpaceViews.swift` | Space name/description/image and destination-selection form rows. |
| `Vellix/Spaces/PennedSettingsView.swift` | Space-picker search field and its divider; ordinary Settings screens stay unchanged. |
| `Vellix/Editor/InlinePropertyEditorSheet.swift` | Shared property/option fields and option-group foreground dividers. |
| `Vellix/Editor/TableEditorSheet.swift` | Table creation, header/format/style controls, content/formula/name/search fields and field-choice surfaces. |
| `Vellix/Editor/TaskEditorSheet.swift` | Reminder/date/time/recurrence controls and field-choice surfaces. |
| `Vellix/Editor/DocumentStyleSheet.swift` | Style selectors, backdrop options, color/direction/image controls and search; previews/colors remain actual document styling. |
| `Vellix/Editor/PageCardEditorSheet.swift` | Background and preview-choice fields, plus a pixel-sized panel divider. |
| `Vellix/Editor/CardBackdropSheet.swift` | Mode, color and image-source field surfaces; image/color previews remain unchanged. |
| `Vellix/Editor/CardPhotoSearchSheet.swift` | Photo-search field background only. |
| `Vellix/Editor/DocumentEditorView.swift` | Sheet icon/category and custom-color fields, category dividers, and disabled-foreground opacity placement; editor/document rendering is untouched. |
| `Vellix/Editor/CardThreeModeColorPicker.swift` | Field style for the app-owned non-UIKit fallback; native iOS palette internals are unchanged. |
| `Vellix/Tags/TagEditorIntegration.swift` | Swap Tag's search field; tagging behavior and compact action-sheet layout remain unchanged. |
| `Scripts/test-sheet-style.mjs` | Shared field/divider invariants, sheet coverage, last-row/dynamic-group rules, opacity/clipping and non-sheet isolation checks. |
| `Docs/Sheets.md` | Shared field usage, exact rollout inventory, verification and runtime limitations. |

## Targeted Sheet Refinements

The latest correction changes five files:

| File | Change |
| --- | --- |
| `Vellix/Resources/PennedSheetStyle.swift` | Use an un-tinted native `Divider` in place of the hard white rectangle; keep row-bound clipping and the existing full-strength field/light-sheet blur settings. |
| `Vellix/Editor/DocumentStyleSheet.swift` | Remove the Custom Style/creator footer from overview and gallery; contain the overview tiles in a bounded scrollable layout without changing style saving/applying. |
| `Vellix/Spaces/PennedSettingsView.swift` | Search beside the close button, spaces directly below, and Create Space pinned at the bottom. Use compact count-based sizing, scalable rows, rounded fonts and the existing purple selection accent. Filtering, switching and nested creation remain intact. |
| `Scripts/test-sheet-style.mjs` | Regression checks for the native separator, footer removal, contained overview and compact switcher layout/behavior. |
| `Docs/Sheets.md` | Record these scoped changes and validation boundaries. |

The switcher uses the existing shared actionable-header overload instead of a
new presentation path. Its search and close controls share a 44-point row;
the list follows after 8 points. The compact height uses active Space count,
not query results, so typing does not resize the sheet. Long names may wrap,
larger text scales the row minimum, and longer lists can still scroll or expand
to the existing large detent. Create Space remains a native purple glass capsule.

## Compact Collection Management

The Collection management sheet opts into `collectionForm(compact: true)`;
other collection forms retain their existing sizing. Previously, the shared
helper only hid the Form's scroll background. Native Form row insets were still
added around content, including the Views menu's 44-point hit target, and native
section/header minimums and top content margins were unchanged.

That first correction still imposed 44-point minimums on the name field and
interactive labels, plus a fixed 44-point height on the Views actions menu.
Together with a 44-point Form row minimum, these constraints kept small icons
and text inside disproportionately tall containers. Form-level inset settings
also did not explicitly size each section label's gap to its fields.

Compact forms now remove the row/header minimums and enable shared
`PennedSheetRowInsets` through `pennedSheetCompactRows`. `pennedSheetRows` applies
the compact insets at the actual row/section styling point: 9 points above and
below content, retaining the existing 20-point horizontal insets. This adds
6 points of total height to the preceding layout's 6-point insets,
without restoring the old forced heights. Text and icon sizes and vertical
centering are unchanged. The name,
buttons, and menu no longer impose vertical frames. Row height follows actual
text/icon height plus those insets and grows naturally for larger text, rather
than replacing the old minimum with another fixed height. Labels still fill
available width with rectangular touch areas; the actions menu retains its
44-point width and separate target.

The three native Section headers use `pennedSheetSectionHeader()` to remove
top inset and leave 6 points below their labels. Sections are separated by the
existing 14-point spacing token. Extra scroll top margin remains zero, and
borderless buttons/plain text fields retain their prior appearance. Other
sheets default to the original sizing because compact rows are opt-in.
Views retain explicit 12-point row/10-point label spacing. Rounded black-weight
text, existing icons, bindings, menus, reordering, and top-right actions remain.
The shared light sheet blur at `0.35` and full-strength dark row blur are not
modified. Source checks and device compilation do not establish rendered
iPhone/iPad spacing; no simulator is used.

The first density change passed 93 source checks and generic iOS device
compilation but did not establish the desired proportions on the user's
device. The content-driven correction requires its own checks and device
compilation; neither is a substitute for rendered-device verification. The
correction passes all 95 sheet source checks and generic iOS device compilation
with code signing disabled. Outputs are `/tmp/penned-content-rows-checks.log`
and `/tmp/penned-content-rows-build.log`. No app or simulator was launched.

The small 9-point inset adjustment passes the same 95 source checks and Swift
parsing. No full build or rendered-device check was rerun for that numeric
adjustment. Source-check output is `/tmp/penned-roomier-rows-checks.log`.

## Continuous Collection Section Backgrounds

The earlier brightness explanation was an inference, not a confirmed device
diagnosis. The rendering trace establishes the following concrete facts:

- Every old `listRowBackground` instantiated its own
  `PennedSheetBlurSurface.Controller` and `UIVisualEffectView`. Applying this
  modifier to a `Section` still supplies row backgrounds; it does not create
  one common section surface.
- Each row used full-strength `systemUltraThinMaterialDark`, with rectangular
  native effect clipping. Native Form cell/group clipping surrounded these
  views. The controller's appearance callbacks installed the effect, and
  dismantling/window removal cleared it. These were independent lifecycles.
- Rows with separators supplied a different background value from Add View
  and Add Field. The separator itself is only a foreground native Divider;
  it requests no alternative material. The Collection code contains no
  selected-row fill, alternate-light style, opacity change, or alternating
  background rule. The selected-view indicator is only the existing icon.
- The light full-sheet effect is a separate presentation-level surface at
  `0.35`. `scrollContentBackground(.hidden)` leaves it visible between groups.

This confirms a structural mismatch with the required continuous section
surface. It does not prove which native cell mask, lifecycle, or backdrop
sample produced each light band on the user's device. Apple's
[visual-effect documentation](https://developer.apple.com/documentation/uikit/uivisualeffectview/)
also cautions against ancestor masks around effect views, so material names
alone cannot verify the rendered result.

Collection management now opts into section-owned native backgrounds. Its
existing row-background hosts become transparent geometry probes plus the
unchanged separators. They locate their actual public UITableView or
UICollectionView ancestors. A noninteractive background plane behind those
same native cells owns exactly one `PennedFrostedMaterial` surface
per visible logical section. It is sized from the union of the native row
background frames, not estimated row heights. Native effective corner radii
are read from the first/last row's clipping ancestors and applied directly
to the background host. No cell frames, constraints, masks, selection state, or
delegate are modified.

Probe layout/window callbacks and native bounds/content-size observations
update the background geometry through UIKit only. There is no geometry
feedback into SwiftUI state, polling, delay, screenshot dependency, or log
output. Surfaces are reused by section identity and removed when their rows
are no longer present. Stable native view identifiers are
`Penned.SectionBackground.collection-views` and
`Penned.SectionBackground.collection-fields` for device hierarchy inspection.

The existing Form, individual native rows, bindings, menus, move callbacks,
separators, all 9/6/14-point layout values, text/icon sizes, header controls,
and light sheet renderer remain unchanged. The requested Voxiverse material
now replaces the former section `UIVisualEffectView`, hosted with native
`UIHostingConfiguration.makeContentView()`. Zero configuration margins and
minimum sizes keep this background from imposing new row dimensions. The host
is transparent, noninteractive, sized to its existing measured bounds, and
clipped with the same native section corners. There is no additional per-row
material in opted-in groups. Other fields use the same recipe through their
existing shared field/row modifiers.

Verification must distinguish implementation checks from the physical
result: source checks and generic iOS device compilation do not establish
that the visible banding is gone, nor do they constitute a captured native
view hierarchy. First presentation, scrolling/reuse, nested sheets, corner
fidelity, and the continuous dark appearance still require the user's
device check. No simulator or application is launched for this change.

The background-only correction passes 100 source checks and generic iOS device
compilation with code signing disabled. Outputs are
`/tmp/penned-section-backdrop-checks.log` and
`/tmp/penned-section-backdrop-build-final.log`. These verify code structure and
compilation, not on-device compositing or visual resolution.

Files changed for this background-only correction:

- `Resources/PennedSheetSectionBackground.swift`: native section ownership,
  transparent row probes, measured geometry/corners, effect reuse and cleanup.
- `Resources/PennedSheetStyle.swift`: route only opted-in row backgrounds to
  probes; leave the existing blur renderer, separators and layout intact.
- `Collections/CollectionViewSheets.swift`: identify the three groups and
  opt the existing Form into shared backgrounds. No row content changes.
- `Scripts/test-sheet-style.mjs`: section ownership/layering, cleanup,
  no polling/logging, native geometry, and approved-layout invariants.
- `Docs/Sheets.md`: trace, correction, verification limits and file inventory.

## Requested Voxiverse Material Port

This later request explicitly changes field material, not row layout or the
sheet backdrop. Files for this port:

- `Resources/PennedFrostedCard.swift`: new renamed material and compatible card.
- `Resources/PennedSheetStyle.swift`: shared dark-gray field tint and canonical
  material routing for all existing sheet field/row consumers.
- `Resources/PennedSheetSectionBackground.swift`: one hosted instance of that
  same material per Collection group, retaining native geometry and ownership.
- `Scripts/test-sheet-style.mjs`: copied recipe/API checks, shared tint routing,
  section hosting, unchanged row metrics, and unchanged light-sheet assertions.
- `Scripts/test-collections.mjs`: include the new production component in the
  existing full headless macOS module so shared sheet code still compiles. Full
  mode uses the app's macOS 26.5 minimum for Liquid Glass; domain-only mode keeps
  its existing macOS 15 minimum. No app deployment settings are changed.
- `Docs/Sheets.md`: current rendering path, scope, and verification limitations.

Source checks and device-target compilation do not verify the rendered result.
No simulator or application is launched. First presentation, group continuity,
contrast, and frost appearance remain for physical-device verification.

Port verification: 102 source checks pass, including the original backdrop and
row-layout invariants. A direct normalized comparison against the supplied file
matches both copied types after name/theme substitutions. Generic iOS device
compilation succeeds with signing disabled. The full headless macOS suite passes
156 tests in 12 suites; existing Swift 6 migration warnings remain outside this
change. Logs: `/tmp/penned-frosted-material-checks.log`,
`/tmp/penned-frosted-material-build.log`, and
`/tmp/penned-frosted-material-native-tests.log`.

## Inline Property Option Surfaces and Sheet Return

`InlinePropertyEditorSheet.optionsSection` applies the existing
`pennedSheetField(cornerRadius: 16)` inside each option button's label, after its
unchanged horizontal/vertical padding. The outer stack has no material and uses
the existing 10-point field gap. Each option's pigment/frost layers are contained
within that row rather than stretched across the entire options group. Pills,
drag handles, editing, reordering, context menus, and accessibility actions stay
intact. Neither `PennedFrostedMaterial` nor the shared tint or sheet backdrop is
modified.

The blank paragraph had a separate confirmed cause: the native property sheet's
`onDismiss` calls `resumeEditingAfterProperty`, which sends
`focusAfterInlineProperty` to the editor. That JavaScript helper previously called
`placeCaretInParagraphAt` when no paragraph followed the property, including a
property at the end of a nested container. That helper performs a real document
insertion; it is not just caret decoration. The same fallback could also create
content after a deleted property if the remaining selection was not a text block.

The return helper now only focuses an existing following text block, or an
existing text selection after deletion. Otherwise it returns without editing the
document. Explicit blank-page taps still use the original paragraph-insertion
path. Existing document/editability/lock/selection guards remain unchanged.
Pre-existing paragraphs are not deleted or rewritten by this correction.

The runtime regressions exercise actual property configuration requests, repeated
returns for all seven property kinds at root and nested levels, saving, undo/redo,
adjacent properties/headings, reloading, explicit page taps, and Backspace. Before
the fix all 14 root/nested no-insertion cases reproduced the extra paragraph.
Backspace fixtures now explicitly create their typing paragraph through the page
tap command rather than relying on the sheet-dismissal bug to create it. The
fixture can also select a generated/shipping runtime via `PENNED_EDITOR_RUNTIME`.

Files changed:

- `Vellix/Editor/InlinePropertyEditorSheet.swift`: per-option material ownership.
- `vellix-backend/src/editor.js`: non-inserting property-sheet return behavior.
- `vellix-backend/tests/inline-property-runtime.test.js`: round-trip/content and
  existing typing/deletion regressions.
- `Scripts/test-sheet-style.mjs`: per-option material and native return guards.
- `vellix-backend/dist/tiptap.bundle.js` and
  `Vellix/VellixEditor.bundle/tiptap.bundle.js`: regenerate and synchronize only
  the editor JavaScript; retain all other shipping resources.
- `Docs/Sheets.md`: behavior, cause, scope, and verification boundaries.

No material, Collection-row layout, document styling, or database schema is
changed, and no existing data is migrated or deleted. Native visual presentation
and physical-device keyboard behavior are not established by the headless checks.
No simulator or app is launched.

Verification passes: 104 sheet source checks; 50 focused editor/property/gap tests,
with the property runtime fixture loading the actual shipping bundle; and generic
iOS device compilation with signing disabled. Before/after SHA-256 checks confirm
`PennedFrostedCard.swift` and `PennedSheetStyle.swift` are unchanged, and the
generated/shipping JavaScript hashes match. Logs:
`/tmp/penned-inline-property-sheet-checks.log`,
`/tmp/penned-inline-property-runtime-tests.log`, and
`/tmp/penned-inline-property-device-build.log`.

## Verification

- `node --test Scripts/test-sheet-style.mjs`: 104 source-level checks pass, covering
  native blur interpolation and intensity, actual presentation-background
  ownership, every detent, cleanup/reuse, accessibility/foreground handling,
  appearance gating, post-presentation rebinding, transition completion,
  container scoping, universal field coverage/light-sheet isolation, pixel-sized
  separators above the blur, last-row handling, foreground opacity/clipping,
  tag-action alignment, native separator styling, style-footer removal and
  compact Space-switcher placement/behavior, content-sized Collection rows,
  shared opt-in insets, and explicit section-label gaps. The latest checks
  also cover section-owned backgrounds,
  transparent row probes, native corner/frame measurement, effect reuse and
  geometry-observer cleanup. They do
  not render a sheet or establish physical-device visual fidelity.
- `PENNED_FULL_APP_TESTS=1 node Scripts/test-collections.mjs`: 156 headless native
  tests in 12 suites pass, including persistence, tag/navigation, Daily Notes,
  attachments, collections, and editor change tracking.
- Generic iOS device compilation uses `-sdk iphoneos -destination generic/platform=iOS`
  with code signing disabled. This is compilation only, not an app launch.
- No simulator is booted, launched, selected as a destination, or used for tests.
- Source checks and compilation do not prove visual fidelity. Actual backdrop
  sampling, sheet contrast over different documents, Reduce Transparency,
  native palette presentation, dynamic-type action sizing, keyboard focus,
  VoiceOver interaction, and iPhone/iPad detent transitions still require
  physical-device runtime verification.
- A paused property animator remains active while it holds the partial effect.
  Interaction with XCTest UI-idleness detection is not verified; do not finish
  the animator just to make a UI runner idle, which can commit the full effect.

Current refinement build output: `/tmp/penned-sheet-refinement-build.log`.
Headless native test output:
`/tmp/penned-sheet-refinement-tests.log`. Source-check output:
`/tmp/penned-sheet-refinement-checks.log`. Existing Swift 6 migration warnings remain outside
this visual-presentation change.

The top-right placement correction updates the shared style, its source-level
regression check, and these notes. Its generic iOS device build output is
`/tmp/penned-sheet-top-right-build.log`; device appearance remains unverified.

The subsequent frosted-background and tag-action spacing correction changes
only `Resources/PennedSheetStyle.swift`, `Tags/TagEditorIntegration.swift`,
`Scripts/test-sheet-style.mjs`, and this document. Other sheet contents, editor
rendering, document colors, persistence, and existing action callbacks are
intentionally unchanged.

The interim clear-glass adjustment was rejected after device screenshots showed
it removed frosting rather than reducing blur. It has been replaced by the
paused `UIBlurEffect` interpolation above. This correction changes only
`Resources/PennedSheetStyle.swift`, `Scripts/test-sheet-style.mjs`, and this
document. Tag layout, sheet controls, detents, dismissal, document rendering,
and persistence are unchanged. Compilation output is recorded in
`/tmp/penned-sheet-intensity-build.log`; final visual fidelity still requires a
physical-device check, not a claim based on source tests or compilation.

## Light Material Comparison

For the requested first comparison, the shared effect switches only from
`systemUltraThinMaterialDark` to `systemUltraThinMaterialLight`. Interpolation
stays at `0.35`; the dark foreground color scheme, fields, layout, and animator
lifecycle are unchanged. The Collection management sheet removes its header
Edit button while retaining Done, the custom x, and row-menu editing/reordering.
Other sheets' functional Edit controls are intentionally left alone.

Device screenshots showed that the partial blur refreshed only after taking a
screenshot and returning to the sheet. The material swap alone did not address
that behavior. During the comparison, automatic refresh and field styling were
intentionally unchanged.

The light-material comparison passes all 47 source checks and generic iOS device
compilation. Outputs are `/tmp/penned-sheet-light-comparison-checks.log` and
`/tmp/penned-sheet-light-comparison-build.log`. No simulator or app was launched;
the light preset's final appearance still needs physical-device verification.

## First-Presentation Refresh

The approved appearance remains `systemUltraThinMaterialLight` at `0.35`.
The likely initialization problem was that the effect was installed during
early layout, while UIKit was still transitioning the sheet. Native geometry
and effect-container updates can occur again during that transition, but there
was no explicit rebind afterward. App reactivation forced a later rebuild,
matching the reported screenshot-and-return behavior. This is an inference
from the source and device report, not a separately reproduced device diagnosis.

The shared surface now uses the documented appearance callbacks above. The
automatic background is also rechecked after appearance, and both components
refresh after native size-transition completion. Teardown resets appearance
readiness so a detached view cannot install an effect early when reused.

Only `Resources/PennedSheetStyle.swift`, `Scripts/test-sheet-style.mjs`, and this
document change. The light style, intensity, fields, document backgrounds,
controls, removed Collection Edit button, detents, and persistence are unchanged.
There is no screenshot notification observer, artificial capture, static image,
timer, draw-time animator recreation, or continuous refresh loop. These source
checks and compilation cannot establish that the physical-device issue is gone;
opening fresh/reopened/nested sheets without a screenshot still needs device
verification.

The lifecycle correction passes 50 source checks, the 156-test headless native
suite, and generic iOS device compilation. No simulator or application was
launched during verification.

The subsequent collection-field adjustment passes 63 source checks and generic
iOS device compilation; build output is
`/tmp/penned-collection-field-blur-build.log`. It changes the shared blur renderer,
the four collection sheet source files, the sheet source checks, and these notes.
No simulator or application was launched. The headless persistence suite above
was not rerun for this visual-only adjustment. Field blur contrast, native row
clipping, scrolling/reuse, and first appearance still need physical-device
verification; compilation and source checks do not prove their appearance.

The full-strength field comparison changes only the shared renderer's intensity
parameter, `collectionFormRows()` in `CollectionPropertySheets.swift`, the source
checks, and these notes. Fields now use `intensity: 1`; the light sheet remains
at `0.35`. All 63 source checks and generic iOS device compilation pass; output
is `/tmp/penned-collection-field-full-blur-build.log`. No simulator or application
was launched, and the rendered appearance remains unverified on a device.
