//
//  VellixDesignSystem.swift
//  Vellix
//

import SwiftUI

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
    static let appBackground = Color(red: 10 / 255, green: 11 / 255, blue: 11 / 255)
    static let sidebar = Color(red: 0.055, green: 0.06, blue: 0.06)
    static let paper = Color(red: 0.105, green: 0.108, blue: 0.108)
    static let paperLifted = Color(red: 0.145, green: 0.148, blue: 0.148)
    static let ink = Color(red: 0.965, green: 0.965, blue: 0.945)
    static let secondaryInk = Color(red: 0.56, green: 0.57, blue: 0.55)
    static let hairline = Color.white.opacity(0.09)
    static let accent = Color(red: 0.55, green: 0.86, blue: 1.0)
    static let teal = Color(red: 0.25, green: 0.94, blue: 0.82)
    static let coral = Color(red: 0.94, green: 0.46, blue: 0.58)
    static let gold = Color(red: 1.0, green: 0.78, blue: 0.32)
    static let violet = Color(red: 0.72, green: 0.44, blue: 1.0)
}

struct VellixBackground: View {
    var body: some View {
        ZStack {
            VellixSurface.appBackground
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.03, blue: 0.03).opacity(0.85),
                    VellixSurface.appBackground,
                    Color(red: 0.03, green: 0.02, blue: 0.04).opacity(0.9)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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
                    .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
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
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: VellixRadius.sm, style: .continuous))
    }
}

extension View {
    func vellixPaper(cornerRadius: CGFloat = VellixRadius.lg) -> some View {
        background(VellixSurface.paper, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(VellixSurface.hairline, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.38), radius: 18, x: 0, y: 10)
    }
}
