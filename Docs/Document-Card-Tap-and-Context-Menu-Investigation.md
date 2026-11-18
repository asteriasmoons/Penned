# Document Card Taps and Context Menu Interference

**Project:** Penned (Vellix source repository)  
**Platforms investigated:** iPadOS All Docs; related iPhone Home screen behavior  
**Investigation date:** November 8, 2026  
**Status:** iPad All Docs opening restored and confirmed; iPad context menu restored using a different attachment point and subsequently reported fixed. iPhone Home screen context menu arrangement updated; iPhone outcome not yet confirmed in the recorded investigation.

## Summary

Document cards in the iPad **All Docs** gallery visibly responded to touch, but tapping them did not open their documents. The same document could be opened successfully through the iPad sidebar's **Starred** list. Investigation established that the failure occurred **before the document card's SwiftUI `Button` action executed**, rather than inside document navigation, document retrieval, TipTap, or WebKit.

The decisive isolation experiment temporarily removed the card's `.contextMenu` modifier, removed an added diagnostic card gesture, and placed `.contentShape(Rectangle())` on the button label. After those changes, tapping a document opened it successfully. The context menu was then restored **on the visual label inside the `Button`**, instead of on the `Button` itself. The user subsequently reported that the iPad issue was fixed.

This is strong evidence of a **SwiftUI interaction/gesture conflict involving where the context menu was attached**. It does **not** prove a particular internal SwiftUI framework defect or establish that the context menu was the sole cause independent of the other modifiers changed during isolation.

## User-visible symptoms and scope

- iPad All Docs displayed the document gallery, but a normal tap on a document card did not navigate to the editor.
- The same document opened successfully from the sidebar's Starred section.
- An earlier investigation of document previews and rendering had not solved this symptom.
- The problem was **failure to open the page**, not a blank page after editor presentation.
- A related problem remained on the **iPhone homepage**: its document previews also did not open. The homepage used the same outer-button context-menu attachment pattern.

## Relevant code paths

### iPad gallery

`Vellix/Documents/DocumentBrowserView.swift`

The `preview(_ document: DocumentRecord)` function builds a SwiftUI `Button` whose label is `LibraryDocumentPreview`. In normal browsing mode, its action invokes:

```swift
Task {
    do {
        try await workspace.openDocument(document)
    } catch {
        environment.report(error)
    }
}
```

Before isolation, the context menu was attached **after** `.buttonStyle(.plain)`, directly to the `Button`:

```swift
Button {
    // Open document
} label: {
    LibraryDocumentPreview(document: document, visibleHeightFraction: previewHeightFraction)
}
.buttonStyle(.plain)
.contextMenu { DocumentContextMenu(document: document) }
```

### Working iPad sidebar

`Vellix/App/PadWorkspaceSidebar.swift`

The Starred row calls `workspace.openDocument(document)` through its own button action. Both the sidebar and gallery therefore reach the same underlying navigation method when their actions fire.

### Workspace navigation and editor activation

- `Vellix/App/PadWorkspaceModel.swift`: `openDocument`, `transition`, and `apply`.
- `Vellix/App/PadWorkspaceView.swift`: workspace container, disabled state, `PadEditorDeck`, and editor selection.
- `Vellix/Documents/LibraryDocumentPreview.swift`: document card's visual preview.

## Investigation timeline

### 1. Compare working and broken entry points

Opening from the iPad sidebar worked; opening from All Docs did not. Source inspection showed that both paths eventually call `workspace.openDocument(document)`. This shifted attention to the gallery's interaction path **before** navigation.

### 2. Instrument document opening

Diagnostic messages were added with the **exact prefix** `🛠️ PENNED-OPEN` to distinguish them from existing `PENNED-OPEN` messages.

Instrumentation covered:

- All Docs button action and async task start/completion/error.
- Sidebar button action and async task.
- Workspace `openDocument` request and target location.
- Navigation transition entry, busy-state skip, preparation, and completion.
- `apply` selection of the document.
- `PadEditorDeck` selected ID and prepared editor model IDs.

The initial result was telling: tapping All Docs produced **no card-button action log**, while sidebar navigation activated the editor. One sidebar log showed:

```text
🛠️ PENNED-OPEN editor-deck selected=198CE74A-1EED-409C-A130-974D666A7F95 preparedIDs=["198CE74A-1EED-409C-A130-974D666A7F95"]
```

This confirmed that the editor could activate for that document.

### 3. Check whether the gallery receives touches at all

Additional diagnostic taps were attached at the workspace root, browser scroll view, and individual gallery card. Logs also tracked page appearance, document count, gallery dimensions, selection mode, sidebar visibility, and `workspace.isBusy`.

Representative failure trace:

```text
🛠️ PENNED-OPEN apply-start id=nil destination=library(Vellix.AppDestination.allDocuments)
🛠️ PENNED-OPEN workspace-disabled-state busy=false selected=nil pending=nil
🛠️ PENNED-OPEN browser-appear mode=all docs=11 columns=1 width=60.0 workspace=true
🛠️ PENNED-OPEN browser-width mode=all width=60.0 columns=1 cardWidth=Optional(20.0)
🛠️ PENNED-OPEN browser-width mode=all width=820.0 columns=3 cardWidth=Optional(253.33333333333334)
🛠️ PENNED-OPEN workspace-root-tap sidebar=false overlay=true busy=false selected=nil pending=nil
🛠️ PENNED-OPEN browser-scroll-tap mode=all busy=false selecting=false docs=11
🛠️ PENNED-OPEN gallery-card-gesture id=198CE74A-1EED-409C-A130-974D666A7F95 column=2 busy=false
```

**Crucial absence:** there was still no `🛠️ PENNED-OPEN gallery-button-action`.

Interpretation:

- Touches reached the workspace, scroll view, and card's diagnostic gesture.
- The page contained 11 documents.
- The gallery's initial narrow layout resolved to three columns; no evidence established the transient width as the cause.
- Selection mode was off and the workspace was not disabled.
- **The card's SwiftUI `Button` action did not execute.** Navigation was never requested.

### 4. Isolate context-menu and gesture behavior

A controlled interaction change was made in `DocumentBrowserView.swift`:

1. Temporarily removed `.contextMenu { DocumentContextMenu(document: document) }` from the gallery card.
2. Removed the extra `.simultaneousGesture(TapGesture())` diagnostic gesture from the card.
3. Restored normal hit testing for `LibraryDocumentPreview` and placed `.contentShape(Rectangle())` on the button's visual label.

**Result: tapping the All Docs card opened the document.**

Representative successful trace:

```text
🛠️ PENNED-OPEN gallery-button-action id=198CE74A-1EED-409C-A130-974D666A7F95 mode=all selecting=false workspace=true
🛠️ PENNED-OPEN all-docs tap id=198CE74A-1EED-409C-A130-974D666A7F95 busy=false selected=nil
🛠️ PENNED-OPEN all-docs task-start id=198CE74A-1EED-409C-A130-974D666A7F95
🛠️ PENNED-OPEN workspace-request id=198CE74A-1EED-409C-A130-974D666A7F95 busy=false activeTab=EBC7A031-35EE-4E63-B28D-AE038297C386
🛠️ PENNED-OPEN transition-enter busy=false selected=nil
🛠️ PENNED-OPEN transition-prepare-start
🛠️ PENNED-OPEN workspace-disabled-state busy=true selected=nil pending=nil
🛠️ PENNED-OPEN transition-prepare-finished
🛠️ PENNED-OPEN apply-selected id=198CE74A-1EED-409C-A130-974D666A7F95 selected=198CE74A-1EED-409C-A130-974D666A7F95
🛠️ PENNED-OPEN transition-applied selected=198CE74A-1EED-409C-A130-974D666A7F95
🛠️ PENNED-OPEN all-docs task-finished id=198CE74A-1EED-409C-A130-974D666A7F95 selected=198CE74A-1EED-409C-A130-974D666A7F95
🛠️ PENNED-OPEN editor-deck selected=198CE74A-1EED-409C-A130-974D666A7F95 preparedIDs=["198CE74A-1EED-409C-A130-974D666A7F95"]
```

The brief `busy=true` during navigation was expected and did not prevent the successful transition.

### 5. Restore the required context menu

Removing the context menu was diagnostic only; its functionality was required. The original `DocumentContextMenu` was restored **inside the button label**, after the visual label's `.contentShape(Rectangle())`, rather than on the outer SwiftUI `Button`.

The resulting pattern in `DocumentBrowserView.swift` is:

```swift
Button {
    // Existing document selection/open action.
} label: {
    LibraryDocumentPreview(
        document: document,
        visibleHeightFraction: previewHeightFraction
    )
    // Existing selection overlays remain here.
    .contentShape(Rectangle())
    .contextMenu {
        DocumentContextMenu(document: document)
    }
}
.buttonStyle(.plain)
```

**Important terminology:** “outer button” describes the SwiftUI `Button` wrapping the card's visual content; it is **not** an additional visible button. The interface still shows one document card.

The user later stated, **“Okay we fixed that”**, before raising the related iPhone homepage issue. This supports treating the iPad issue as resolved in the conversation, though the record does not include a separate post-restoration iPad log for both single tap and long press.

## Related iPhone homepage investigation

`Vellix/Documents/HomeView.swift` had two document-opening areas using the same attachment pattern:

1. **Recent Documents preview strip**: a horizontal `LazyHStack` of `Button { environment.select(document) }` cards, each showing `LibraryDocumentPreview`, with `.contextMenu` attached to the button.
2. **Starred Documents list**: document rows using `Button { environment.select(document) }` and a `LibraryDocumentPreview` thumbnail plus title, with `.contextMenu` attached to the button.

Both were changed to attach the **existing** `DocumentContextMenu(document: document)` to the **visual label inside the button**. The Recent Documents preview also received `.contentShape(Rectangle())` on its label. The Starred row already had `.contentShape(Rectangle())`.

The existing `environment.select(document)` action was preserved. No new visible controls or context-menu actions were introduced.

**Verification status:** the source edits passed `git diff --check`, but no iPhone device result was supplied after this change. Do not document the iPhone behavior as verified fixed until confirmed on a physical iPhone.

## Root-cause assessment and confidence

**Confirmed:** The iPad All Docs card received touch events, but its SwiftUI button action did not fire in the failing configuration. With the card's context menu temporarily omitted and interaction modifiers adjusted, the action fired and navigation completed successfully.

**Strongly implicated:** Gesture/interaction arbitration around the context menu's attachment to the card's SwiftUI `Button`.

**Not independently established:** Whether moving the context menu alone, without the accompanying gesture and content-shape changes, is sufficient in every configuration; the precise SwiftUI internal mechanism; whether the same issue affects every iPhone homepage document.

**Ruled out for the observed iPad failure path:** a permanently disabled workspace, missing document in the gallery, or a document-opening request that reached `workspace.openDocument` and then failed. The request never started during the failing taps.

## Practical implementation guidance for this codebase

- Keep a document card's **single-tap open action** on its SwiftUI `Button`.
- For the affected gallery and homepage cards, attach `DocumentContextMenu` to the **button label's content**, not directly to the button.
- Keep `.contentShape(Rectangle())` on the intended tappable label area.
- Preserve the existing menu actions and document selection/navigation code.
- When investigating a card that appears tappable but does nothing, distinguish **touch reception**, **button action execution**, **workspace navigation**, and **editor activation** using logs at each boundary.
- A successful tap gesture on a view does **not** imply that its enclosing `Button` action fired.
- Avoid treating a failed tap as a WebKit rendering failure unless navigation actually reached the editor.
- The `🛠️ PENNED-OPEN` instrumentation is diagnostic; it can be removed separately after behavior is confirmed, without changing the fix.
- This investigation was performed with real iPad/iPhone usage; no simulator validation is claimed.

## Files involved

| File | Role |
| --- | --- |
| `Vellix/Documents/DocumentBrowserView.swift` | iPad All Docs card button, label context menu, hit-testing shape, and diagnostics |
| `Vellix/Documents/HomeView.swift` | iPhone Recent and Starred homepage card context-menu placement |
| `Vellix/Documents/LibraryDocumentPreview.swift` | Shared visual preview inside document cards; examined as a possible touch-interception source |
| `Vellix/App/PadWorkspaceSidebar.swift` | Working iPad sidebar opening reference and diagnostics |
| `Vellix/App/PadWorkspaceModel.swift` | Shared navigation path and transition diagnostics |
| `Vellix/App/PadWorkspaceView.swift` | Workspace touch/disabled-state and editor activation diagnostics |

## Scope and preservation notes

The targeted interaction fix did not require changing document records, the TipTap editor, WebKit loading, or the existing context-menu action definitions. Existing uncommitted project work was not intentionally reverted or reset. No claim is made that the app was compiled or that automated tests were run as part of these edits.

---

**Takeaway:** In this case, **the card received touches but the button never acted**. Moving the required context menu from the SwiftUI `Button` to the button's **visual label** preserved the menu while addressing the implicated interaction arrangement. The iPad issue was reported resolved; the analogous iPhone change still requires device confirmation.
