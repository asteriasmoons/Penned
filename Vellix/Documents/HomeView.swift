//
//  HomeView.swift
//  Vellix
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VellixSpacing.xl) {
                hero

                if environment.overview.all.isEmpty {
                    emptyDesk
                } else {
                    topShelf
                    documentShelf(
                        title: "Continue Writing",
                        subtitle: "The pages you touched most recently.",
                        documents: Array(environment.overview.recent.prefix(6)),
                        actionTitle: "All Recents"
                    ) {
                        environment.selectedDestination = .recents
                    }
                    if !environment.overview.favorites.isEmpty {
                        documentShelf(
                            title: "Starred",
                            subtitle: "Pinned where your eyes naturally land.",
                            documents: Array(environment.overview.favorites.prefix(6)),
                            actionTitle: "View Starred"
                        ) {
                            environment.selectedDestination = .favorites
                        }
                    }
                    quickStarts
                }
            }
            .padding(VellixSpacing.xl)
        }
        .background(VellixBackground())
        .navigationTitle("Home")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: VellixSpacing.lg) {
            HStack(alignment: .top, spacing: VellixSpacing.md) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your workspace")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(VellixSurface.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)
                    Text(Date.now.formatted(date: .complete, time: .omitted))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    _ = environment.createDocument(title: "Untitled")
                } label: {
                    Label("New Page", systemImage: "square.and.pencil")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.94), in: Capsule())
                        .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 6)
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: VellixSpacing.md)], spacing: VellixSpacing.md) {
                WorkspacePill(
                    title: "Pages",
                    value: "\(environment.overview.all.count)",
                    systemImage: "doc.text",
                    tint: VellixSurface.accent
                )
                WorkspacePill(
                    title: "Starred",
                    value: "\(environment.overview.favorites.count)",
                    systemImage: "star.fill",
                    tint: VellixSurface.gold
                )
                WorkspacePill(
                    title: "Templates",
                    value: "\(environment.overview.templates.count)",
                    systemImage: "square.on.square",
                    tint: VellixSurface.violet
                )
            }
        }
        .padding(22)
        .vellixPaper()
    }

    private var emptyDesk: some View {
        VellixEmptyState(
            title: "Start with a page",
            message: "Vellix opens into a local writing desk. Create a page and the editor will autosave structured BlockNote JSON to SQLite.",
            systemImage: "doc.badge.plus",
            actionTitle: "Create Page"
        ) {
            _ = environment.createDocument()
        }
        .frame(minHeight: 420)
        .vellixPaper()
    }

    private var topShelf: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: VellixSpacing.md)], spacing: VellixSpacing.md) {
            QuickActionCard(
                title: "Daily Note",
                subtitle: "Open a page for today.",
                systemImage: "calendar.badge.plus",
                tint: VellixSurface.teal
            ) {
                if let template = environment.overview.templates.first(where: { $0.id == "built-in.daily-note" }) {
                    _ = environment.createDocument(title: "Today", from: template)
                } else {
                    _ = environment.createDocument(title: "Today")
                }
            }

            QuickActionCard(
                title: "Blank Page",
                subtitle: "A clean canvas.",
                systemImage: "doc",
                tint: VellixSurface.accent
            ) {
                _ = environment.createDocument(title: "Untitled")
            }

            QuickActionCard(
                title: "Search Library",
                subtitle: "Find text, titles, and templates.",
                systemImage: "magnifyingglass",
                tint: VellixSurface.violet
            ) {
                environment.selectedDestination = .search
            }
        }
    }

    private func documentShelf(
        title: String,
        subtitle: String,
        documents: [DocumentRecord],
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: VellixSpacing.md) {
            VellixSectionHeader(
                title: title,
                subtitle: subtitle,
                actionTitle: actionTitle,
                action: action
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VellixSpacing.md) {
                    ForEach(documents) { document in
                        DocumentCard(document: document, style: .paper)
                            .frame(width: 268)
                            .onTapGesture {
                                environment.select(document)
                            }
                            .contextMenu {
                                DocumentContextMenu(document: document)
                            }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var quickStarts: some View {
        VStack(alignment: .leading, spacing: VellixSpacing.md) {
            VellixSectionHeader(
                title: "Start From A Template",
                subtitle: "Quiet structure when you do not want to stare at an empty page.",
                actionTitle: "All Templates"
            ) {
                environment.selectedDestination = .templates
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: VellixSpacing.md)], spacing: VellixSpacing.md) {
                ForEach(environment.overview.templates.prefix(4)) { template in
                    TemplateCard(template: template) {
                        _ = environment.createDocument(title: template.title, from: template)
                    }
                }
            }
        }
    }
}

struct QuickActionCard: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: VellixSpacing.md) {
                IconTile(systemName: systemImage, tint: tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(VellixSurface.ink)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(VellixSpacing.lg)
            .vellixPaper(cornerRadius: VellixRadius.md)
        }
        .buttonStyle(.plain)
    }
}

struct TemplateCard: View {
    var template: TemplateRecord
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: VellixSpacing.md) {
                HStack {
                    IconTile(systemName: template.icon, tint: templateTint)
                    Spacer()
                    Text(template.category)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(templateTint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(templateTint.opacity(0.10), in: Capsule())
                }
                Text(template.title)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(VellixSurface.ink)
                    .lineLimit(2)
                Text(template.templateDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer(minLength: 0)
            }
            .padding(VellixSpacing.lg)
            .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
            .vellixPaper()
        }
        .buttonStyle(.plain)
    }

    private var templateTint: Color {
        switch template.category {
        case "Planning":
            return VellixSurface.teal
        case "Creative":
            return VellixSurface.coral
        case "Research":
            return VellixSurface.violet
        case "Personal":
            return VellixSurface.gold
        default:
            return VellixSurface.accent
        }
    }
}
