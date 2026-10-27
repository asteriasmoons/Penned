//
//  VellixDesignSystem.swift
//  Vellix
//

import SwiftUI

extension Menu {
    func pennedIconMenuStyle() -> some View {
        menuStyle(.button).buttonStyle(.borderless)
    }
}

enum VellixSpacing {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
    static let xxl: CGFloat = 40
}

enum VellixRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 8
    static let lg: CGFloat = 8
}

enum VellixSurface {
    static func secondaryControlInk(opacity: Double) -> Color {
        .penned(light: Color(vellixHex: "#686171"), dark: .white.opacity(opacity))
    }

    static func elevationShadow(opacity: Double) -> Color {
        .penned(light: .black.opacity(opacity * 0.28), dark: .black.opacity(opacity))
    }
    static let workspace = Color.penned(light: Color(vellixHex: "#FAF9FC"), dark: .black)
    static let activeTab = Color.penned(light: .white, dark: .black)
    static let previewPlaceholder = Color.penned(light: Color(vellixHex: "#F0ECF5"), dark: Color(vellixHex: "#303033"))
    static let lilac = Color.penned(light: Color(vellixHex: "#7955A0"), dark: Color(vellixHex: "#B59AD9"))
    static let kanbanPaper = Color.penned(light: Color(vellixHex: "#FCFAFF"), dark: Color(vellixHex: "#2C2C2E"))
    static let appBackground = Color.penned(light: Color(vellixHex: "#FAF9FC"), dark: Color(red: 10 / 255, green: 11 / 255, blue: 11 / 255))
    static let sidebar = Color.penned(light: Color(vellixHex: "#F1EFF6"), dark: Color(red: 0.055, green: 0.06, blue: 0.06))
    static let paper = Color.penned(light: .white, dark: Color(red: 0.105, green: 0.108, blue: 0.108))
    static let paperLifted = Color.penned(light: Color(vellixHex: "#F0EDF5"), dark: Color(red: 0.145, green: 0.148, blue: 0.148))
    static let ink = Color.penned(light: Color(vellixHex: "#211D29"), dark: Color(red: 0.965, green: 0.965, blue: 0.945))
    static let secondaryInk = Color.penned(light: Color(vellixHex: "#686171"), dark: Color(red: 0.56, green: 0.57, blue: 0.55))
    static let controlInk = Color.penned(light: Color(vellixHex: "#272130"), dark: .white)
    static let inverseInk = Color.penned(light: .white, dark: .black)
    static let tertiaryInk = Color.penned(light: Color(vellixHex: "#777080"), dark: Color(vellixHex: "#99949F"))
    static let disabledInk = controlInk.opacity(0.38)
    static let hairline = controlInk.opacity(0.09)
    static let subtleFill = controlInk.opacity(0.06)
    static let selection = Color.penned(light: Color(vellixHex: "#E9DDF8"), dark: .white.opacity(0.08))
    static let input = Color.penned(light: Color(vellixHex: "#F0ECF5"), dark: Color(white: 0.2))
    static let toolbar = Color.penned(light: Color(vellixHex: "#F5F2F9"), dark: Color(red: 0.118, green: 0.118, blue: 0.118))
    static let shadow = Color.penned(light: .black.opacity(0.10), dark: .black.opacity(0.38))
    static let overlay = Color.black.opacity(0.48)
    static let accent = Color.penned(light: Color(vellixHex: "#096E91"), dark: Color(red: 0.55, green: 0.86, blue: 1.0))
    static let teal = Color.penned(light: Color(vellixHex: "#087966"), dark: Color(red: 0.25, green: 0.94, blue: 0.82))
    static let coral = Color.penned(light: Color(vellixHex: "#BD274B"), dark: Color(red: 0.94, green: 0.46, blue: 0.58))
    static let gold = Color.penned(light: Color(vellixHex: "#8D6500"), dark: Color(red: 1.0, green: 0.78, blue: 0.32))
    static let violet = Color.penned(light: Color(vellixHex: "#7833BC"), dark: Color(red: 0.72, green: 0.44, blue: 1.0))
    static let formattingAccent = Color.penned(light: Color(vellixHex: "#7833BC"), dark: Color(red: 0.94, green: 0.67, blue: 1.0))
    static let groupingAccent = Color.penned(light: Color(vellixHex: "#087966"), dark: Color(red: 0.25, green: 0.98, blue: 0.78))
    static let reactionAccent = Color.penned(light: Color(vellixHex: "#9C481A"), dark: Color(red: 0.95, green: 0.68, blue: 0.50))
    static let commentAccent = Color.penned(light: Color(vellixHex: "#856100"), dark: Color(red: 0.98, green: 0.95, blue: 0.54))
    static let assistantAccent = Color.penned(light: Color(vellixHex: "#A12680"), dark: Color(red: 1.0, green: 0.42, blue: 0.86))
    static let writingAccent = Color.penned(light: Color(vellixHex: "#7833BC"), dark: Color(red: 0.94, green: 0.72, blue: 1.0))
    static let editingAccent = Color.penned(light: Color(vellixHex: "#096E91"), dark: Color(red: 0.76, green: 0.86, blue: 1.0))
    static let destructiveAccessory = Color.penned(light: Color(vellixHex: "#BD274B"), dark: Color(red: 1.0, green: 0.55, blue: 0.62))
    static let destructiveLabel = Color.penned(light: Color(vellixHex: "#BD274B"), dark: Color(red: 1.0, green: 0.45, blue: 0.52))
    static let destructiveAction = Color.penned(light: Color(vellixHex: "#BD274B"), dark: Color(vellixHex: "#FF4874"))
}

struct VellixBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        ZStack {
            VellixSurface.appBackground
            if colorScheme == .dark { LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.03, blue: 0.03).opacity(0.85),
                    VellixSurface.appBackground,
                    Color(red: 0.03, green: 0.02, blue: 0.04).opacity(0.9)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ) }
        }
        .ignoresSafeArea()
    }
}

struct IconTile: View {
    var systemName: String?
    var size: CGFloat = 36
    var tint: Color = VellixSurface.accent

    var body: some View {
        RoundedRectangle(cornerRadius: VellixRadius.sm, style: .continuous)
            .fill(tint.opacity(0.11))
            .frame(width: size, height: size)
            .overlay {
                if let systemName, VellixAssetIconLibrary.names.contains(systemName) {
                    Image(systemName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.24)
                        .foregroundStyle(tint)
                } else {
                    Image(systemName: systemName.map { VellixAssetIcon(name: $0).systemName ?? $0 } ?? "doc.text")
                        .font(.system(size: size * 0.43, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: VellixRadius.sm, style: .continuous)
                    .stroke(tint.opacity(0.13), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

struct WorkspacePill: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous)
                .stroke(VellixSurface.hairline, lineWidth: 1)
        }
    }
}

struct SaveStatusIndicator: View {
    var state: TipTapSaveState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(state.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(VellixSurface.hairline, lineWidth: 1)
        }
    }

    private var color: Color {
        switch state {
        case .idle:
            return .secondary
        case .unsaved:
            return VellixSurface.gold
        case .saving:
            return VellixSurface.accent
        case .saved:
            return VellixSurface.teal
        case .failed:
            return .red
        }
    }
}

struct VellixSectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(VellixSurface.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VellixSurface.accent)
            }
        }
    }
}

struct VellixEmptyState: View {
    var title: String
    var message: String
    var systemImage: String
    var actionTitle: String?
    var actionIcon = "plainpencil"
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: VellixSpacing.md) {
            IconTile(systemName: systemImage, size: 52, tint: VellixSurface.accent)
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(actionIcon)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                        Text(actionTitle)
                    }
                    .foregroundStyle(VellixSurface.inverseInk)
                }
                .buttonStyle(.borderedProminent)
                .tint(VellixSurface.controlInk)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(VellixSpacing.xxl)
    }
}

struct InspectorCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: VellixSpacing.md) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(VellixSpacing.md)
        .background(VellixSurface.paper.opacity(0.72), in: RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous)
                .stroke(VellixSurface.hairline, lineWidth: 1)
        }
    }
}

struct MetadataTile: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(VellixSurface.ink)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VellixSpacing.md)
        .background(VellixSurface.subtleFill, in: RoundedRectangle(cornerRadius: VellixRadius.sm, style: .continuous))
    }
}

extension View {
    func vellixPaper(cornerRadius: CGFloat = VellixRadius.lg) -> some View {
        background(VellixSurface.paper, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(VellixSurface.hairline, lineWidth: 1)
            }
            .shadow(color: VellixSurface.shadow, radius: 18, x: 0, y: 10)
    }
}
