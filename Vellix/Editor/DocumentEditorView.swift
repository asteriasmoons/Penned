//
//  DocumentEditorView.swift
//  Vellix
//

import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct DocumentEditorView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model: EditorCoordinatorModel
    @State private var titleText = ""
    @State private var showSnapshots = false
    @State private var showAppearance = false
    @State private var showIconPicker = false
    @State private var showCalloutIconPicker = false
    @State private var localAppearance = DocumentAppearance.plain
    @State private var localCover: String?
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var editorBackgroundPickerItem: PhotosPickerItem?
    @State private var innerBackgroundPickerItem: PhotosPickerItem?
    @State private var calloutText = ""
    @State private var calloutIcon = "sparkle"
    @State private var calloutIconTargetBlockID: String?
    @State private var selectedCalloutColor = Color.white
    @State private var editorContentHeight: CGFloat = 320
    @State private var selectedBlockCount = 0
    @State private var isEditingDocument = false
    @State private var showSelectedActions = false
    @State private var selectedStylePanel: SelectionStylePanel?

    init(environment: AppEnvironment) {
        _model = StateObject(
            wrappedValue: EditorCoordinatorModel(
                documentRepository: environment.documents,
                snapshotRepository: environment.snapshots
            )
        )
    }

    var body: some View {
        ZStack {
            VellixSurface.appBackground.ignoresSafeArea()

            if let document = model.document {
                documentWorkspace(document)
            } else {
                VellixEmptyState(
                    title: "Choose a page",
                    message: "Open a page from the library or create a new one. The editor will appear here immediately.",
                    systemImage: "doc.text.magnifyingglass",
                    actionTitle: "New Page"
                ) {
                    _ = environment.createDocument()
                }
                .frame(maxWidth: 520)
                .vellixPaper()
                .padding(VellixSpacing.xl)
            }
        }
        .onAppear {
            loadSelectedDocument()
        }
        .onChange(of: environment.selectedDocumentID) { _, _ in
            loadSelectedDocument()
        }
        .onChange(of: model.document?.id) { _, _ in
            syncLocalState()
        }
        .onChange(of: model.document?.title) { _, newValue in
            titleText = newValue ?? ""
        }
        .onChange(of: localAppearance) { _, newValue in
            guard model.document != nil else { return }
            model.updateAppearance(cover: localCover, appearance: newValue)
            environment.refresh()
        }
        .onChange(of: localCover) { _, newValue in
            guard model.document != nil else { return }
            model.updateAppearance(cover: newValue, appearance: localAppearance)
            environment.refresh()
        }
        .onChange(of: coverPickerItem) { _, newValue in
            importPickedImage(newValue, target: .cover)
        }
        .onChange(of: editorBackgroundPickerItem) { _, newValue in
            importPickedImage(newValue, target: .editorBackground)
        }
        .onChange(of: innerBackgroundPickerItem) { _, newValue in
            importPickedImage(newValue, target: .innerBackground)
        }
        .onReceive(model.session.$editorContentHeight) { newHeight in
            editorContentHeight = max(60, min(newHeight, 12_000))
        }
        .onReceive(model.session.$selectedBlockCount) { newCount in
            selectedBlockCount = newCount
            if newCount == 0 {
                selectedStylePanel = nil
            }
        }
        .onReceive(model.session.$isEditing) { isEditing in
            isEditingDocument = isEditing
        }
        .onReceive(model.$calloutIconRequest) { request in
            guard let request else { return }
            calloutIconTargetBlockID = request.blockID
            calloutIcon = request.icon
            showCalloutIconPicker = true
        }
        .onDisappear {
            model.flushPendingSave()
            environment.refresh()
        }
        .sheet(isPresented: $showAppearance) {
            EditorAppearanceSheet(
                appearance: $localAppearance,
                cover: $localCover,
                coverPickerItem: $coverPickerItem,
                editorBackgroundPickerItem: $editorBackgroundPickerItem,
                innerBackgroundPickerItem: $innerBackgroundPickerItem
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showIconPicker) {
            VellixIconLibraryPicker(title: "Page Icon") { icon in
                model.updateIcon(icon.name)
                environment.refresh()
                showIconPicker = false
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCalloutIconPicker) {
            VellixIconLibraryPicker(title: "Callout Icon") { icon in
                calloutIcon = icon.name
                if let calloutIconTargetBlockID {
                    model.session.updateCalloutIcon(blockID: calloutIconTargetBlockID, icon: icon.name)
                } else {
                    model.session.insertCallout(
                        icon: icon.name,
                        text: calloutText.trimmedNonEmpty ?? "",
                        color: selectedCalloutColor.vellixHexString(fallback: "#ffffff")
                    )
                }
                calloutIconTargetBlockID = nil
                showCalloutIconPicker = false
            }
            .presentationDetents([.medium, .large])
            .onDisappear {
                calloutIconTargetBlockID = nil
            }
        }
        .sheet(isPresented: $showSnapshots) {
            SnapshotHistoryView(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSelectedActions) {
            SelectedBlockActionsSheet(
                copyAction: { model.session.copySelectedBlocks() },
                cutAction: { model.session.cutSelectedBlocks() },
                duplicateAction: { model.session.duplicateSelectedBlocks() },
                groupAction: { model.groupSelectedBlocksIntoChildPage() },
                deleteAction: { model.session.deleteSelectedBlocks() }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Editor", isPresented: Binding(
            get: { model.errorMessage != nil || model.session.bridgeErrorMessage != nil },
            set: {
                if !$0 {
                    model.errorMessage = nil
                    model.session.bridgeErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? model.session.bridgeErrorMessage ?? "")
        }
        .vellixHideEditorNavigationBar()
    }

    private func documentWorkspace(_ document: DocumentRecord) -> some View {
        let appearance = localAppearance

        return GeometryReader { proxy in
            let isCompact = proxy.size.width < 620
            let horizontalPadding: CGFloat = appearance.themeID == nil
                ? (isCompact ? 16 : 30)
                : (isCompact ? 8 : 30)
            let topPadding: CGFloat = appearance.themeID == nil
                ? (isCompact ? 146 : 150)
                : (isCompact ? 112 : 150)
            let bottomPadding: CGFloat = isCompact ? 118 : 140

            ZStack {
                DocumentBackgroundLayer(style: appearance.editorBackground, theme: appearance.themeID)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: appearance.themeID == nil ? 0 : 30) {
                        if appearance.themeID == nil {
                            plainDocument(document, appearance: appearance, isCompact: isCompact)
                        } else {
                            themedDocument(document, appearance: appearance, isCompact: isCompact)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, topPadding)
                    .padding(.bottom, bottomPadding)
                }

                EditorTopControls(
                    document: document,
                    isThemed: appearance.themeID != nil,
                    isCompact: isCompact,
                    isSelectionMode: selectedBlockCount > 0
                ) {
                    environment.selectedDocumentID = nil
                } shareAction: {
                    model.session.requestSnapshot()
                } moreAction: {
                    showSnapshots = true
                } selectionDoneAction: {
                    model.session.clearBlockSelection()
                }
                .padding(.horizontal, isCompact ? 18 : 28)
                .padding(.top, isCompact ? 10 : 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if selectedBlockCount > 0 && !isEditingDocument {
                    SelectedBlocksToolbar(
                        styleAction: { selectedStylePanel = .page },
                        actionsAction: { showSelectedActions = true },
                        copyAction: { model.session.copySelectedBlocks() },
                        cutAction: { model.session.cutSelectedBlocks() },
                        duplicateAction: { model.session.duplicateSelectedBlocks() },
                        deleteAction: { model.session.deleteSelectedBlocks() },
                        groupAction: { model.groupSelectedBlocksIntoChildPage() },
                        isCompact: isCompact
                    )
                    .padding(.horizontal, isCompact ? 30 : 34)
                    .padding(.bottom, isCompact ? 14 : 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }

                if let selectedStylePanel, selectedBlockCount > 0 && !isEditingDocument {
                    SelectedBlockStylePanel(
                        panel: selectedStylePanel,
                        isCompact: isCompact,
                        calloutColor: Binding(
                            get: { selectedCalloutColor },
                            set: { newColor in
                                selectedCalloutColor = newColor
                                model.session.setSelectedCalloutColor(
                                    newColor.vellixHexString(fallback: "#ffffff")
                                )
                            }
                        ),
                        headingAction: { model.session.setSelectedBlockType("heading", level: 3) },
                        bodyAction: { model.session.setSelectedBlockType("paragraph") },
                        pageAction: { model.groupSelectedBlocksIntoChildPage() },
                        checklistAction: { model.session.setSelectedBlockType("checkListItem") },
                        toggleAction: { model.session.setSelectedBlockType("toggleListItem") },
                        bulletsAction: { model.session.setSelectedBlockType("bulletListItem") },
                        numbersAction: { model.session.setSelectedBlockType("numberedListItem") },
                        outdentAction: { model.session.outdentSelectedBlocks() },
                        indentAction: { model.session.indentSelectedBlocks() },
                        quoteAction: { model.session.setSelectedBlockType("quote") },
                        calloutAction: {
                            model.session.setSelectedBlockType(
                                "callout",
                                color: selectedCalloutColor.vellixHexString(fallback: "#ffffff")
                            )
                        },
                        showPagePanel: { self.selectedStylePanel = .page },
                        showFormattingPanel: { self.selectedStylePanel = .formatting },
                        showHeadingPanel: { self.selectedStylePanel = .heading },
                        dismissAction: { self.selectedStylePanel = nil }
                    )
                        .padding(.horizontal, isCompact ? 26 : 34)
                        .padding(.bottom, isCompact ? 12 : 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }

                if selectedBlockCount == 0 && !isEditingDocument {
                    EditorFloatingToolbar(
                        appearanceAction: { showAppearance = true },
                        iconAction: { showIconPicker = true },
                        focusAction: { model.session.focus() },
                        insertDividerAction: { model.session.insertDivider($0) },
                        pageBreakAction: { model.session.insertPageBreak() },
                        calloutAction: { showCalloutIconPicker = true },
                        isCompact: isCompact
                    )
                    .padding(.horizontal, isCompact ? 32 : 34)
                    .padding(.bottom, isCompact ? 20 : 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    private func plainDocument(_ document: DocumentRecord, appearance: DocumentAppearance, isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            TextField("Untitled", text: $titleText)
                .font(.system(size: isCompact ? 34 : 42, weight: .bold, design: appearance.fontStyle.design))
                .foregroundStyle(Color(vellixHex: appearance.textColorHex))
                .textFieldStyle(.plain)
                .onSubmit {
                    model.rename(title: titleText)
                    environment.refresh()
                }

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)

            editorSurface(
                document: document,
                appearance: appearance,
                isCompact: isCompact,
                minimumHeight: isCompact ? 64 : 110
            )
        }
        .frame(maxWidth: 900, alignment: .leading)
    }

    private func themedDocument(_ document: DocumentRecord, appearance: DocumentAppearance, isCompact: Bool) -> some View {
        VStack(spacing: model.children.isEmpty ? 0 : 28) {
            VStack(alignment: .leading, spacing: 32) {
                coverView(document: document, appearance: appearance, isCompact: isCompact)

                HStack(alignment: .center) {
                    TextField("Untitled", text: $titleText)
                        .font(.system(size: isCompact ? 28 : 42, weight: .bold, design: appearance.fontStyle.design))
                        .foregroundStyle(Color(vellixHex: appearance.textColorHex))
                        .textFieldStyle(.plain)
                        .onSubmit {
                            model.rename(title: titleText)
                            environment.refresh()
                        }

                    Spacer()

                    Button {
                        showIconPicker = true
                    } label: {
                        IconTile(systemName: document.icon, size: isCompact ? 38 : 42, tint: Color(vellixHex: appearance.themeID?.accentHex ?? "#8FE9FF"))
                    }
                    .buttonStyle(.plain)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)

                if !model.children.isEmpty {
                    ThemedChildPages(children: model.children, appearance: appearance)
                }

                editorSurface(
                    document: document,
                    appearance: appearance,
                    isCompact: isCompact,
                    minimumHeight: isCompact ? 68 : 118
                )
            }
            .padding(.horizontal, isCompact ? 16 : 28)
            .padding(.top, isCompact ? 16 : 28)
            .padding(.bottom, isCompact ? 28 : 36)
            .background(DocumentBackgroundLayer(style: appearance.innerPageBackground, theme: nil))
            .clipShape(RoundedRectangle(cornerRadius: isCompact ? 22 : 30, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: isCompact ? 22 : 30, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.42), radius: 34, x: 0, y: 18)

            if !model.children.isEmpty {
                ThemedInnerPagePreview(appearance: appearance, children: model.children)
            }
        }
        .frame(maxWidth: isCompact ? .infinity : 900)
    }

    private func editorSurface(
        document: DocumentRecord,
        appearance: DocumentAppearance,
        isCompact: Bool,
        minimumHeight: CGFloat
    ) -> some View {
        let height = max(editorContentHeight, minimumHeight)
        let showInstantPreview = !model.instantPreviewBlocks.isEmpty
            && model.session.renderedDocumentID != document.id
            && (model.session.isLoadingDocument || !model.session.isReady)

        return ZStack(alignment: .topLeading) {
            BlockNoteWebView(
                session: model.session,
                documentID: document.id,
                canonicalJSON: document.blockNoteJSON
            )
            .opacity(showInstantPreview ? 0.01 : 1)

            if showInstantPreview {
                InstantDocumentPreviewView(
                    blocks: model.instantPreviewBlocks,
                    appearance: appearance,
                    isCompact: isCompact
                )
                .transaction { transaction in
                    transaction.animation = nil
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(height: height, alignment: .topLeading)
    }

    private func coverView(document: DocumentRecord, appearance: DocumentAppearance, isCompact: Bool) -> some View {
        ZStack {
            if let localCover {
                StoredAttachmentImage(relativePath: localCover, contentMode: .fill)
            } else {
                ThemeCoverArt(theme: appearance.themeID ?? .lunarClouds)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.78, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 8 : 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 8 : 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func loadSelectedDocument() {
        model.load(documentID: environment.selectedDocumentID)
        editorContentHeight = 320
        selectedBlockCount = 0
        isEditingDocument = false
        showSelectedActions = false
        selectedStylePanel = nil
        syncLocalState()
    }

    private func syncLocalState() {
        guard let document = model.document else {
            titleText = ""
            localAppearance = .plain
            localCover = nil
            return
        }

        titleText = document.title
        localAppearance = document.appearance
        localCover = document.cover
    }

    private func importPickedImage(_ item: PhotosPickerItem?, target: PickedImageTarget) {
        guard let item, let document = model.document else {
            return
        }

        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    return
                }

                let record = try environment.attachments.importData(
                    data,
                    originalFileName: "\(target.filePrefix)-\(UUID().uuidString).jpg",
                    mimeType: "image/jpeg",
                    documentID: document.id
                )

                await MainActor.run {
                    switch target {
                    case .cover:
                        localCover = record.relativePath
                        coverPickerItem = nil
                    case .editorBackground:
                        localAppearance.editorBackground = .image(path: record.relativePath)
                        editorBackgroundPickerItem = nil
                    case .innerBackground:
                        localAppearance.innerPageBackground = .image(path: record.relativePath)
                        innerBackgroundPickerItem = nil
                    }
                }
            } catch {
                await MainActor.run {
                    model.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private enum PickedImageTarget {
    case cover
    case editorBackground
    case innerBackground

    var filePrefix: String {
        switch self {
        case .cover:
            return "cover"
        case .editorBackground:
            return "editor-background"
        case .innerBackground:
            return "inner-background"
        }
    }
}

private enum SelectionStylePanel {
    case page
    case formatting
    case heading
}

private struct InstantDocumentPreviewView: View {
    var blocks: [InstantPreviewBlock]
    var appearance: DocumentAppearance
    var isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 10) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                previewRow(block, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color(vellixHex: appearance.textColorHex))
        .font(.system(size: isCompact ? 16 : 18, weight: .regular, design: appearance.fontStyle.design))
        .lineSpacing(isCompact ? 3 : 4)
    }

    @ViewBuilder
    private func previewRow(_ block: InstantPreviewBlock, index: Int) -> some View {
        switch block.kind {
        case .heading:
            Text(block.text)
                .font(.system(size: headingSize(for: block.level), weight: .bold, design: appearance.fontStyle.design))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, index == 0 ? 0 : 8)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("•")
                    .frame(width: 18, alignment: .center)
                Text(block.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .numbered:
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(index + 1).")
                    .frame(width: 24, alignment: .trailing)
                Text(block.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .checklist:
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: block.checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: isCompact ? 15 : 17, weight: .semibold))
                    .foregroundStyle(Color(vellixHex: appearance.textColorHex).opacity(block.checked ? 0.9 : 0.42))
                Text(block.text)
                    .strikethrough(block.checked)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .quote:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(vellixHex: appearance.textColorHex).opacity(0.36))
                    .frame(width: 3)
                Text(block.text)
                    .font(.system(size: isCompact ? 16 : 18, weight: .semibold, design: appearance.fontStyle.design))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .callout:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: isCompact ? 15 : 17, weight: .semibold))
                Text(block.text)
                    .font(.system(size: isCompact ? 16 : 18, weight: .semibold, design: appearance.fontStyle.design))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .divider:
            Rectangle()
                .fill(Color(vellixHex: appearance.textColorHex).opacity(0.18))
                .frame(height: 1)
                .padding(.vertical, 8)
        case .pageBreak:
            Capsule()
                .stroke(Color(vellixHex: appearance.textColorHex).opacity(0.18), lineWidth: 1)
                .frame(height: 20)
                .padding(.vertical, 6)
        case .paragraph:
            Text(block.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1:
            return isCompact ? 26 : 34
        case 2:
            return isCompact ? 22 : 28
        default:
            return isCompact ? 19 : 22
        }
    }
}

private extension View {
    @ViewBuilder
    func vellixHideEditorNavigationBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

private struct EditorTopControls: View {
    var document: DocumentRecord
    var isThemed: Bool
    var isCompact: Bool
    var isSelectionMode: Bool
    var backAction: () -> Void
    var shareAction: () -> Void
    var moreAction: () -> Void
    var selectionDoneAction: () -> Void

    var body: some View {
        let controlSize: CGFloat = isCompact ? 46 : 68
        let iconSize: CGFloat = isCompact ? 20 : 28

        HStack {
            Button(action: backAction) {
                Image(systemName: "chevron.left")
                    .font(.system(size: iconSize, weight: .semibold))
                    .frame(width: controlSize, height: controlSize)
                    .background(.thinMaterial, in: Circle())
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.14), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.system(size: isCompact ? 16 : 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                Text("Library")
                    .font(.system(size: isCompact ? 12 : 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
            }
            .padding(.leading, isCompact ? 8 : 18)
            .opacity(isThemed && !isCompact ? 0.72 : 0)

            Spacer()

            if isSelectionMode {
                Button(action: selectionDoneAction) {
                    Image(systemName: "checkmark")
                        .font(.system(size: isCompact ? 22 : 30, weight: .semibold))
                        .foregroundStyle(Color(red: 0.78, green: 0.97, blue: 1.0))
                        .frame(width: controlSize, height: controlSize)
                        .background(Color(red: 0.0, green: 0.58, blue: 1.0), in: Circle())
                        .overlay {
                            Circle().stroke(Color.white.opacity(0.16), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: isCompact ? 12 : 18) {
                    Button(action: shareAction) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: isCompact ? 19 : 25, weight: .medium))
                    }
                    Button(action: moreAction) {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: isCompact ? 19 : 25, weight: .medium))
                    }
                }
                .foregroundStyle(.white)
                .frame(height: controlSize)
                .padding(.horizontal, isCompact ? 18 : 28)
                .background(.thinMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1)
                }
            }
        }
        .foregroundStyle(.white)
    }
}

private struct SelectedBlocksToolbar: View {
    var styleAction: () -> Void
    var actionsAction: () -> Void
    var copyAction: () -> Void
    var cutAction: () -> Void
    var duplicateAction: () -> Void
    var deleteAction: () -> Void
    var groupAction: () -> Void
    var isCompact: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isCompact ? 2 : 4) {
                SelectedToolbarItem(title: "Style", systemImage: nil, textIcon: "Aa", tint: Color(red: 0.94, green: 0.67, blue: 1.0), action: styleAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Group", systemImage: "wand.and.stars", textIcon: nil, tint: Color(red: 0.25, green: 0.98, blue: 0.78), action: groupAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Actions", systemImage: "square.and.arrow.up", textIcon: nil, tint: .white.opacity(0.92), action: actionsAction, isCompact: isCompact)
                SelectedToolbarItem(title: "React", systemImage: "face.smiling", textIcon: nil, tint: Color(red: 0.95, green: 0.68, blue: 0.50), action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "Comment", systemImage: "bubble", textIcon: nil, tint: Color(red: 0.98, green: 0.95, blue: 0.54), action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "Assistant", systemImage: "circle.hexagongrid", textIcon: nil, tint: Color(red: 1.0, green: 0.42, blue: 0.86), action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "Writing To...", systemImage: "atom", textIcon: nil, tint: Color(red: 0.94, green: 0.72, blue: 1.0), action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "Edit", systemImage: "character.cursor.ibeam", textIcon: nil, tint: Color(red: 0.76, green: 0.86, blue: 1.0), action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "Copy", systemImage: "doc.on.doc", textIcon: nil, tint: .white.opacity(0.88), action: copyAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Cut", systemImage: "scissors", textIcon: nil, tint: .white.opacity(0.88), action: cutAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Duplicate", systemImage: "rectangle.on.rectangle", textIcon: nil, tint: .white.opacity(0.88), action: duplicateAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Share", systemImage: "square.and.arrow.up", textIcon: nil, tint: .white.opacity(0.88), action: actionsAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Move", systemImage: "arrowshape.turn.up.right", textIcon: nil, tint: .white.opacity(0.78), action: {}, isCompact: isCompact)
                SelectedToolbarItem(title: "More", systemImage: "ellipsis.circle", textIcon: nil, tint: .white.opacity(0.78), action: actionsAction, isCompact: isCompact)
                SelectedToolbarItem(title: "Delete", systemImage: "trash", textIcon: nil, tint: Color(red: 1.0, green: 0.55, blue: 0.62), action: deleteAction, isCompact: isCompact, isDestructive: true)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, isCompact ? 8 : 10)
            .padding(.vertical, isCompact ? 6 : 8)
        }
        .frame(maxWidth: isCompact ? .infinity : 720)
        .frame(height: isCompact ? 88 : 102)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: isCompact ? 24 : 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 24 : 28, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 30, x: 0, y: 14)
    }
}

private struct SelectedToolbarItem: View {
    var title: String
    var systemImage: String?
    var textIcon: String?
    var tint: Color
    var action: () -> Void
    var isCompact: Bool
    var isDestructive = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                if let textIcon {
                    Text(textIcon)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 24, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.white.opacity(0.42))
            }
            .foregroundStyle(tint)
            .frame(width: isCompact ? 74 : 88, height: isCompact ? 70 : 80)
            .background(Color.white.opacity(isDestructive ? 0.055 : 0.001))
            .clipShape(RoundedRectangle(cornerRadius: isCompact ? 17 : 21, style: .continuous))
            .overlay {
                if isDestructive {
                    RoundedRectangle(cornerRadius: isCompact ? 17 : 21, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SelectedBlockStylePanel: View {
    var panel: SelectionStylePanel
    var isCompact: Bool
    @Binding var calloutColor: Color
    var headingAction: () -> Void
    var bodyAction: () -> Void
    var pageAction: () -> Void
    var checklistAction: () -> Void
    var toggleAction: () -> Void
    var bulletsAction: () -> Void
    var numbersAction: () -> Void
    var outdentAction: () -> Void
    var indentAction: () -> Void
    var quoteAction: () -> Void
    var calloutAction: () -> Void
    var showPagePanel: () -> Void
    var showFormattingPanel: () -> Void
    var showHeadingPanel: () -> Void
    var dismissAction: () -> Void

    var body: some View {
        VStack(spacing: isCompact ? 14 : 18) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 38, height: 5)

            switch panel {
            case .page:
                pagePanel
            case .formatting:
                formattingPanel
            case .heading:
                headingPanel
            }
        }
        .padding(.horizontal, isCompact ? 14 : 18)
        .padding(.top, 8)
        .padding(.bottom, isCompact ? 14 : 18)
        .frame(maxWidth: isCompact ? .infinity : 720)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: isCompact ? 24 : 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 24 : 28, style: .continuous)
                .stroke(Color(red: 0.21, green: 0.72, blue: 1.0).opacity(0.38), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.46), radius: 32, x: 0, y: 16)
        .gesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    guard value.translation.height > 34 else { return }
                    advancePanel()
                }
        )
    }

    private var pagePanel: some View {
        VStack(spacing: isCompact ? 14 : 18) {
            HStack(spacing: 0) {
                panelTab("Heading", selected: false, action: headingAction)
                divider()
                panelTab("Body", selected: false, action: bodyAction)
                divider()
                panelTab("Page", selected: true, icon: "doc.text", action: pageAction)
                panelTab("More...", selected: false, action: showHeadingPanel)
            }

            HStack(spacing: isCompact ? 8 : 12) {
                styleSquare("checkmark.square", action: checklistAction)
                styleSquare("chevright", assetImage: true, action: toggleAction)
                styleSquare("list.bullet", action: bulletsAction)
                styleSquare("list.number", action: numbersAction)
                styleSquare("decrease.indent", action: outdentAction)
                styleSquare("increase.indent", action: indentAction)
            }

            HStack(spacing: isCompact ? 10 : 14) {
                styleWide("Quote", systemImage: "quote.opening", action: quoteAction)
                styleWide("Callout", systemImage: "sparkles", selected: false, action: calloutAction)
                calloutColorPicker
                styleSquare("ellipsis", selected: true, action: showFormattingPanel)
                    .frame(width: isCompact ? 58 : 70)
            }
        }
    }

    private var formattingPanel: some View {
        VStack(spacing: isCompact ? 14 : 18) {
            HStack(spacing: isCompact ? 8 : 12) {
                styleSquare("bold", selected: true)
                styleSquare("italic")
                styleSquare("strikethrough")
                styleSquare("chevron.left.forwardslash.chevron.right")
                styleSquare("text.alignleft")
                styleSquare("text.aligncenter")
                styleSquare("text.alignright")
                styleSquare("text.justify")
            }

            HStack(spacing: isCompact ? 8 : 10) {
                fontTile("Aa", title: "System", selected: true)
                fontTile("Ss", title: "Serif")
                fontTile("00", title: "Mono")
                fontTile("Rr", title: "Round")
            }

            HStack(spacing: isCompact ? 10 : 12) {
                styleWide("Copy Format", systemImage: "doc.on.doc")
                styleWide("Paste Format", systemImage: "doc.on.clipboard", disabled: true)
            }
        }
    }

    private var headingPanel: some View {
        VStack(spacing: isCompact ? 14 : 18) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                headingOption("Title", weight: .bold)
                headingOption("Subtitle", weight: .semibold)
                headingOption("Heading", weight: .semibold, opacity: 0.72)
                headingOption("Strong", weight: .bold)
                headingOption("Body", weight: .regular)
                headingOption("Caption", weight: .regular, opacity: 0.52)
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            HStack(spacing: isCompact ? 12 : 16) {
                headingMode("Page", systemImage: "doc.text", selected: true)
                headingMode("Card", systemImage: "rectangle.stack")
                Spacer(minLength: 0)
            }
        }
    }

    private var calloutColorPicker: some View {
        ColorPicker(selection: $calloutColor, supportsOpacity: false) {
            HStack(spacing: 7) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 18, weight: .semibold))
                Text("Color")
                    .font(.system(size: isCompact ? 15 : 17, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.88))
        }
        .frame(width: isCompact ? 112 : 128, height: 56)
    }

    private func advancePanel() {
        switch panel {
        case .page:
            showFormattingPanel()
        case .formatting:
            showHeadingPanel()
        case .heading:
            dismissAction()
        }
    }

    private func panelTab(_ title: String, selected: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .font(.system(size: isCompact ? 18 : 22, weight: selected ? .bold : .semibold, design: .rounded))
            .foregroundStyle(selected ? .white : .white.opacity(0.76))
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 46 : 54)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color(red: 0.18, green: 0.78, blue: 1.0), lineWidth: 1.5)
                        }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 34)
    }

    private func styleSquare(
        _ imageName: String,
        assetImage: Bool = false,
        selected: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            styleSquareIcon(imageName, assetImage: assetImage, disabled: disabled)
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 54 : 62)
            .background(Color.white.opacity(selected ? 0.07 : 0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(red: 0.18, green: 0.78, blue: 1.0), lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func styleSquareIcon(_ imageName: String, assetImage: Bool, disabled: Bool) -> some View {
        if assetImage {
            Image(imageName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 23, height: 23)
                .foregroundStyle(disabled ? .white.opacity(0.24) : .white.opacity(0.88))
        } else {
            Image(systemName: imageName)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(disabled ? .white.opacity(0.24) : .white.opacity(0.88))
        }
    }

    private func styleWide(
        _ title: String,
        systemImage: String?,
        selected: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .medium))
                }
                Text(title)
                    .font(.system(size: isCompact ? 17 : 20, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(disabled ? .white.opacity(0.28) : .white.opacity(0.86))
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 56 : 64)
            .background(Color.white.opacity(selected ? 0.09 : 0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func fontTile(_ sample: String, title: String, selected: Bool = false) -> some View {
        VStack(spacing: 5) {
            Text(sample)
                .font(.system(size: isCompact ? 25 : 30, weight: .bold, design: title == "Mono" ? .monospaced : title == "Serif" ? .serif : title == "Round" ? .rounded : .default))
            Text(title)
                .font(.system(size: isCompact ? 11 : 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
        .foregroundStyle(.white.opacity(selected ? 0.92 : 0.72))
        .frame(maxWidth: .infinity)
        .frame(height: isCompact ? 76 : 88)
        .background(Color.white.opacity(selected ? 0.075 : 0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func headingOption(_ title: String, weight: Font.Weight, opacity: Double = 0.92) -> some View {
        Text(title)
            .font(.system(size: isCompact ? 20 : 24, weight: weight, design: .rounded))
            .foregroundStyle(.white.opacity(opacity))
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 50 : 60)
    }

    private func headingMode(_ title: String, systemImage: String, selected: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 23, weight: .medium))
            Text(title)
                .font(.system(size: isCompact ? 19 : 23, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.88))
        .frame(width: isCompact ? 136 : 176, height: isCompact ? 58 : 66)
        .background(Color.white.opacity(selected ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(red: 0.18, green: 0.78, blue: 1.0), lineWidth: 1.5)
            }
        }
    }
}

private struct SelectedBlockActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var copyAction: () -> Void
    var cutAction: () -> Void
    var duplicateAction: () -> Void
    var groupAction: () -> Void
    var deleteAction: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.045).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                Text("Actions")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)

                VStack(spacing: 0) {
                    actionRow("Copy", systemImage: "doc.on.doc", action: copyAction)
                    actionRow("Cut", systemImage: "scissors", action: cutAction)
                    actionRow("Duplicate", systemImage: "rectangle.on.rectangle", action: duplicateAction)
                    actionRow("Group into Sub Page", systemImage: "folder.badge.plus", action: groupAction)
                    sheetDivider()
                    actionRow("Share & Export", systemImage: "square.and.arrow.up", showsChevron: true, action: copyAction)
                    sheetDivider()
                    actionRow("Move to Daily Note", systemImage: "calendar", showsChevron: true, action: {})
                    actionRow("Move to...", systemImage: "arrowshape.turn.up.right.fill", showsChevron: true, action: {})
                    sheetDivider()
                    actionRow("More", systemImage: "ellipsis.circle", showsChevron: true, action: {})
                    actionRow("Delete", systemImage: "trash", destructive: true, action: deleteAction)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        showsChevron: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 18) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .medium))
                    .frame(width: 34)
                Text(title)
                    .font(.system(size: 25, weight: .regular, design: .rounded))
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .foregroundStyle(destructive ? Color(red: 1.0, green: 0.45, blue: 0.52) : .white.opacity(0.88))
            .frame(height: 58)
        }
        .buttonStyle(.plain)
    }

    private func sheetDivider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 7)
    }
}

private struct EditorFloatingToolbar: View {
    var appearanceAction: () -> Void
    var iconAction: () -> Void
    var focusAction: () -> Void
    var insertDividerAction: (VellixDividerStyle) -> Void
    var pageBreakAction: () -> Void
    var calloutAction: () -> Void
    var isCompact: Bool

    var body: some View {
        HStack {
            HStack(spacing: isCompact ? 16 : 26) {
                toolbarButton("arrow.uturn.backward.circle", action: focusAction)
                toolbarButton("paintbrush", action: appearanceAction)
                toolbarButton("pencil", action: focusAction)
            }
            .padding(.horizontal, isCompact ? 18 : 30)
            .frame(height: isCompact ? 54 : 74)
            .background(.thinMaterial, in: Capsule())
            .overlay { Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1) }

            Spacer()

            HStack(spacing: isCompact ? 14 : 24) {
                Button(action: appearanceAction) {
                    ZStack {
                        Circle()
                            .fill(AngularGradient(colors: [.cyan, .blue, .purple, .pink, .orange, .cyan], center: .center))
                        Circle()
                            .fill(Color.black.opacity(0.72))
                            .frame(width: isCompact ? 19 : 26, height: isCompact ? 19 : 26)
                    }
                    .frame(width: isCompact ? 32 : 42, height: isCompact ? 32 : 42)
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        calloutAction()
                    } label: {
                        Label("Callout", systemImage: "quote.bubble")
                    }
                    Button {
                        pageBreakAction()
                    } label: {
                        Label("Page Break", systemImage: "rectangle.split.3x1")
                    }
                    Menu("Divider") {
                        ForEach(VellixDividerStyle.allCases) { style in
                            Button(style.title) {
                                insertDividerAction(style)
                            }
                        }
                    }
                    Button {
                        iconAction()
                    } label: {
                        Label("Page Icon", systemImage: "sparkles")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: isCompact ? 21 : 28, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: isCompact ? 38 : 50, height: isCompact ? 38 : 50)
                        .background(.white, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, isCompact ? 18 : 28)
            .frame(height: isCompact ? 54 : 74)
            .background(.thinMaterial, in: Capsule())
            .overlay { Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1) }
        }
        .shadow(color: .black.opacity(0.42), radius: 26, x: 0, y: 12)
    }

    private func toolbarButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isCompact ? 20 : 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: isCompact ? 26 : 36, height: isCompact ? 38 : 44)
        }
        .buttonStyle(.plain)
    }
}

private struct EditorAppearanceSheet: View {
    @Binding var appearance: DocumentAppearance
    @Binding var cover: String?
    @Binding var coverPickerItem: PhotosPickerItem?
    @Binding var editorBackgroundPickerItem: PhotosPickerItem?
    @Binding var innerBackgroundPickerItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Theme", selection: Binding<DocumentThemeID?>(
                        get: { appearance.themeID },
                        set: { newValue in
                            if newValue == nil {
                                cover = nil
                                coverPickerItem = nil
                                editorBackgroundPickerItem = nil
                                innerBackgroundPickerItem = nil
                            }
                            appearance = DocumentAppearance.defaultForTheme(newValue)
                        }
                    )) {
                        Text("None").tag(DocumentThemeID?.none)
                        ForEach(DocumentThemeID.allCases) { theme in
                            Text(theme.title).tag(Optional(theme))
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if appearance.themeID != nil {
                    Section("Cover") {
                        PhotosPicker(selection: $coverPickerItem, matching: .images) {
                            Label(cover == nil ? "Choose Cover Photo" : "Replace Cover Photo", systemImage: "photo")
                        }
                        if cover != nil {
                            Button("Remove Cover", role: .destructive) {
                                cover = nil
                            }
                        }
                    }

                    Section("Theme Background") {
                        BackgroundStyleEditor(
                            style: $appearance.editorBackground,
                            pickerItem: $editorBackgroundPickerItem
                        )
                    }

                    Section("Inner Page") {
                        BackgroundStyleEditor(
                            style: $appearance.innerPageBackground,
                            pickerItem: $innerBackgroundPickerItem
                        )
                    }
                }

                Section("Text") {
                    ColorPicker("Text Color", selection: Binding(
                        get: { Color(vellixHex: appearance.textColorHex) },
                        set: { appearance.textColorHex = $0.vellixHexString(fallback: appearance.textColorHex) }
                    ))

                    Picker("Font", selection: $appearance.fontStyle) {
                        ForEach(DocumentFontStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .scrollContentBackground(.hidden)
            .background(VellixSurface.appBackground)
            .navigationTitle("Page Style")
        }
    }
}

private struct BackgroundStyleEditor: View {
    @Binding var style: DocumentBackgroundStyle
    @Binding var pickerItem: PhotosPickerItem?

    var body: some View {
        Picker("Type", selection: Binding(
            get: { style.kind },
            set: { newKind in
                switch newKind {
                case .solid:
                    style = .solid(style.colorHex)
                case .gradient:
                    style = .gradient(primary: style.colorHex, secondary: style.secondaryColorHex)
                case .image:
                    style.kind = .image
                }
            }
        )) {
            ForEach(DocumentBackgroundKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)

        ColorPicker("Color", selection: Binding(
            get: { Color(vellixHex: style.colorHex) },
            set: { style.colorHex = $0.vellixHexString(fallback: style.colorHex) }
        ))

        if style.kind == .gradient {
            ColorPicker("Second Color", selection: Binding(
                get: { Color(vellixHex: style.secondaryColorHex) },
                set: { style.secondaryColorHex = $0.vellixHexString(fallback: style.secondaryColorHex) }
            ))
        }

        if style.kind == .image {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label(style.imagePath == nil ? "Choose Image" : "Replace Image", systemImage: "photo.on.rectangle")
            }
        }
    }
}

private struct VellixIconLibraryPicker: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    var onSelect: (VellixAssetIcon) -> Void
    @State private var query = ""

    private var icons: [VellixAssetIcon] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return VellixAssetIconLibrary.all
        }

        return VellixAssetIconLibrary.all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 14)], spacing: 16) {
                    ForEach(icons) { icon in
                        Button {
                            onSelect(icon)
                        } label: {
                            VStack(spacing: 8) {
                                Image(icon.name)
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 34, height: 34)
                                    .foregroundStyle(.white)
                                Text(icon.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .searchable(text: $query)
            .background(VellixSurface.appBackground)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct DocumentBackgroundLayer: View {
    var style: DocumentBackgroundStyle
    var theme: DocumentThemeID?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                switch style.kind {
                case .solid:
                    Color(vellixHex: style.colorHex)
                case .gradient:
                    LinearGradient(
                        colors: [Color(vellixHex: style.colorHex), Color(vellixHex: style.secondaryColorHex)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                case .image:
                    if let imagePath = style.imagePath {
                        StoredAttachmentImage(relativePath: imagePath, contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } else {
                        Color(vellixHex: style.colorHex)
                    }
                }

                if let theme, theme != .custom {
                    ThemePatternOverlay(theme: theme)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}

private struct ThemePatternOverlay: View {
    var theme: DocumentThemeID

    var body: some View {
        GeometryReader { proxy in
            let columns = max(4, Int(proxy.size.width / 118))
            let rows = max(8, Int(proxy.size.height / 86))
            let asset = theme == .lunarClouds ? "rainbowclouds" : "codewindow"

            ZStack {
                ForEach(0..<rows, id: \.self) { row in
                    ForEach(0..<columns, id: \.self) { column in
                        Image(asset)
                            .resizable()
                            .scaledToFit()
                            .opacity(theme == .lunarClouds ? 0.28 : 0.20)
                            .frame(width: theme == .lunarClouds ? 104 : 92)
                            .position(
                                x: CGFloat(column) * 118 + (row.isMultiple(of: 2) ? 32 : 86),
                                y: CGFloat(row) * 86 + 44
                            )
                    }
                }
            }
            .blur(radius: 1.2)
        }
        .allowsHitTesting(false)
    }
}

private struct ThemeCoverArt: View {
    var theme: DocumentThemeID

    var body: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: coverGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(coverAsset)
                .resizable()
                .scaledToFit()
                .padding(coverPadding)
                .shadow(color: Color(vellixHex: theme.accentHex).opacity(0.55), radius: 26)
        }
    }

    private var coverGradient: [Color] {
        switch theme {
        case .custom:
            return [Color(vellixHex: "#121416"), Color(vellixHex: "#2A2B31")]
        case .lunarClouds:
            return [Color(vellixHex: "#09213A"), Color(vellixHex: "#6928A8")]
        case .neonCode:
            return [Color.black, Color(vellixHex: "#061B1B"), Color(vellixHex: "#160B28")]
        }
    }

    private var coverAsset: String {
        switch theme {
        case .custom, .lunarClouds:
            return "moonzs"
        case .neonCode:
            return "codewindow"
        }
    }

    private var coverPadding: CGFloat {
        switch theme {
        case .custom:
            return 72
        case .lunarClouds:
            return 70
        case .neonCode:
            return 56
        }
    }
}

private struct ThemedChildPages: View {
    @EnvironmentObject private var environment: AppEnvironment
    var children: [DocumentRecord]
    var appearance: DocumentAppearance

    var body: some View {
        VStack(spacing: 14) {
            ForEach(children.prefix(10)) { child in
                Button {
                    environment.select(child)
                } label: {
                    HStack(spacing: 14) {
                        IconTile(systemName: child.icon, size: 52, tint: Color.white.opacity(0.45))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(child.title)
                                .font(.system(size: 24, weight: .bold, design: appearance.fontStyle.design))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(child.previewText)
                                .font(.system(size: 19, weight: .medium, design: appearance.fontStyle.design))
                                .foregroundStyle(.white.opacity(0.38))
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ThemedInnerPagePreview: View {
    var appearance: DocumentAppearance
    var children: [DocumentRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Class Notes")
                .font(.system(.title3, design: appearance.fontStyle.design).weight(.bold))
                .foregroundStyle(Color(vellixHex: appearance.textColorHex))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                ForEach(children.prefix(4)) { child in
                    ZStack(alignment: .topLeading) {
                        DocumentBackgroundLayer(style: appearance.editorBackground, theme: appearance.themeID)
                        Text(child.title)
                            .font(.system(size: 24, weight: .bold, design: appearance.fontStyle.design))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .padding(18)
                    }
                    .aspectRatio(1.05, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(26)
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct StoredAttachmentImage: View {
    @EnvironmentObject private var environment: AppEnvironment
    var relativePath: String
    var contentMode: ContentMode
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                platformImage(image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.black
            }
        }
        .clipped()
        .task(id: relativePath) {
            let url = environment.attachmentStore.fileURL(relativePath: relativePath)
            guard let data = try? Data(contentsOf: url) else {
                image = nil
                return
            }
            image = PlatformImage(data: data)
        }
    }

    @ViewBuilder
    private func platformImage(_ image: PlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #elseif canImport(AppKit)
        Image(nsImage: image)
        #endif
    }
}

#if canImport(UIKit)
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
private typealias PlatformImage = NSImage
#endif

private struct SnapshotHistoryView: View {
    @ObservedObject var model: EditorCoordinatorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.snapshots.isEmpty {
                    Text("No snapshots yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshots) { snapshot in
                        Button {
                            model.restore(snapshot)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snapshot.reason.capitalized)
                                    .font(.headline)
                                Text(snapshot.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Revision \(snapshot.revision)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(VellixSurface.appBackground)
            .navigationTitle("Snapshots")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct DocumentInspectorView: View {
    @EnvironmentObject private var environment: AppEnvironment
    var document: DocumentRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VellixSpacing.md) {
                if let document {
                    InspectorCard(title: "Page") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112))], spacing: VellixSpacing.sm) {
                            MetadataTile(title: "Created", value: document.createdAt.formatted(date: .abbreviated, time: .omitted))
                            MetadataTile(title: "Updated", value: document.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            MetadataTile(title: "Revision", value: "\(document.revision)")
                            MetadataTile(title: "Words", value: "\(document.wordCount)")
                            MetadataTile(title: "Characters", value: "\(document.characterCount)")
                            MetadataTile(title: "Location", value: document.folderID == nil ? "Library" : "Folder")
                        }
                    }
                    InspectorCard(title: "Recovery") {
                        let count = (try? environment.snapshots.history(documentID: document.id).count) ?? 0
                        MetadataTile(title: "Snapshots", value: "\(count)")
                    }
                } else {
                    Text("No page selected.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(VellixSpacing.md)
        }
        .frame(minWidth: 284)
        .background(VellixSurface.sidebar)
    }
}

private extension Color {
    func vellixHexString(fallback: String) -> String {
        #if canImport(UIKit)
        let color = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return fallback
        }
        #elseif canImport(AppKit)
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return fallback
        }
        let red = color.redComponent
        let green = color.greenComponent
        let blue = color.blueComponent
        #endif

        return String(
            format: "#%02X%02X%02X",
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255)
        )
    }
}
