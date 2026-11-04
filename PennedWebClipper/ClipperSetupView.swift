import SwiftUI

private enum ClipperSetupStyle {
    static let background = Color(red: 10 / 255, green: 11 / 255, blue: 11 / 255)
    static let accent = Color(red: 0.72, green: 0.44, blue: 1)
    static let secondary = Color.white.opacity(0.6)
    static let border = Color.white.opacity(0.09)
}

struct ClipperSetupView: View {
    @ObservedObject var model: ClipperSetupModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 14) {
                        Image("ClipperLogo").resizable().scaledToFit().frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                        Text("Penned Web Clipper")
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    connectionSection
                    safariSection
                    instructions
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(ClipperSetupStyle.background.ignoresSafeArea())
            .foregroundStyle(.white)
            .font(.system(.body, design: .rounded))
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.refresh() } } label: { asset("repeatfill", size: 22) }
                        .disabled(model.isRefreshing)
                        .accessibilityLabel("Refresh Connection and Safari Status")
                        .help("Refresh status")
                }
            }
            .refreshable { await model.refresh() }
            .alert("Penned Web Clipper", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
                Button("OK", role: .cancel) { model.actionError = nil }
            } message: { Text(model.actionError ?? "") }
        }
        .tint(ClipperSetupStyle.accent)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Penned Connection", icon: "link")
            switch model.connectionStatus {
            case .checking:
                Text("Checking connection").foregroundStyle(ClipperSetupStyle.secondary)
            case .missingPenned:
                Text("Penned is not installed").fontWeight(.bold)
                Text("Install Penned on this device, then sign in under Account Settings.")
                    .foregroundStyle(ClipperSetupStyle.secondary)
            case .disconnected:
                Text("Not connected").fontWeight(.bold)
                Text("Open Penned and sign in under Account Settings, then return here.")
                    .foregroundStyle(ClipperSetupStyle.secondary)
            case .connected(let name, let spaces):
                HStack(spacing: 8) {
                    asset("checkwavy", size: 20).foregroundStyle(ClipperSetupStyle.accent)
                    Text(name).fontWeight(.bold).fixedSize(horizontal: false, vertical: true)
                }
                Text(spaces == 1 ? "1 Space available" : "\(spaces) Spaces available")
                    .foregroundStyle(ClipperSetupStyle.secondary)
                if spaces == 0 {
                    Text("Create a Space in Penned before saving clips.").foregroundStyle(ClipperSetupStyle.secondary)
                }
            case .unavailable(let message):
                Text("Connection unavailable").fontWeight(.bold)
                Text(message).foregroundStyle(ClipperSetupStyle.secondary)
            }
            Button(action: model.openPenned) {
                HStack(spacing: 8) {
                    asset("profilewavy", size: 20)
                    Text(model.isConnected ? "Manage Penned Connection" : "Connect to Penned")
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity).padding(.vertical, 13).padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ClipperSetupStyle.border))
            .disabled(!model.canOpenPenned)
            .opacity(model.canOpenPenned ? 1 : 0.45)
        }
    }

    private var safariSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().overlay(ClipperSetupStyle.border)
            sectionTitle("Safari Extension", icon: "writepen")
            HStack(spacing: 8) {
                if model.isExtensionEnabled { asset("checkwavy", size: 20).foregroundStyle(ClipperSetupStyle.accent) }
                Text(extensionStatusTitle).fontWeight(.bold)
            }
            if case .unavailable(let message) = model.extensionStatus {
                Text(message).font(.footnote).foregroundStyle(ClipperSetupStyle.secondary)
            }
            Button { Task { await model.openSafariSettings() } } label: {
                HStack(spacing: 8) {
                    asset("settingswavy", size: 20)
                    Text("Safari Extension Settings").fixedSize(horizontal: false, vertical: true)
                }
                .fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 14).padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .background(ClipperSetupStyle.accent, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var extensionStatusTitle: String {
        switch model.extensionStatus {
        case .checking: "Checking Safari"
        case .enabled: "Enabled in Safari"
        case .disabled: "Not enabled in Safari"
        case .unavailable: "Safari status unavailable"
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider().overlay(ClipperSetupStyle.border)
            Text("Enable in Safari").font(.system(.headline, design: .rounded).weight(.black))
            step("1", title: "Open Safari settings", detail: "Settings > Apps > Safari > Extensions.")
            step("2", title: "Turn on Penned Web Clipper", detail: "Enable the extension and allow access to websites you want to clip.")
            step("3", title: "Save an article", detail: "Open an article in Safari, choose Penned Web Clipper from Safari's extensions menu, select a Space and folder, then tap Save Clip.")
            Text("Saved clips and images import when Penned next opens. Account changes and sign-in stay in Penned's Account Settings.")
                .font(.footnote).foregroundStyle(ClipperSetupStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            asset(icon, size: 21).foregroundStyle(ClipperSetupStyle.accent)
            Text(title).font(.system(.headline, design: .rounded).weight(.black))
        }
    }
    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(.subheadline, design: .rounded).bold())
                .frame(width: 26, height: 26).background(.white.opacity(0.08), in: Circle())
                .foregroundStyle(ClipperSetupStyle.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.bold)
                Text(detail).foregroundStyle(ClipperSetupStyle.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
    private func asset(_ name: String, size: CGFloat) -> some View {
        Image(name).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}
