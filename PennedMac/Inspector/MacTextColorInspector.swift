import SwiftUI

struct MacTextColorInspector: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var session: TipTapEditorSession
    @State private var request: InlineTextColorEditorRequest?
    @State private var preparing = false
    @State private var generation = 0
    @State private var errorMessage: String?

    private var isCurrent: Bool { workspace.isAuthorized && workspace.activeEditor?.session === session }
    private var canEdit: Bool { isCurrent && session.isReady && !session.isLoadingDocument && session.editingEnabled && session.selectionMode == "off" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacInspectorSectionHeader(title: "Selected Text Color")
            if let request {
                MacTextColorControls(session: session, request: request, canEdit: canEdit,
                    finished: { close(restoreFocus: true) })
            } else {
                Button(action: begin) {
                    HStack(spacing: 8) {
                        LibraryIcon(name: "paintbrush", size: 17)
                        Text("Change Text Color").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .disabled(preparing || !canEdit || !session.formattingState.canColorText)
                .help("Change the selected text to a solid color or gradient")
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(VellixSurface.coral) }
        }
        .onChange(of: session.formattingState.textColorToken) { _, token in
            if let request, token != request.id {
                close(restoreFocus: false)
                errorMessage = "The text selection changed."
            }
        }
        .onChange(of: canEdit) { _, allowed in if !allowed { close(restoreFocus: false) } }
        .onChange(of: workspace.activeID) { _, _ in close(restoreFocus: false) }
        .onDisappear { close(restoreFocus: false) }
    }

    private func begin() {
        guard canEdit, session.formattingState.canColorText, !preparing else { return }
        preparing = true
        errorMessage = nil
        let capturedGeneration = generation
        Task {
            defer { if generation == capturedGeneration { preparing = false } }
            do {
                guard let next = try await session.beginTextColorEditing() else {
                    if generation == capturedGeneration { errorMessage = "This text selection is no longer available." }
                    return
                }
                guard capturedGeneration == generation, canEdit,
                      next.documentID == workspace.activeEditor?.documentID else {
                    session.endTextColorEditing(requestID: next.id, restoreFocus: false)
                    return
                }
                request = next
            } catch { if generation == capturedGeneration { errorMessage = error.localizedDescription } }
        }
    }

    private func close(restoreFocus: Bool) {
        generation += 1
        let previous = request, wasPreparing = preparing
        request = nil
        preparing = false
        if let previous {
            session.endTextColorEditing(requestID: previous.id, restoreFocus: restoreFocus && isCurrent)
        } else if wasPreparing {
            session.endTextColorEditing(restoreFocus: false)
        }
    }
}

private struct MacTextColorControls: View {
    @ObservedObject var session: TipTapEditorSession
    let request: InlineTextColorEditorRequest
    let canEdit: Bool
    let finished: () -> Void
    @State private var mode: InlineTextColor.Kind
    @State private var start: String
    @State private var end: String
    @State private var angle: Double
    @State private var applying = false
    @State private var errorMessage: String?

    init(session: TipTapEditorSession, request: InlineTextColorEditorRequest, canEdit: Bool, finished: @escaping () -> Void) {
        self.session = session
        self.request = request
        self.canEdit = canEdit
        self.finished = finished
        _mode = State(initialValue: request.initialColor?.kind ?? .solid)
        _start = State(initialValue: request.initialColor?.start ?? "#BC76FF")
        _end = State(initialValue: request.initialColor.flatMap { $0.kind == .gradient ? $0.end : nil } ?? "#FF78B5")
        _angle = State(initialValue: Double(request.initialColor?.angle ?? 90))
    }

    private var color: InlineTextColor? { InlineTextColor(kind: mode, start: start, end: end, angle: Int(angle)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacSegmentedControl("Selected Text Color", selection: $mode, options: InlineTextColor.Kind.allCases,
                label: { $0 == .solid ? "Solid" : "Gradient" })
            preview
            MacColorRow(title: mode == .solid ? "Color Picker" : "Start Color", selection: colorBinding(end: false))
            if mode == .gradient { gradientControls }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(VellixSurface.coral) }
            HStack {
                Button("Cancel", action: finished)
                Spacer(minLength: 4)
                Button("Apply") { if let color { apply(color) } }.disabled(color == nil)
            }
            Button("Default Text Color") { apply(nil) }.frame(maxWidth: .infinity)
        }
        .controlSize(.small).disabled(applying || !canEdit)
    }

    private var preview: some View {
        let text = Text(request.selectedText).font(.system(size: 14, weight: .semibold, design: .rounded))
        return InlineTextColorSample(text: text, color: color, maximumLines: 3)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .padding(.vertical, 4).accessibilityLabel("Selected text preview: " + request.selectedText)
    }

    private var gradientControls: some View {
        VStack(spacing: 10) {
            MacColorRow(title: "End Color", selection: colorBinding(end: true))
            HStack(spacing: 8) {
                Text("Angle").font(.caption)
                MacSlider(value: $angle, in: 0...359, step: 1).tint(VellixSurface.violet)
                    .accessibilityLabel("Text Gradient Angle")
                Text("\(Int(angle))\u{00B0}").font(.system(size: 11, design: .monospaced)).frame(width: 34, alignment: .trailing)
                MacIconButton("Swap Gradient Colors", icon: "repeatarrows") {
                    let previous = start; start = end; end = previous
                }
            }
        }
    }

    private func colorBinding(end isEnd: Bool) -> Binding<Color> {
        Binding(get: { Color(vellixHex: isEnd ? end : start) }, set: { color in
            if isEnd { end = MacColorValue.hex(color) } else { start = MacColorValue.hex(color) }
        })
    }

    private func apply(_ value: InlineTextColor?) {
        guard canEdit, !applying else { return }
        applying = true
        errorMessage = nil
        Task {
            do { try await session.applyTextColor(value, request: request); finished() }
            catch { errorMessage = error.localizedDescription }
            applying = false
        }
    }
}
