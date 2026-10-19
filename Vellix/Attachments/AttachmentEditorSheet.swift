import SwiftUI
import QuickLook

struct AttachmentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: AttachmentEditorRequest
    let session: TipTapEditorSession
    let editable: Bool
    @State private var mode: String
    @State private var width: Double
    @State private var alignment: String
    @State private var usesOriginalSize: Bool
    @State private var previewURL: URL?
    @State private var error: String?
    @State private var saving = false

    init(request: AttachmentEditorRequest, session: TipTapEditorSession, editable: Bool) {
        self.request = request; self.session = session; self.editable = editable
        _mode = State(initialValue: request.mode)
        _width = State(initialValue: request.width ?? 100)
        _alignment = State(initialValue: request.alignment)
        _usesOriginalSize = State(initialValue: request.width == nil)
    }

    private var file: EditorAttachment? { session.attachmentFiles.first { $0.record.relativePath == request.relativePath } }
    private var originalURL: URL? { try? session.attachmentStore?.validatedFileURL(relativePath: request.relativePath) }
    private var modes: [(String, String)] {
        switch file?.media.kind {
        case .image: [("inline", "Image"), ("fullWidth", "Full Width"), ("card", "Attachment")]
        case .pdf: [("preview", "Preview"), ("card", "Attachment")]
        case .audio, .video: [("player", "Player"), ("card", "Attachment")]
        default: [("card", "Attachment")]
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(file?.record.originalFileName ?? "Attachment unavailable")
                        .pennedSheetRows(showsSeparator: file != nil)
                    if let file {
                        Text(ByteCountFormatter.string(fromByteCount: file.record.fileSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                            .pennedSheetRows(showsSeparator: (file.media.width != nil && file.media.height != nil) || originalURL != nil)
                        if let width = file.media.width, let height = file.media.height {
                            Text("\(width) x \(height)").foregroundStyle(.secondary).pennedSheetRows(showsSeparator: originalURL != nil)
                        }
                    }
                    if let url = originalURL, file != nil {
                        Button("Open Original") { previewURL = url }.pennedSheetRows(showsSeparator: true)
                        ShareLink("Share File", item: url)
                    }
                }.pennedSheetRows()
                if editable, file != nil {
                    Section("Display") {
                        Picker("Display", selection: $mode) {
                            ForEach(modes, id: \.0) { value, title in Text(title).tag(value) }
                        }.pickerStyle(.segmented).pennedSheetRows(showsSeparator: true)
                        if mode != "fullWidth" {
                            Toggle("Original Size", isOn: $usesOriginalSize).pennedSheetRows(showsSeparator: true)
                            if !usesOriginalSize {
                                HStack { Text("Width"); Spacer(); Text("\(Int(width))%") }.pennedSheetRows(showsSeparator: true)
                                Slider(value: $width, in: 10...100, step: 1).accessibilityLabel("File width").pennedSheetRows(showsSeparator: true)
                            }
                        }
                        Picker("Alignment", selection: $alignment) {
                            Text("Left").tag("left"); Text("Center").tag("center"); Text("Right").tag("right")
                        }.pickerStyle(.segmented)
                    }.pennedSheetRows()
                }
                if editable { Section { Button("Remove from Document", role: .destructive) { perform("attachmentDelete") } }.pennedSheetRows() }
                if let error { Text(error).foregroundStyle(.red).pennedSheetRows() }
            }
            .navigationTitle("File")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .pennedSheet(title: "File", close: { dismiss() }) {
                if editable {
                    Button("Save") { perform("attachmentUpdate") }.disabled(saving || file == nil)
                }
            }
            .tint(VellixSurface.accent)
            .quickLookPreview($previewURL)
        }
    }

    private func perform(_ command: String) {
        saving = true
        Task {
            do {
                let result = try await session.attachmentCommand(command, args: ["blockID": request.blockID,
                    "mode": mode, "width": usesOriginalSize ? NSNull() : width as Any, "alignment": alignment])
                guard result as? Bool == true else { throw VellixError.editorBridge("This file block is no longer available.") }
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
