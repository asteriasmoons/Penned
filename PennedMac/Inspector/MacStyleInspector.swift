import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacStyleInspector: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var model: DocumentEditorModel
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    @State private var saveStyle = false
    @State private var styleName = ""
    @State private var currentStyleName = "Document Style"
    private var definition: DocumentStyleDefinition { .init(appearance: model.appearance, cover: model.document?.cover) }
    var body: some View {
        VStack(spacing: 14) {
            DocumentStyleThumbnail(title: currentStyleName, definition: definition, store: environment.attachmentStore)
                .frame(height: 156).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Style Gallery") { workspace.styleGalleryVisible = true }
                Spacer()
                Button("Save Style") { styleName = ""; saveStyle = true }
            }.controlSize(.small)
            MacInspectorSectionHeader(title: "Color")
            MacBackgroundControls(title: "Backdrop", selection: background(\.editorBackground, field: .backdrop), importImage: { chooseImage(.backdrop) })
            MacBackgroundControls(title: "Document", selection: background(\.innerPageBackground, field: .paper), importImage: { chooseImage(.paper) })
            MacColorRow(title: "Text Color", selection: Binding(get: { Color(vellixHex: model.appearance.resolved(for: colorScheme).textColorHex) }, set: { color in
                update { $0.textColorHex = color.vellixHexString(fallback: model.appearance.textColorHex); $0.markCustomized(.text) }
            }))
            MacInspectorSectionHeader(title: "Cover")
            Toggle("Show Cover", isOn: Binding(get: { model.appearance.displaysCover }, set: { value in
                update { $0.showsCover = value; if value && $0.coverThemeID == nil { $0.coverThemeID = $0.resolvedCoverTheme } }
            }))
            HStack {
                Button("Choose Image") { chooseImage(nil) }
                Spacer()
                Button("Remove", role: .destructive) { model.updateAppearance(cover: nil, appearance: model.appearance) }.disabled(model.document?.cover == nil)
            }.controlSize(.small)
            MacInspectorSectionHeader(title: "Typography")
            MacFontOptions(selection: Binding(get: { model.appearance.fontStyle }, set: { font in update { $0.fontStyle = font } }))
            MacInspectorSectionHeader(title: "Separator")
            HStack(spacing: 6) {
                ForEach(VellixDividerStyle.allCases) { style in
                    Button { model.session.insertDivider(style) } label: {
                        Group {
                            if style == .thinLine || style == .thickLine { Rectangle().frame(height: style == .thinLine ? 1 : 3) }
                            else { HStack(spacing: 4) { ForEach(0..<(style == .fourCircles ? 4 : 7), id: \.self) { _ in Circle().frame(width: 3, height: 3) } } }
                        }.foregroundStyle(VellixSurface.ink).padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 30)
                            .background(VellixSurface.subtleFill, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).help("Insert " + style.title).accessibilityLabel("Insert " + style.title)
                }
            }
            Divider().padding(.vertical, 4)
            Button("Return to Default Appearance") { model.updateAppearance(cover: nil, appearance: .plain) }
                .frame(maxWidth: .infinity)
        }
        .onAppear(perform: identifyStyle)
        .onChange(of: definition) { _, _ in identifyStyle() }
        .macAlert("Save Document Style", isPresented: $saveStyle) {
            TextField("Style Name", text: $styleName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { workspace.perform { _ = try environment.documentStyles.save(title: styleName, definition: definition); identifyStyle() } }
                .disabled(styleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func identifyStyle() {
        let styles = (try? environment.documentStyles.all()) ?? []
        currentStyleName = (try? environment.documentStyles.matchingStyle(definition, in: styles))?.title
            ?? (model.appearance == .plain ? "Default" : "Custom Style")
    }
    private func update(_ change: (inout DocumentAppearance) -> Void) {
        guard workspace.isAuthorized else { return }
        var appearance = model.appearance; change(&appearance)
        model.updateAppearance(cover: model.document?.cover, appearance: appearance)
    }
    private func background(_ keyPath: WritableKeyPath<DocumentAppearance, DocumentBackgroundStyle>, field: DocumentAppearanceField) -> Binding<DocumentBackgroundStyle> {
        Binding(get: { model.appearance.resolved(for: colorScheme)[keyPath: keyPath] }, set: { value in
            update { appearance in
                if field == .backdrop { appearance.customizeBackdrop() }
                if field == .paper { appearance.enableCustomLayout() }
                appearance[keyPath: keyPath] = value; appearance.markCustomized(field)
            }
        })
    }
    private func chooseImage(_ field: DocumentAppearanceField?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        let documentID = model.documentID
        workspace.perform {
            guard await panel.begin() == .OK, let url = panel.url, workspace.isAuthorized,
                  workspace.activeEditor?.documentID == documentID else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let attachment = try environment.documentStyles.importImage(data, documentID: documentID)
            if let field {
                update { appearance in
                    if field == .backdrop { appearance.customizeBackdrop(); appearance.editorBackground = .image(path: attachment.relativePath) }
                    else { appearance.enableCustomLayout(); appearance.innerPageBackground = .image(path: attachment.relativePath) }
                    appearance.markCustomized(field)
                }
            } else {
                var appearance = model.appearance; appearance.showsCover = true
                model.updateAppearance(cover: attachment.relativePath, appearance: appearance)
            }
        }
    }
}

private struct MacBackgroundControls: View {
    let title: String
    @Binding var selection: DocumentBackgroundStyle
    let importImage: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(DocumentBackgroundKind.allCases) { kind in
                    Button { selection.kind = kind } label: {
                        Group {
                            switch kind {
                            case .none: LibraryIcon(name: "eyeslash", size: 16)
                            case .solid: RoundedRectangle(cornerRadius: 3).fill(Color(vellixHex: selection.colorHex)).frame(width: 19, height: 19).overlay(RoundedRectangle(cornerRadius: 3).stroke(VellixSurface.hairline))
                            case .gradient: RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [Color(vellixHex: selection.colorHex), Color(vellixHex: selection.secondaryColorHex)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 19, height: 19)
                            case .image: LibraryIcon(name: "imagesign", size: 17)
                            }
                        }.frame(maxWidth: .infinity).frame(height: 30)
                            .background(selection.kind == kind ? VellixSurface.selection : VellixSurface.subtleFill, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).help(title + ": " + kind.rawValue.capitalized).accessibilityLabel(title + ": " + kind.rawValue.capitalized)
                        .accessibilityAddTraits(selection.kind == kind ? .isSelected : [])
                }
            }
            if selection.kind == .solid || selection.kind == .gradient {
                MacColorRow(title: selection.kind == .gradient ? "Start Color" : "Color", selection: color(\.colorHex))
                if selection.kind == .gradient {
                    MacColorRow(title: "End Color", selection: color(\.secondaryColorHex))
                    MacGradientDirectionControl(selection: Binding(get: { selection.gradientDirection ?? .diagonal }, set: { selection.gradientDirection = $0 }),
                        start: Color(vellixHex: selection.colorHex), end: Color(vellixHex: selection.secondaryColorHex))
                }
            }
            if selection.kind == .image {
                Button("Choose Image", action: importImage).frame(maxWidth: .infinity)
                Toggle("Blur", isOn: Binding(get: { selection.blurImage ?? false }, set: { selection.blurImage = $0 }))
            }
        }.controlSize(.small)
    }
    private func color(_ path: WritableKeyPath<DocumentBackgroundStyle, String>) -> Binding<Color> {
        Binding(get: { Color(vellixHex: selection[keyPath: path]) }, set: { selection[keyPath: path] = $0.vellixHexString(fallback: selection[keyPath: path]) })
    }
}
