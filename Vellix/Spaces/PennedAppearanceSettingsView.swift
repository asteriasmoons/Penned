import SwiftUI

struct PennedAppearanceSettingsView: View {
    @AppStorage(PennedAppearancePreference.storageKey) private var preference = PennedAppearancePreference.defaultValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Appearance").font(.system(.headline, design: .rounded).weight(.black))
                ForEach(PennedAppearancePreference.allCases) { option in
                    Button { preference = option } label: {
                        HStack(spacing: 14) {
                            LibraryIcon(name: option == .system ? "settings" : "text", size: 21)
                            Text(option.title).frame(maxWidth: .infinity, alignment: .leading)
                            if preference == option { LibraryIcon(name: "checkwavy", size: 21) }
                        }
                        .foregroundStyle(preference == option ? VellixSurface.violet : VellixSurface.ink)
                        .padding(16).frame(minHeight: 52).pennedSheetField()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(preference == option ? .isSelected : [])
                    .accessibilityIdentifier("appearance-" + option.rawValue)
                }
            }
            .font(.system(.body, design: .rounded).weight(.black))
            .padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .background(VellixSurface.appBackground).foregroundStyle(VellixSurface.ink)
        .tint(VellixSurface.violet)
    }
}
