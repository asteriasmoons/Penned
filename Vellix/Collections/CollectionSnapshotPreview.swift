import SwiftUI

// Read-only saved-content rendering for first frames and persisted document previews.
struct CollectionSnapshotPreview: View {
    let snapshot: CollectionSnapshot
    let appearance: DocumentAppearance
    let attachments: AttachmentStore

    var body: some View {
        if let view = snapshot.activeView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(snapshot.name).font(.system(size: 18, weight: .bold, design: appearance.fontStyle.design))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(view.name).font(.system(size: 15)).foregroundStyle(Color(vellixHex: "#B59AD9"))
                    LibraryIcon(name: "chevdown", size: 18).foregroundStyle(Color(vellixHex: "#B59AD9"))
                    LibraryIcon(name: "dotswavy", size: 18)
                }.padding(.horizontal, 8).frame(minHeight: 40)
                switch view.kind {
                case .table: table(view)
                case .gallery: gallery(view)
                case .kanban: kanban(view)
                }
            }
            .font(.system(size: 15, design: appearance.fontStyle.design))
            .foregroundStyle(Color(vellixHex: appearance.textColorHex))
            .allowsHitTesting(false)
        }
    }

    private func table(_ view: CollectionViewRecord) -> some View {
        let fields = snapshot.visibleFields(in: view)
        let entries = Array(snapshot.presentedEntries(in: view).prefix(100))
        return GeometryReader { geometry in
            VStack(spacing: 0) {
                tableRow(title: "Title", fields: fields, entry: nil)
                    .foregroundStyle(Color(vellixHex: "#B59AD9")).background(.white.opacity(0.02))
                ForEach(entries) { entry in
                    tableRow(title: entry.title, fields: fields, entry: entry)
                }
            }.frame(width: geometry.size.width, alignment: .leading).clipped()
        }.frame(height: CGFloat(entries.count + 1) * 48)
    }
    private func tableRow(title: String, fields: [CollectionField], entry: CollectionEntrySummary?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(title).fontWeight(.semibold).frame(width: 196, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
            ForEach(fields) { field in
                Group {
                    if let entry { CollectionValueDisplay(field: field, value: entry.values[field.id] ?? CollectionValue(), ink: Color(vellixHex: appearance.textColorHex)) }
                    else { Label { Text(field.name) } icon: { LibraryIcon(name: field.resolvedIcon, size: 18) } }
                }.frame(width: field.kind == .number || field.kind == .checkbox ? 96 : 156, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }.fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.09)).frame(height: 1) }
    }

    private func gallery(_ view: CollectionViewRecord) -> some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: view.configuration.galleryColumns), spacing: 12) {
                ForEach(Array(snapshot.presentedEntries(in: view).prefix(40))) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        if view.configuration.showsCover { cover(entry) }
                        Text(entry.title).fontWeight(.semibold).lineLimit(3).padding(.horizontal, 10).padding(.top, 6)
                        properties(entry, view: view).padding(.horizontal, 10)
                        HStack { Spacer(); LibraryIcon(name: "dotswavy", size: 18) }.padding(8)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.09), lineWidth: 1))
                }
            }
            LibraryIcon(name: "addwavy", size: 20).foregroundStyle(Color(vellixHex: "#B59AD9")).padding(10)
        }.fixedSize(horizontal: false, vertical: true).frame(maxHeight: 420, alignment: .top).clipped()
    }
    private func cover(_ entry: CollectionEntrySummary) -> some View {
        Color.white.opacity(0.045).aspectRatio(1.78, contentMode: .fit).overlay {
            if entry.appearance.displaysCover {
                if let image = CardImageLoader.image(path: entry.cover, store: attachments) {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else if entry.cover == nil { ThemeCoverArt(theme: entry.appearance.resolvedCoverTheme) }
                else { LibraryIcon(name: "imagesign", size: 24).foregroundStyle(Color(vellixHex: "#B59AD9")) }
            } else { LibraryIcon(name: "imagesign", size: 24).foregroundStyle(Color(vellixHex: "#B59AD9")) }
        }.clipped()
    }

    private func kanban(_ view: CollectionViewRecord) -> some View {
        VStack(spacing: 12) {
            ForEach(snapshot.kanbanGroups(in: view), id: \.column.id) { group in
                VStack(spacing: 9) {
                    HStack(spacing: 8) {
                        LibraryIcon(name: group.column.collapsed ? "chevright" : "chevdown", size: 12)
                        Text(group.column.name).fontWeight(.semibold)
                        Text("\(group.entries.count)").font(.caption).padding(5).background(.black.opacity(0.24), in: Capsule()).foregroundStyle(.white)
                        Spacer(); Image(systemName: "plus")
                    }.frame(minHeight: 36).foregroundStyle(Self.columnInk(group.column.color))
                    if !group.column.collapsed {
                        ForEach(Array(group.entries.prefix(40))) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    Text(entry.title).fontWeight(.medium).lineLimit(3)
                                    Spacer(); LibraryIcon(name: "chevright", size: 11).foregroundStyle(.white.opacity(0.45))
                                }
                                properties(entry, view: view)
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(Color(vellixHex: "#E4E6F1"))
                                .background(Color(vellixHex: "#2C2C2E"), in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.1), lineWidth: 1))
                        }
                        if !group.entries.isEmpty {
                            Image(systemName: "plus").frame(maxWidth: .infinity).frame(height: 34)
                                .foregroundStyle(Self.columnInk(group.column.color))
                                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.padding(10).background(Color(vellixHex: group.column.color), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Self.columnInk(group.column.color).opacity(0.25), lineWidth: 1))
            }
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: CGFloat(CollectionViewConfiguration.kanbanMaxHeight) - 50, alignment: .top).clipped()
    }

    private func properties(_ entry: CollectionEntrySummary, view: CollectionViewRecord) -> some View {
        CollectionChipLayout {
            ForEach(snapshot.visibleFields(in: view)) { field in
                let value = entry.values[field.id] ?? CollectionValue()
                if !value.isEmpty {
                    let options = field.configuration.options.filter { value.optionIDs.contains($0.id) }
                    if options.isEmpty { chip(field.display(value), color: "#87B9D5") }
                    else { ForEach(options) { chip($0.name, color: $0.color) } }
                }
            }
        }
    }
    private func chip(_ text: String, color hex: String) -> some View {
        let color = Color(vellixHex: hex)
        return Text(text).font(.caption2.weight(.medium)).lineLimit(2).padding(.horizontal, 5).padding(.vertical, 2)
            .foregroundStyle(color).background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
    }
    private static func columnInk(_ hex: String) -> Color {
        let rgb = UInt64(hex.dropFirst(), radix: 16) ?? 0
        return 0.299 * Double((rgb >> 16) & 255) + 0.587 * Double((rgb >> 8) & 255) + 0.114 * Double(rgb & 255) > 165
            ? Color(vellixHex: "#181821") : .white
    }
}

struct CollectionFieldsSnapshotPreview: View {
    let snapshot: CollectionSnapshot
    let entry: CollectionEntrySummary
    let appearance: DocumentAppearance
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(snapshot.fields) { field in
                HStack(alignment: .top, spacing: 12) {
                    Label { Text(field.name) } icon: { LibraryIcon(name: field.resolvedIcon, size: 18) }
                        .font(.subheadline.weight(.semibold)).frame(width: 140, alignment: .leading)
                    CollectionValueDisplay(field: field, value: entry.values[field.id] ?? CollectionValue(), ink: Color(vellixHex: appearance.textColorHex))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 44)
            }
        }.foregroundStyle(Color(vellixHex: appearance.textColorHex))
    }
}
