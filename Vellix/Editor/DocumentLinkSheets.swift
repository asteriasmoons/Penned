#if os(iOS)
import SwiftUI
import UIKit

struct DocumentLinkEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @FocusState private var urlFocused: Bool
    @State private var href: String
    @State private var label = ""
    @State private var kind: LinkInsertionKind = .text
    @State private var saving = false
    @State private var error: String?
    let request: DocumentLinkRequest
    let dismissPanel: (() -> Void)?
    let save: (URL?, LinkInsertionKind, String) async throws -> Void

    init(request: DocumentLinkRequest, dismissPanel: (() -> Void)? = nil,
         save: @escaping (URL?, LinkInsertionKind, String) async throws -> Void) {
        self.request = request
        self.dismissPanel = dismissPanel
        self.save = save
        _href = State(initialValue: request.href)
    }

    private var url: URL? {
        let value = DocumentLinkURL.normalize(href)
        return request.isRich || kind == .rich ? value.flatMap { DocumentLinkURL.web($0.absoluteString) } : value
    }

    var body: some View {
        Group {
            if dismissPanel != nil {
                scrollingFields
                .frame(maxWidth: 520)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .overlay {
                    RoundedRectangle(cornerRadius: 24).strokeBorder(VellixSurface.hairline)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.28), radius: 18, y: 5)
            } else {
                scrollingFields
                    .presentationDetents([.height(request.mode == .insert ? (kind == .label ? 302 : 246) : 204)])
                    .presentationDragIndicator(.hidden).presentationBackground(.regularMaterial)
                    .presentationCornerRadius(24).interactiveDismissDisabled(saving)
            }
        }
        .foregroundStyle(VellixSurface.controlInk)
        .tint(PennedSheetStyle.accent)
        .task { urlFocused = true }
        .alert("Could Not Save Link", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var scrollingFields: some View {
        ScrollView { fields }
            .scrollBounceBehavior(.basedOnSize)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Link").font(.system(size: 17, weight: .semibold))
                Spacer()
                if let existing = DocumentLinkURL.openable(request.href) {
                    Menu {
                        Button("Open Link", systemImage: "arrow.up.right") { openURL(existing) }
                        Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.string = existing.absoluteString }
                    } label: {
                        LibraryIcon(name: "dotswavy", size: 19).frame(width: 32, height: 32)
                    }.accessibilityLabel("Link Actions").disabled(saving)
                }
                Button(action: close) {
                    LibraryIcon(name: "xmarkwavy", size: 19).frame(width: 32, height: 32)
                }.buttonStyle(.plain).accessibilityLabel("Close").disabled(saving)
            }
            Divider()
            if request.mode == .insert {
                Picker("Link type", selection: $kind) {
                    ForEach(LinkInsertionKind.allCases) { choice in Text(choice.title).tag(choice) }
                }.pickerStyle(.segmented).disabled(saving)
            }
            TextField("Paste a link e.g., www.google.com", text: $href)
                .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                .autocorrectionDisabled().focused($urlFocused).padding(.horizontal, 12)
                .frame(height: 44).background(VellixSurface.input, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("URL").disabled(saving)
                .submitLabel(.done)
                .onSubmit { if canSave, let url { commit(url) } }
            if request.mode == .insert && kind == .label {
                TextField("Display text", text: $label).padding(.horizontal, 12).frame(height: 44)
                    .background(VellixSurface.input, in: RoundedRectangle(cornerRadius: 8)).disabled(saving)
            }
            HStack(spacing: 10) {
                if request.mode != .insert {
                    Button("Remove") { commit(nil) }
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(VellixSurface.subtleFill, in: Capsule())
                        .foregroundStyle(request.existing ? VellixSurface.controlInk : VellixSurface.disabledInk)
                        .disabled(!request.existing || saving)
                }
                Button { if let url { commit(url) } } label: {
                    Group { if saving { ProgressView().tint(.white) } else { Text("Save").fontWeight(.semibold) } }
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(PennedSheetStyle.accent.opacity(canSave ? 1 : 0.42), in: Capsule())
                        .foregroundStyle(.black)
                }.disabled(!canSave || saving)
            }.buttonStyle(.plain).padding(.top, 4)
        }
        .padding(16).frame(maxWidth: 520).frame(maxWidth: .infinity)
    }

    private var canSave: Bool {
        url != nil && (request.mode != .insert || kind != .label || !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func close() {
        urlFocused = false
        if let dismissPanel { dismissPanel() }
        else { dismiss() }
    }

    private func commit(_ url: URL?) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await save(url, kind, label); close() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct DocumentLinkLayoutSheet: View {
    let link: SelectedDocumentLink
    let select: (RichLinkLayout) async throws -> Void
    @State private var layout: RichLinkLayout
    @State private var updating = false
    @State private var error: String?

    init(link: SelectedDocumentLink, select: @escaping (RichLinkLayout) async throws -> Void) {
        self.link = link
        self.select = select
        _layout = State(initialValue: link.layout)
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(RichLinkLayout.allCases) { choice in
                Button {
                    guard layout != choice, !updating else { return }
                    updating = true
                    Task {
                        defer { updating = false }
                        do { try await select(choice); layout = choice }
                        catch { self.error = error.localizedDescription }
                    }
                } label: {
                    VStack(spacing: 8) {
                        glyph(choice).frame(height: 43).accessibilityHidden(true)
                        Text(choice.title).font(.system(size: 13, weight: .medium))
                    }.frame(maxWidth: .infinity).frame(height: 92)
                        .background(VellixSurface.controlInk.opacity(layout == choice ? 0.14 : 0.065), in: RoundedRectangle(cornerRadius: 5))
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(layout == choice ? PennedSheetStyle.accent : .clear, lineWidth: 1.5) }
                }.buttonStyle(.plain).accessibilityAddTraits(layout == choice ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12).frame(maxWidth: 460).frame(maxWidth: .infinity)
        .foregroundStyle(VellixSurface.controlInk)
        .presentationDetents([.height(124)]).presentationBackground(.regularMaterial)
        .presentationDragIndicator(.visible).presentationCornerRadius(20)
        .alert("Could Not Change Layout", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private func glyph(_ choice: RichLinkLayout) -> some View {
        let small = choice == .small
        if choice == .card {
            VStack(spacing: 0) { thumbnail(width: 45, height: 24); lines(small: false).padding(4) }
                .frame(width: 45).background(VellixSurface.input).clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            HStack(spacing: 4) { thumbnail(width: small ? 18 : 25, height: small ? 15 : 23); lines(small: small).padding(.trailing, 5) }
                .frame(width: 58).background(VellixSurface.input).clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    private func thumbnail(width: CGFloat, height: CGFloat) -> some View {
        AsyncImage(url: link.thumbnail) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { Image(systemName: "photo").font(.system(size: 10)).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(width: width, height: height).clipped().background(VellixSurface.previewPlaceholder)
    }

    private func lines(small: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Capsule().fill(VellixSurface.controlInk.opacity(0.85)).frame(width: 13, height: 2)
            if !small { Capsule().fill(VellixSurface.controlInk.opacity(0.4)).frame(width: 21, height: 1.5) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
