//
//  DocumentBrowserView.swift
//  Vellix
//

import SwiftUI

enum DocumentBrowserMode: Equatable {
    case all
    case today
    case recent
    case favorites
    case trash
    case space(String)
    case folder(String)
    case children(String)

    var title: String {
        switch self {
        case .all:
            return "All Pages"
        case .today:
            return "Today"
        case .recent:
            return "Recents"
        case .favorites:
            return "Starred"
        case .trash:
            return "Trash"
        case .space:
            return "Space"
        case .folder:
            return "Folder"
        case .children:
            return "Child Pages"
        }
    }

    var subtitle: String {
        switch self {
        case .all:
            return "Every page in your local library."
        case .today:
            return "A focused landing spot for what is active now."
        case .recent:
            return "Pages ordered by your latest opens and edits."
        case .favorites:
            return "Pages you pinned for quick return."
        case .trash:
            return "Recover pages or remove them permanently."
        case .space:
            return "Pages inside this space."
        case .folder:
            return "Pages inside this folder."
        case .children:
            return "Pages nested below the current document."
        }
    }
}

struct DocumentBrowserView: View {
    @EnvironmentObject private var environment: AppEnvironment
    var mode: DocumentBrowserMode
    var documents: [DocumentRecord]

    private let columns = [
        GridItem(.adaptive(minimum: 230, maximum: 360), spacing: VellixSpacing.md)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VellixSpacing.xl) {
                browserHeader

                if documents.isEmpty {
                    VellixEmptyState(
                        title: emptyTitle,
                        message: emptyMessage,
                        systemImage: mode == .trash ? "trash" : "doc.badge.plus",
                        actionTitle: mode == .trash ? nil : "Create Page"
                    ) {
                        _ = environment.createDocument()
                    }
                    .frame(minHeight: 440)
                    .vellixPaper()
                } else {
                    LazyVGrid(columns: columns, spacing: VellixSpacing.md) {
                        ForEach(documents) { document in
                            DocumentCard(document: document, style: .paper)
                                .contentShape(RoundedRectangle(cornerRadius: VellixRadius.lg, style: .continuous))
                                .onTapGesture {
                                    environment.select(document)
                                }
                                .contextMenu {
                                    DocumentContextMenu(document: document)
                                }
                        }
                    }
                }
            }
            .padding(VellixSpacing.xl)
        }
        .background(VellixBackground())
        .navigationTitle(mode.title)
        .toolbar {
            if mode != .trash {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        _ = environment.createDocument()
                    } label: {
                        Label("New Page", systemImage: "square.and.pencil")
                    }
                }
            }
        }
    }

    private var browserHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(mode.title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(VellixSurface.ink)
                Text(mode.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(documents.count) \(documents.count == 1 ? "page" : "pages")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.68), in: Capsule())
                .overlay {
                    Capsule().stroke(VellixSurface.hairline, lineWidth: 1)
                }
        }
    }

    private var emptyTitle: String {
        mode == .trash ? "Trash is empty" : "No pages yet"
    }

    private var emptyMessage: String {
        mode == .trash
            ? "Deleted pages stay here until you restore or permanently remove them."
            : "Create a page and Vellix will save your writing locally as you work."
    }
}

struct DocumentCard: View {
    enum Style {
        case compact
        case paper
    }

    var document: DocumentRecord
    var style: Style = .paper

    var body: some View {
        VStack(alignment: .leading, spacing: VellixSpacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    IconTile(systemName: document.icon, size: style == .compact ? 30 : 36, tint: accent)
                    Text(locationText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if document.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(VellixSurface.gold)
                        .accessibilityLabel("Starred")
                }
            }

            VStack(alignment: .leading, spacing: VellixSpacing.xs) {
                Text(document.title)
                    .font(.system(style == .compact ? .headline : .title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(VellixSurface.ink)
                    .lineLimit(2)
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(style == .compact ? 2 : 4)
                    .frame(minHeight: style == .compact ? 38 : 76, alignment: .topLeading)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(updatedText)
                if document.wordCount > 0 {
                    Circle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(width: 3, height: 3)
                    Text("\(document.wordCount) words")
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(style == .compact ? VellixSpacing.md : VellixSpacing.lg)
        .frame(maxWidth: .infinity, minHeight: style == .compact ? 154 : 228, alignment: .topLeading)
        .vellixPaper()
    }

    private var accent: Color {
        if document.isFavorite {
            return VellixSurface.gold
        }
        if document.spaceID != nil {
            return VellixSurface.teal
        }
        if document.parentDocumentID != nil {
            return VellixSurface.violet
        }
        return VellixSurface.accent
    }

    private var preview: String {
        document.previewText == "No content yet" ? "Blank page" : document.previewText
    }

    private var updatedText: String {
        document.updatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var locationText: String {
        if document.isTrashed {
            return "Trash"
        }
        if document.parentDocumentID != nil {
            return "Nested page"
        }
        if document.spaceID != nil {
            return "Space"
        }
        return "Library"
    }
}

struct DocumentContextMenu: View {
    @EnvironmentObject private var environment: AppEnvironment
    var document: DocumentRecord

    var body: some View {
        if document.isTrashed {
            Button {
                environment.restore(document)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                environment.permanentlyDelete(document)
            } label: {
                Label("Delete Permanently", systemImage: "trash.slash")
            }
        } else {
            Button {
                environment.select(document)
            } label: {
                Label("Open", systemImage: "arrow.right")
            }
            Button {
                do {
                    _ = try environment.documents.setFavorite(
                        id: document.id,
                        isFavorite: !document.isFavorite
                    )
                    environment.refresh()
                } catch {
                    environment.report(error)
                }
            } label: {
                Label(document.isFavorite ? "Remove Star" : "Star", systemImage: "star")
            }
            Button {
                do {
                    let duplicate = try environment.documents.duplicate(id: document.id)
                    environment.refresh()
                    environment.select(duplicate)
                } catch {
                    environment.report(error)
                }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                do {
                    _ = try environment.documents.trash(id: document.id)
                    environment.refresh()
                } catch {
                    environment.report(error)
                }
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }
}
