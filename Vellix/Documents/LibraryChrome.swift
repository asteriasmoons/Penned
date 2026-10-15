import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct LibraryBrandMark: View {
    var body: some View {
        Group {
            #if os(iOS)
            if let image = Self.appIcon {
                Image(uiImage: image).resizable().scaledToFit()
            } else { Image("moonzs").resizable().scaledToFit() }
            #elseif os(macOS)
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().scaledToFit()
            #endif
        }
        .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Vellix")
    }

    #if os(iOS)
    private static let appIcon: UIImage? = {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let names = primary?["CFBundleIconFiles"] as? [String] ?? []
        return names.reversed().compactMap { UIImage(named: $0) }.first
    }()
    #endif
}

struct LibraryIcon: View {
    var name: String
    var size: CGFloat = 22
    var body: some View {
        let icon = VellixAssetIcon(name: name)
        Group {
            if let symbol = icon.systemName { Image(systemName: symbol).resizable() }
            else { Image(name).renderingMode(.template).resizable() }
        }.scaledToFit().frame(width: size, height: size)
    }
}

enum LibrarySearchScope: String, CaseIterable {
    case keyword = "Keyword"
    case title = "Title"
}

struct LibrarySearchField: View {
    @Binding var query: String
    @Binding var scope: LibrarySearchScope
    var placeholder = "Search"
    var focus: FocusState<Bool>.Binding?
    var body: some View {
        HStack(spacing: 9) {
            LibraryIcon(name: "searchwavy").foregroundStyle(.secondary)
            searchInput
            if !query.isEmpty {
                Button { query = "" } label: { LibraryIcon(name: "xmarkwavy", size: 14) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
            Menu {
                Picker("Search in", selection: $scope) {
                    ForEach(LibrarySearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(scope.rawValue).font(.subheadline)
                    LibraryIcon(name: "chevdown", size: 10)
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(Color.primary.opacity(0.10), in: Capsule())
    }

    @ViewBuilder private var searchInput: some View {
        if let focus {
            TextField(placeholder, text: $query).textFieldStyle(.plain).submitLabel(.search).focused(focus)
        } else {
            TextField(placeholder, text: $query).textFieldStyle(.plain).submitLabel(.search)
        }
    }
}

struct LibraryBottomBar: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        HStack {
            HStack(spacing: 2) {
                destination(.home, icon: "houseoutline")
                destination(.favorites, icon: "starfill")
                destination(.calendar, icon: "mooncal")
            }
            .padding(4).background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Button { environment.focusLibrarySearch() } label: {
                    LibraryIcon(name: "searchwavy").frame(width: 42, height: 44)
                }.accessibilityLabel("Search").help("Search")
                Menu {
                    Button("New Page") {
                        let folder = environment.selectedDestination == .allDocuments ? environment.selectedFolderID : nil
                        _ = environment.createDocument(folderID: folder == "__unsorted" ? nil : folder)
                    }
                    Button("New Folder") { environment.createFolder() }
                    Button("From Template") { navigate(.templates) }
                } label: {
                    LibraryIcon(name: "addwavy", size: 26).frame(width: 42, height: 44)
                }
                .accessibilityLabel("Create").help("Create")
            }
            .padding(4).background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func destination(_ destination: AppDestination, icon: String) -> some View {
        Button { navigate(destination) } label: {
            LibraryIcon(name: icon, size: 25)
                .foregroundStyle(environment.selectedDestination == destination ? (destination == .calendar ? CalendarStyle.accent : VellixSurface.accent) : Color.primary)
                .frame(width: 52, height: 48)
                .background(environment.selectedDestination == destination ? Color.black.opacity(0.35) : .clear, in: Capsule())
        }
        .accessibilityLabel(destination.title).help(destination.title)
    }

    private func navigate(_ destination: AppDestination) {
        environment.selectedFolderID = nil
        environment.selectedDestination = destination
    }
}
