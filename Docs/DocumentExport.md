# Document Export

## Entry Point

The existing document sharing button opens `PublishingSheet`. Its Export tab
contains PDF, Markdown, Print, Image, MS Word, Email, Duplicate, Link, and
Advanced > TextBundle. No extra editor toolbar button was added. Switching tabs
retains the selected document, including a child page or collection entry.

## Implemented Workflows

- PDF: separate read-only WebKit render, PDFKit assembly, multipage preview,
  system sharing/saving, paper and appearance settings.
- Print: the same PDF output handed to UIPrintInteractionController on iOS/iPadOS
  and PDFKit/NSPrintOperation on Mac. Copies, ranges, printer selection, layout,
  and device-specific preferences belong to the real system print dialog.
- PNG: complete document divided into sequential images, with Fit Document,
  Portrait, Landscape, Square, cover/title/tag/style/font controls, image copying,
  sharing, and Mac saving. Long documents are not truncated to the viewport.
- Markdown: actual `.md` text with semantic blocks, marks, lists, task syntax,
  quotes, code fences, tables, links, captions, property values, component
  responses, nested references, and collection values. When assets exist, the
  share output also includes a ZIP containing the `.md` and relative `assets/`.
- Word: OOXML `.docx` ZIP with document XML, relationships, styles, numbering,
  embedded PNG images, tables, headings, hyperlinks, and editable text.
- Email: attachment-format selection and an actual user-controlled mail composer
  on iOS/iPadOS, or NSSharingService's compose-email service on Mac. Mail is never
  sent automatically. Unconfigured Mail produces an error and a sharing fallback.
- Duplicate: existing transactional `TemplateRepository.cloneTree` and document
  duplicate routines, including descendants, independent IDs, attachments,
  collection fields/values, and component responses. Current Location preserves
  collection-entry membership; choosing a Space creates a new root copy there.
  A collection entry copied to a Space root retains its former field values as
  independent inline properties instead of referencing the original collection.
- Link: current active/unexpired public URL when available, otherwise the private
  internal URL. Separate private and Markdown-deeplink copy actions. Link never
  creates a publication or changes publishing permissions.
- TextBundle: version-2 `.textbundle` directory with `info.json`,
  `text.markdown`, and relative `assets/`; packaged as `.textpack` for transport.
  See the [TextBundle specification](https://textbundle.org/spec/).

## Rendering And Data Boundary

`DocumentExportSnapshot` commits pending editor saves through existing APIs and
captures only the selected document for file exports. Child pages and collection
entries retain their visible cards/references; their document bodies are not
appended to the export. PDF, image, and print output keep the actual nested card
or page preview, including its thumbnail, excerpt, cover, and saved card styling,
using the editor's existing reference renderer. The full child documents are not
added as extra export pages. Hidden, unused reference-image elements are excluded
from asset decoding and missing-image warnings. Markdown and Word references
emit the child title only (with its private link in Markdown). No recursive export
option is exposed. Duplicate remains
a separate operation that clones the owned descendant tree. Exports do not
traverse parent or sibling bodies.
The parent collection of an exported entry supplies that entry's property values,
not sibling pages or sibling assets. Embedded collections retain their active
view's approved field selection, filters, sorting, and Kanban placement.

`DocumentExportRenderer` owns a new nonpersistent WKWebView and snapshot-scoped
asset handlers. It reads the existing bundled HTML unchanged. Commands and
export-only DOM preparation run after readiness with structured arguments. It
does not change the live WebView, editor session, HTML assembler, startup,
document JSON, editor selection, or publishing status.

Actual editor NodeViews/CSS render rich-text blocks, attachments, page cards,
components, gallery collections, and table collections. Native-only Kanban
collections receive a static read-only DOM rendition. Lazy collection entries
are materialized; gallery scrolling masks and editing controls are excluded.
Native background/cover rendering supplies images for saved themes and styling.
Before PDF capture, local attachment images, collection covers, and icon masks
are resolved from snapshot-approved assets and embedded as data URLs, including
CSS and pseudo-element resources. Export does not depend on the live editor's
streaming attachment session. Images are decoded before measuring pagination.
Gradient spans are painted against export line geometry with their saved angles.
Block, row, and text-line boundaries guide pagination. Explicit page breaks are
honored, and oversized blocks continue across slices rather than being dropped.
Gallery and Kanban cards are not treated as indivisible page-size blocks, so a
collection can start beneath its heading and continue on subsequent paper pages.

Account/Space changes invalidate in-progress generation. Export asset paths use
AttachmentStore validation. ZIP entries reject path traversal and fail explicitly
at the ZIP32 size/count limit. Errors remove unfinished output. Successful files
remain in the OS temporary directory so native sharing can finish reading them.

## Format Limits And Fallbacks

- PDF/PNG are the visual-fidelity formats. Static video/audio representations
  retain a poster/name; they do not contain playable media. An embedded PDF uses
  its document preview, not a recursive export of every page of that attachment.
- Markdown cannot encode native backgrounds, exact typography, table spans,
  custom layout, or editable widgets. Callouts use quoted notes, toggles expand
  their own blocks in document order, collections use tables, and components use
  their saved values. Unsupported colors, gradients, underline, and caption sizing
  fall back to plain text. No synthetic HTML anchors, page-break elements, styling
  spans, or other HTML wrappers are generated. Actual user-authored code blocks
  remain code blocks.
- Word uses a solid-color fallback for gradient text and page backgrounds,
  portable font substitutions, and textual representations for interactive
  components and nonimage attachments. Externally hosted legacy images may be
  represented by their source/description rather than embedded bytes. Tables
  preserve content and supported cell fills/alignment; exact custom spacing,
  complex merged-cell layout, and native control geometry are not guaranteed.
- A missing stored asset is reported, not silently counted as successfully
  embedded. A missing cover that cannot decode stops visual generation with a
  specific error. Remote-only media still depends on its source being reachable.
- Private deeplinks require the matching library/account and an available owned
  document. They are not public web links. They use the registered `penned` URL
  scheme and existing Space/navigation operations.

## File Inventory

New shared files under `Vellix/Export/`:

| File | Responsibility |
| --- | --- |
| DocumentExportModels.swift | Formats, settings, filenames, outputs, errors |
| DocumentExportSnapshot.swift | Saved, scoped hierarchy and asset capture |
| DocumentExportArchive.swift | Streaming stored ZIP for OOXML and packages |
| DocumentMarkdownExport.swift | Semantic Markdown conversion |
| DocumentWordExport.swift | OOXML writing, images, styles, numbering, tables |
| DocumentExportScript.swift | Isolated static DOM preparation and page slicing |
| DocumentExportRenderer.swift | Export-only WebKit lifecycle, PDF and PNG capture |
| DocumentExportService.swift | Generation orchestration, packaging, duplication, cancellation |
| DocumentExportPlatform.swift | PDF preview, native share/save/print/mail, pasteboard |
| DocumentExportSheet.swift | Export rows, previews, duplicate/link/email/advanced sheets |
| DocumentExportSettingsSheet.swift | Working format-specific settings |
| DocumentInternalLink.swift | Canonical scoped private document route |

Existing files updated:

- `Vellix/Publishing/PublishingSheet.swift`: enable and host the Export tab;
  existing Publish controls and queue behavior are unchanged.
- `Vellix/VellixApp.swift`: accept private document URLs, including after startup.
- `PennedMac/App/MacApplicationModel.swift`: route private URLs through existing
  Mac workspace operations without bypassing tab/Space ownership.
- `Vellix/Resources/LaunchInfo.plist` and
  `PennedMac/Resources/MacInfo.plist`: register the private `penned` URL scheme.
- This document records architecture, format fallbacks, and verification limits.

## Verification Status

Source implementation only. Per the explicit instruction, no builds, tests,
simulators, app launches, generated-file validation, or printer/mail workflows
were run. This document does not certify runtime correctness or pixel parity.

Before release, verify on iPhone, iPad, and Mac: long styled PDF/PNG output,
gradient directions, backgrounds and custom covers, tables and every collection
view, nested/collection-entry exports, missing files, cancellation, account/Space
changes, opening DOCX in Word, TextPack import, saving/sharing, configured and
unconfigured Mail, printing, independent duplicate edits, and private-link routing.
Confirm ordinary document opening/editing and existing publishing still work.
