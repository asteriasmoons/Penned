# Editor Attachments

## Storage And Rendering

Files stay in the existing `AttachmentStore` and GRDB `attachments` table. There is no second storage system or schema migration. Original bytes, attachment IDs, filenames, MIME/UTI metadata and file sizes remain intact. ImageIO and file signatures take precedence over misleading filename extensions. Scripted/external-resource SVGs fall back to file cards instead of becoming executable editor content.

The new TipTap `attachment` block stores a file reference plus its own `displayMode`, `widthPercent`, `textAlign`, block ID and indentation. Multiple blocks can reference the same attachment with independent layouts. Native, Space-checked metadata determines the actual available renderer; pasted node metadata cannot grant filesystem access.

- Images use bare, responsive image elements. PNG alpha is preserved; GIFs use the original animated file, not a JPEG thumbnail. HEIC/HEIF can use a PNG display derivative without changing the original.
- PDFs show a bounded first-page preview and can open in Quick Look.
- Audio uses the compact pill-style player described below; video retains browser media controls. The native resource handler supports byte ranges, cancellation and bounded reads. Video has a stable preview frame and an optional undecorated poster.
- Other files use compact filename/size cards. Unsupported decoders fall back to a card with access to the original.
- SVG/video native thumbnails use the existing `thumbnailRelativePath` field. Quick Look is asked for raw thumbnails without icon framing and has a bounded optional request. Preview failure never rejects the original file.

## Interaction

Use the existing text-only Add menu's **File** action. The native file picker supports multiple files; pasted/dropped file bytes also go through native attachment import. Clipboard file transfers are bounded; larger files use the file picker.

Long press a file/image/player to open a native menu with **File Settings** and a direct destructive **Delete** action. Tapping an image/card still opens the existing-style settings sheet, with compatible display modes, original/custom width, alignment, Open Original, Share and Remove from Document. Delete removes only that document block and supports undo; shared attachment bytes remain intact. Read-only documents omit Delete. Menu requests retain their originating document so stale actions cannot affect another document. Media controls remain usable in read-only documents. Playback pauses when leaving the document or entering block selection.

Insertion ends at a collapsed text caret, not a selected image. File-containing block selections use the native HTML clipboard so Copy/Cut preserve formatting and references. Cut waits for clipboard success and rejects stale selection/document results. Duplicated file blocks receive independent block IDs; undo/redo groups file operations separately from initial document loading. Ordinary text-only clipboard behavior remains in place.

Removing a block does not delete the attachment bytes: undo, snapshots and other references may still need them. Document/template deletion uses the existing recoverable cleanup queue after committing SQL. A surviving same-Space reference retains ownership before its original page is permanently deleted. References remain available while their original owner is in Trash. Cross-Space file resolution is rejected; use Move/Copy to Space to transfer content and its files.

The existing deep tree copier now handles ordinary document duplication as well as templates and Daily Notes. Original and thumbnail paths and attachment IDs are remapped together. Borrowed files used by the copied tree are copied independently. Space moves retain ownership relationships; Space copies generate new identities and paths.

## Files Changed

Paths below are relative to the Swift project unless marked `backend`.

| File | Reason |
| --- | --- |
| `Vellix/Attachments/AttachmentStore.swift` | Real-type imports, atomic registration, validated paths, scoped lookup, recoverable cleanup and retained references. |
| `Vellix/Attachments/AttachmentMedia.swift` (new) | Recognition, metadata, safe SVG parsing, PNG derivatives, thumbnail requests, file copying and byte-range parsing. |
| `Vellix/Attachments/AttachmentSchemeHandler.swift` (new) | Space-authorized original/preview streaming for WebKit, including ranged playback. |
| `Vellix/Attachments/AttachmentEditorSheet.swift` (new) | Display, size, alignment, original-file and removal controls. |
| `Vellix/Attachments/AttachmentBlockPreview.swift` (new) | Immediate native file/image previews. |
| `Vellix/Documents/DocumentRecords.swift` | Make immutable attachment metadata safely transferable to file-processing work. No column changes. |
| `Vellix/Documents/DocumentRepositories.swift` | Scoped file resolution, full duplication, borrowed-file independence, identity/path remapping and safe deletion. |
| `Vellix/Spaces/SpaceOperations.swift` | Preserve original filenames and duplicate/remap thumbnails with transferred files. |
| `Vellix/Editor/TipTapContentAnalyzer.swift` | Index filenames and recognize file-only documents as populated. |
| `Vellix/Editor/TipTapBridgeTypes.swift` | File menu, import and clipboard bridge events. |
| `Vellix/Editor/TipTapEditorSession.swift` | Metadata capabilities, background imports, pending-operation coordination, clipboard acknowledgement and media lifecycle. |
| `Vellix/Editor/TipTapWebView.swift` | Register the file-resource handler alongside existing handlers. |
| `Vellix/Editor/DocumentEditorView.swift` | Reuse Add menu, file picker and contextual sheet; stop playback when leaving. |
| `Vellix/Documents/DocumentPreviewCache.swift` | Resolve attachments before rendering saved previews. |
| `Vellix/Documents/DocumentPreviewContent.swift` | Version file-containing previews without invalidating unrelated previews. |
| `Vellix/Documents/ImmediateDocumentPreview.swift` | Include attachment blocks in immediate saved-document rendering. |
| `Vellix/Editor/DocumentThumbnailLayout.swift` | Represent image/card/media modes and sizing in miniatures. |
| `Vellix/VellixTests/AttachmentTests.swift` (new) | Recognition, transparency pixels, ranges, persistence, cloning, Spaces, templates, Daily Notes, thumbnails and cleanup. |
| `Vellix/VellixTests/AttachmentBridgeTests.swift` (new) | Native import payload validation. |
| `Scripts/test-collections.mjs` | Include new production files and tests in the existing headless harness. |
| `Vellix.xcodeproj/project.pbxproj` | Include attachment tests in the test target, not the app target. |
| `backend/src/attachments.js` (new) | Real node views, serialization, modes, clipboard/paste/drop integration and contextual actions. |
| `backend/src/editor.js` | Register the node and bridge, preserve file blocks in selection actions and isolate undo groups. |
| `backend/src/block-actions.js` | Let file-specific context menus handle their own surfaces. Existing table/collection protections are unchanged. |
| `backend/src/tiptap.html` | Bare transparent images, compact cards, bounded previews and responsive players. |
| `backend/tests/attachments.test.js` (new) | Exercise the actual editor bundle, bridge, history and serialization. |
| `backend/tests/attachment-browser.mjs` (new) | Shipping-bundle browser rendering, screenshot-pixel transparency, widths, audio and reopening checks. |
| `backend/tests/block-actions-runtime.test.js` | Cover file menus and include the actual 500 ms hold timer in the deterministic test harness. No gesture timing changed. |
| `backend/dist/tiptap.html`, `backend/dist/tiptap.bundle.js` | Generated editor output. |
| `Vellix/VellixEditor.bundle/tiptap.html`, `Vellix/VellixEditor.bundle/tiptap.bundle.js` | Synchronized shipping resources. |
| `Docs/Attachments.md` (new) | This implementation and verification record. |

## File Long-Press Delete Follow-up

Only these files changed for the direct Delete action:

| File | Reason |
| --- | --- |
| `Vellix/Attachments/AttachmentMedia.swift` | Keep the file menu tied to its originating document. |
| `Vellix/Editor/TipTapBridgeTypes.swift` | Distinguish long-press actions from tap-to-edit settings. |
| `Vellix/Editor/TipTapEditorSession.swift` | Route actions, reject stale document requests, and reuse undoable deletion with pending-operation coordination. |
| `Vellix/Editor/DocumentEditorView.swift` | Present File Settings and Delete directly on long press; omit Delete for locked documents. |
| `Vellix/VellixTests/AttachmentBridgeTests.swift` | Add native decoding coverage for the separate menu requests. |
| `backend/src/attachments.js` | Send a dedicated action-menu event on context menu gestures. |
| `backend/tests/attachments.test.js` | Verify tap/long-press routing, deletion, undo/redo, shared-file preservation and reopening. |
| `backend/tests/block-actions-runtime.test.js` | Verify files retain their own menu, separate from generic block deletion. |
| `backend/dist/tiptap.bundle.js`, `Vellix/VellixEditor.bundle/tiptap.bundle.js` | Regenerate and synchronize the updated editor. |
| `Docs/Attachments.md` | Record the interaction change and verification boundary. |

The 28 focused JavaScript attachment/block-action tests passed for this follow-up. The native bridge test was added but not run; no native compilation, app build or app/simulator launch was performed. Native menu presentation still needs device verification. Storage, file settings, tables and collections were intentionally left unchanged.

## Pill-Style Audio Player

Audio in Player display mode uses reference style 4: a rounded, subtly pink/purple surface with a circular play/pause button, filename, elapsed/total time, seek track, mute/unmute and the existing file actions menu. Attachment Card mode is unchanged. It uses the same hidden HTML audio element, stored file identity and native byte-range transport; no records or media files are rewritten. Playback controls work in read-only mode, do not select the block, and do not save transient playback state into the document. Existing playback shutdown, undo, duplication and file deletion remain intact.

| Changed file | Reason |
| --- | --- |
| `backend/src/audio-player.js` | Accessible pill controls, actual audio event synchronization, seeking, mute, playback error reporting and time formatting. |
| `backend/src/attachments.js` | Render the pill around the existing audio element; isolate player gestures and preserve the direct Delete menu. |
| `backend/src/editor.js` | Reuse registered icon sources and CSS variables for audio controls. |
| `backend/src/tiptap.html` | Compact responsive pill styling, seek track, focus states and block-selection protection. |
| `Vellix/Editor/TipTapEditorSession.swift` | Pre-register the existing play/pause assets and supported volume SF Symbols. |
| `Vellix/Attachments/AttachmentBlockPreview.swift` | Match the audio pill in immediate native previews. |
| `Vellix/Documents/DocumentPreviewContent.swift` | Invalidate old attachment previews so the new player appearance is rendered. |
| `backend/tests/attachments.test.js` | Verify time formatting, play/pause, seeking, mute, errors, read-only playback, selection guards, file actions, unchanged JSON and reopening. |
| `backend/dist/tiptap.html`, `backend/dist/tiptap.bundle.js` | Generated editor output. |
| `Vellix/VellixEditor.bundle/tiptap.html`, `Vellix/VellixEditor.bundle/tiptap.bundle.js` | Synchronize the shipping editor resources. |
| `Docs/Attachments.md` | Describe the player, changed files and verification boundary. |

Verification: 154 editor regression tests passed. A temporary Playwright check exercised the shipping bundle at 320, 390 and 834 point widths: actual WAV playback/pause, pointer seeking, mute/unmute, file action routing, independent document JSON, reopening, long filename truncation and narrow-width layout. All viewports were nonblank, had no page/console errors or horizontal overflow, and maintained a 76-point player height. Screenshots are in `/tmp/penned-audio-pill-qa/`. Browser plugin was unavailable, so the existing Playwright runtime was used. The browser check substitutes local byte transport and equivalent library volume glyphs for WebKit's SF Symbol image transport; play/pause/menu masks come from the actual asset PDFs.

No Penned app build, native compilation or app/simulator launch was performed. Native preview rendering, SF Symbol transport and iOS audio behavior still require iPhone/iPad verification. Attachment persistence, video controls, image rendering, file settings and Add menu behavior were intentionally left unchanged.

## Full Video Frame Fix

The reported screenshot shows a preview strip above an otherwise blank video area. The former renderer relied on a native video poster with an automatic height, a fixed 16:9 ratio and a height cap. The affected physical device and its original file were not available for reproduction, so this is not proof of a failed download or a corrupt file.

Videos now use an explicitly sized frame. Both the video and a separate document-layer poster fill that frame with `object-fit: contain`; neither is cropped. Poster dimensions establish the initial ratio, and actual video dimensions take precedence when available. The existing height cap remains. The complete poster stays visible while idle and while playback is starting, then hands over to native controls only after an actual presented frame (or the `playing` event on older engines). Idle previews remain available to the existing snapshot pipeline. Play-button gestures preserve the editor selection and work in read-only documents.

| Changed file | Reason |
| --- | --- |
| `backend/src/video-player.js` | Frame sizing, independent poster, presented-frame handoff, touch-safe play action, native controls, failure handling and selection guards. |
| `backend/src/attachments.js` | Render videos through the framed view and keep its interactions separate from file settings. Audio rendering is unchanged. |
| `backend/src/tiptap.html` | Explicit full-frame dimensions and uncropped poster/video layout, initial play button and block-selection protection. |
| `backend/tests/attachments.test.js` | Cover poster sizing, real video dimensions, frame readiness/cancellation, idle snapshots, playback, missing posters, reopening and unchanged document JSON. |
| `Vellix/Documents/DocumentPreviewContent.swift` | Invalidate stale attachment snapshots so corrected video previews replace them. |
| `backend/dist/tiptap.html`, `backend/dist/tiptap.bundle.js` | Generated editor resources. |
| `Vellix/VellixEditor.bundle/tiptap.html`, `Vellix/VellixEditor.bundle/tiptap.bundle.js` | Synchronized shipping editor resources. |
| `Docs/Attachments.md` | Record the fix, evidence and verification boundary. |

Verification: 156 editor regression tests passed. A temporary Playwright check uses real generated H.264 landscape/portrait files and deliberately withholds video bytes while the poster loads. At 320, 390 and 834 point widths, screenshot pixels prove that both top and bottom poster edges are visible before metadata is available. Touch/mouse playback, decoded-frame handoff, seeking, pausing, reopening, unchanged JSON and the file menu pass without page/console errors or overflow. Screenshots are under `/tmp/penned-video-frame-qa/`. Browser plugin and a headless WebKit installation were unavailable, so checks used the installed Chrome/Playwright runtime and local equivalent byte-range transport, not native WKURLSchemeHandler.

No Penned build, native compilation, app launch or simulator launch was performed. The original iPhone/iPad rendering issue still needs physical-device confirmation. File storage, byte streaming, the audio pill, templates, collections and document persistence were not changed.

References: [Apple's video poster definition](https://developer.apple.com/documentation/webkitjs/htmlvideoelement/1631880-poster), [WebKit first-frame sizing report](https://bugs.webkit.org/show_bug.cgi?id=241789). These explain the native poster/frame distinction; they do not establish that the reported device has that specific WebKit bug.

## Reliable Hold To Delete Every File Type

The earlier file-menu change depended on WebKit delivering `contextmenu`. That did not provide a reliable long press on video or on controls that consume touch events. Every attachment now shares a capture-phase 500 ms hold recognizer, independent of renderer, filename extension and browser context-menu behavior. Holding a video, its initial play button, the active native video surface, an image, PDF, audio pill or ordinary file card opens the existing native menu containing Delete.

Movement, scrolling, multitouch, pointer cancellation, document edits, page switches and block-selection mode cancel pending holds. A completed hold suppresses the release/tap so it cannot start playback, toggle mute or open File Settings behind the Delete menu. Native context menus remain supported and do not duplicate the hold request. Audio scrubbers retain their range interaction rather than arming a hold. Deletion still uses the existing undoable attachment-block command; shared files and undo/snapshot bytes are not deleted.

| Changed file | Reason |
| --- | --- |
| `backend/src/attachment-actions.js` | One capture-phase pointer/touch hold recognizer for all attachment renderers, with cancellation, duplicate-menu protection and release suppression. |
| `backend/src/attachments.js` | Register every attachment host with the shared recognizer and clean up its handlers when the editor is destroyed. |
| `backend/src/tiptap.html` | Disable the competing native image/file touch callout and native text selection inside attachment blocks. No visual changes. |
| `backend/tests/block-actions-runtime.test.js` | Exercise actual holds, deletion and undo across image formats, PDF preview/card, video poster/play/native surface, audio controls, ZIP/TXT/DOCX and card display modes; verify cancellation and other block gestures. |
| `backend/dist/tiptap.html`, `backend/dist/tiptap.bundle.js` | Generated editor resources. |
| `Vellix/VellixEditor.bundle/tiptap.html`, `Vellix/VellixEditor.bundle/tiptap.bundle.js` | Synchronized shipping editor resources. |
| `Docs/Attachments.md` | Record the corrected gesture behavior and verification boundary. |

Verification: 180 editor tests passed. A temporary browser check also performed real touch holds at 390 and 834 point widths on images, PDFs, file cards, audio play/volume controls, the video play button and a decoded video with native controls. All opened one action request, removed the requested attachment through the existing Delete command, retained surrounding text and supported undo. Releasing the hold did not start playback or open File Settings. The browser check uses the shipping bundle with local equivalent file transport; it does not present SwiftUI's native confirmation dialog.

Native menu wiring, storage, persistence, player appearance and protected table/collection behavior were intentionally left unchanged. No Penned app build, native compilation or app/simulator launch was performed; native iPhone/iPad confirmation remains necessary.

## Verification Boundary

Use `PENNED_FULL_APP_TESTS=1 node Scripts/test-collections.mjs` for the headless native tests. Editor runtime tests are under the backend's `tests/`; the browser check runs with `node tests/attachment-browser.mjs`. Its `PLAYWRIGHT_MODULE`, `CHROME_PATH` and screenshot directory can be overridden.

The browser check uses the shipping HTML/JS. Only WebKit's native URL transport is substituted with a local test transport; it is not a test of WKURLSchemeHandler on an iPhone. Native tests compile the actual repositories, bridge/session, previews, sheets and resource handler into the existing macOS harness. iOS editor source also receives a syntax check.

No Penned app build, app launch or simulator launch is part of this verification. Physical iPhone/iPad checks remain necessary for Files-provider permissions, Quick Look SVG/video thumbnail availability, HEIC display, animated GIFs, media codec compatibility/ranged seeking, native clipboard/paste, keyboard behavior and the contextual sheet presentation.

References: [Apple custom resource loading](https://developer.apple.com/documentation/webkit/wkurlschemehandler), [WebKit media range support](https://bugs.webkit.org/show_bug.cgi?id=203302), [TipTap node views](https://tiptap.dev/docs/editor/extensions/custom-extensions/node-views).
