# Native Mac window blur

The Mac workspace, Settings window, and Style Gallery now use the same
native AppKit behind-window material. It renders dark in Penned's default
Dark appearance. Existing Light and System choices still work, and macOS
controls active-window and accessibility behavior. There are no custom
blur filters, tints, transforms, or stacked backdrops on the window.

- `PennedMac/Appearance/MacWindowAppearance.swift`: Uses an
  `NSVisualEffectView` with the native `underWindowBackground` material.
  The host window is cleared when the view attaches, and the existing
  appearance preference still sets the window's AppKit appearance.
- `PennedMac/PennedMacApp.swift`: Applies the material to all workspace
  windows and to Settings at the scene root.
- `PennedMac/App/MacApplicationModel.swift`: Removes the workspace's solid
  fill so the material also shows during library loading or errors.
- `PennedMac/Workspace/MacNavigationSidebar.swift` and
  `PennedMac/Inspector/MacDocumentInspector.swift`: Use the window material
  directly rather than adding separate pane materials.
- `PennedMac/Browser/MacDocumentBrowser.swift` and
  `PennedMac/Browser/MacCalendarBrowser.swift`: Uncover the window material
  behind library galleries, document and tag lists, Calendar, and Tasks.
- `PennedMac/Settings/MacSettingsView.swift`,
  `PennedMac/Settings/MacDailyNotesSettings.swift`, and
  `PennedMac/Settings/MacSpaceControls.swift`: Uncover the same material
  behind Settings panes and the Daily Notes and Spaces lists.
- `PennedMac/Inspector/MacStyleGallery.swift`: Gives the separate Style
  Gallery panel the same material and appearance preference.
- `PennedMac/Editor/MacDocumentEditorContainer.swift`: Shows the window
  material around default document paper. Custom backdrops and page
  surfaces still render as saved.
- `PennedMac/Support/MacCustomControls.swift` and
  `PennedMac/Support/MacPrompt.swift`: Let native presentation material
  show through Mac forms and prompts instead of painting them solid.

Document colors, preview cards, and sheet layouts are unchanged. No shared
sheet styling, mobile source, or editor bundle was edited. No build, test,
or launch was run. Visually check the Mac windows and sheets in Dark mode
with another window behind them to verify the blur and text contrast.
