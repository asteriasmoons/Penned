import SwiftUI
import AppKit

// Existing Penned appearance and icon controls, isolated for the Mac target.
struct VellixIconLibraryPicker: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    var colorSelection: Binding<Color>?
    var onColorChange: ((Color) -> Void)?
    var onSelect: (VellixAssetIcon) -> Void
    @State private var query = ""
    @State private var selectedCategoryID: String = VellixAssetIconLibrary.categories.first?.id ?? ""
    @State private var isCategoryMenuOpen = false
    @State private var isSystemLibrary = false

    init(
        title: String,
        selectedIcon: String? = nil,
        colorSelection: Binding<Color>? = nil,
        onColorChange: ((Color) -> Void)? = nil,
        onSelect: @escaping (VellixAssetIcon) -> Void
    ) {
        self.title = title
        let usesSymbols = selectedIcon?.hasPrefix("sf:") == true
        _isSystemLibrary = State(initialValue: usesSymbols)
        _selectedCategoryID = State(initialValue: usesSymbols ? VellixSymbolCatalog.categories.first?.id ?? "" : VellixAssetIconLibrary.categories.first?.id ?? "")
        self.colorSelection = colorSelection
        self.onColorChange = onColorChange
        self.onSelect = onSelect
    }

    // Show at most 4 category rows at once; the rest scroll inside the menu.
    private let categoryRowHeight: CGFloat = 46
    private let maxVisibleCategories = 4

    private var categories: [VellixAssetIconCategory] { isSystemLibrary ? VellixSymbolCatalog.categories : VellixAssetIconLibrary.categories }

    private var selectedCategory: VellixAssetIconCategory {
        categories.first { $0.id == selectedCategoryID } ?? categories.first ?? VellixAssetIconCategory(name: "All", icons: [])
    }

    // Only the selected category is loaded into the grid at a time.
    private var icons: [VellixAssetIcon] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return selectedCategory.icons }
        if isSystemLibrary { return VellixSymbolCatalog.search(trimmed) }
        return selectedCategory.icons.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PennedSheetSearchField(text: $query, prompt: isSystemLibrary ? "Search all SF Symbols" : "Search \(selectedCategory.name)")
                    .padding(.horizontal).padding(.bottom, 12)
                if let colorSelection {
                    VellixBlockColorControls(
                        title: "Callout Color",
                        selection: colorSelection,
                        onColorChange: onColorChange
                    )
                    Divider()
                        .padding(.horizontal)
                }

                HStack {
                    MacOptionPicker("Icon Library", selection: $isSystemLibrary, options: [false, true], label: { $0 ? "SF Symbols" : "Penned Icons" })
                    Spacer()
                    if isSystemLibrary { Text("\(VellixSymbolCatalog.symbols.count) symbols").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal).frame(minHeight: 44).pennedSheetField().padding(.horizontal).padding(.top, 10)

                categoryDropdown
                    .padding(.horizontal)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    .zIndex(1)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 14)], spacing: 16) {
                        ForEach(icons) { icon in
                            let symbol = icon.systemName.flatMap { VellixSymbolCatalog.byName[$0] }
                            let available = symbol?.isAvailable ?? true
                            Button {
                                onSelect(icon)
                            } label: {
                                VStack(spacing: 8) {
                                    LibraryIcon(name: available ? icon.name : "sf:questionmark.square.dashed", size: 34)
                                        .foregroundStyle(VellixSurface.controlInk)
                                    Text(icon.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let symbol, !available {
                                        Text("OS \(symbol.requiredVersion)+").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .opacity(available ? 1 : 0.45)
                                .pennedSheetField()
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(VellixSurface.controlInk.opacity(0.08), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!available)
                            .accessibilityLabel(icon.displayName)
                            .accessibilityHint(available ? "Select icon" : "Requires OS \(symbol?.requiredVersion ?? "") or later")
                            .help(icon.displayName)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
            .onChange(of: isSystemLibrary) { _, _ in
                selectedCategoryID = categories.first?.id ?? ""; query = ""; isCategoryMenuOpen = false
            }
            .navigationTitle(title)
            .pennedSheet(title: title, close: { dismiss() })
        }
    }

    private var categoryDropdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isCategoryMenuOpen.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text(selectedCategory.name)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(VellixSurface.ink)
                    Spacer(minLength: 8)
                    Text("\(selectedCategory.icons.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VellixSurface.secondaryInk)
                    Image(isCategoryMenuOpen ? "chevup" : "chevdown")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(VellixSurface.secondaryInk)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .pennedSheetField(cornerRadius: VellixRadius.md)
                .overlay {
                    RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous)
                        .stroke(VellixSurface.hairline, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)

            if isCategoryMenuOpen {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(categories) { category in
                            categoryRow(category)
                            if category.id != categories.last?.id {
                                PennedSheetFieldDivider()
                            }
                        }
                    }
                }
                .frame(maxHeight: categoryRowHeight * CGFloat(maxVisibleCategories))
                .pennedSheetField(cornerRadius: VellixRadius.md)
                .overlay {
                    RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous)
                        .stroke(VellixSurface.hairline, lineWidth: 1)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func categoryRow(_ category: VellixAssetIconCategory) -> some View {
        let isSelected = category.id == selectedCategory.id
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedCategoryID = category.id
                isCategoryMenuOpen = false
            }
            query = ""
        } label: {
            HStack(spacing: 10) {
                Text(category.name)
                    .font(.system(.subheadline, design: .rounded).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? VellixSurface.accent : VellixSurface.ink)
                Spacer(minLength: 8)
                Text("\(category.icons.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(VellixSurface.secondaryInk)
            }
            .padding(.horizontal, 14)
            .frame(height: categoryRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? VellixSurface.controlInk.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VellixBlockColorControls: View {
    enum Layout {
        case stacked, inline, optionEditor
    }

    var title: String
    @Binding var selection: Color
    var onColorChange: ((Color) -> Void)?
    var layout: Layout = .stacked

    private let palette = [
        "#FFFFFF", "#2EC5F4", "#5B8CFF", "#A970FF",
        "#FF5CAA", "#FF9F43", "#FFD84D", "#52D273"
    ]

    private var editableSelection: Binding<Color> {
        Binding(
            get: { selection },
            set: { color in
                selection = color
                onColorChange?(color)
            }
        )
    }

    @ViewBuilder
    var body: some View {
        if layout == .inline {
            HStack(spacing: 8) {
                swatches
                    .frame(minWidth: 0, maxWidth: .infinity)
                customPicker
                    .labelsHidden()
                    .frame(width: 44, height: 44)
            }
        } else if layout == .optionEditor {
            VStack(spacing: 12) {
                swatches
                HStack {
                    Text("Custom Color").font(.body.weight(.medium))
                    Spacer()
                    customPicker.labelsHidden().frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 54)
                .pennedSheetField(cornerRadius: 16)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                swatches
                customPicker.padding(.horizontal, 16).pennedSheetField(cornerRadius: 16)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    private var swatches: some View {
        let selectedHex = selection.vellixHexString(fallback: "#FFFFFF")
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: layout == .optionEditor ? 0 : 4) {
                ForEach(palette, id: \.self) { hex in
                    Button {
                        editableSelection.wrappedValue = Color(vellixHex: hex)
                    } label: {
                        Circle()
                            .fill(Color(vellixHex: hex))
                            .frame(width: layout == .optionEditor ? 36 : 28, height: layout == .optionEditor ? 36 : 28)
                            .overlay {
                                Circle()
                                    .stroke(
                                        VellixSurface.controlInk.opacity(selectedHex.caseInsensitiveCompare(hex) == .orderedSame ? 1 : 0.22),
                                        lineWidth: selectedHex.caseInsensitiveCompare(hex) == .orderedSame ? 3 : 1
                                    )
                            }
                            .overlay {
                                if layout == .optionEditor, selectedHex.caseInsensitiveCompare(hex) == .orderedSame {
                                    Image("checkwavy")
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 14, height: 14)
                                        .foregroundStyle(hex == "#FFFFFF" ? Color.black : Color.white)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(hex)")
                }
            }
        }
        .frame(height: 44)
    }

    private var customPicker: some View {
        MacColorRow(title: "Custom Color", selection: editableSelection)
            .font(.body.weight(.medium))
            .frame(minHeight: 44)
            .accessibilityLabel("Custom \(title.lowercased())")
    }
}

struct ThemePatternOverlay: View {
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
        .accessibilityHidden(true)
    }
}

struct ThemeCoverArt: View {
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

extension Color {
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
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}
