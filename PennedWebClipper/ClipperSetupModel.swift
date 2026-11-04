import Combine
import Foundation
import SafariServices
import UIKit

@MainActor
final class ClipperSetupModel: ObservableObject {
    enum ExtensionStatus { case checking, enabled, disabled, unavailable(String) }
    enum ConnectionStatus {
        case checking, missingPenned, disconnected
        case connected(name: String, spaces: Int)
        case unavailable(String)
    }

    @Published private(set) var extensionStatus: ExtensionStatus = .checking
    @Published private(set) var connectionStatus: ConnectionStatus = .checking
    @Published private(set) var isRefreshing = false
    @Published var actionError: String?
    private var generation = UUID()

    private let pennedURL = URL(string: "penned://clipper/connect")!
    private var extensionIdentifier: String? { Bundle.main.object(forInfoDictionaryKey: "PennedSafariExtensionIdentifier") as? String }

    var canOpenPenned: Bool {
        if case .missingPenned = connectionStatus { return false }
        return true
    }
    var isConnected: Bool {
        if case .connected = connectionStatus { return true }
        return false
    }
    var isExtensionEnabled: Bool {
        if case .enabled = extensionStatus { return true }
        return false
    }

    func refresh() async {
        let request = UUID(); generation = request
        isRefreshing = true
        defer { if generation == request { isRefreshing = false } }
        await refreshConnection(request: request)
        guard generation == request, !Task.isCancelled else { return }
        guard let identifier = extensionIdentifier else {
            extensionStatus = .unavailable("The companion app's Safari extension identifier is missing."); return
        }
        do {
            let enabled: Bool = try await withCheckedThrowingContinuation { continuation in
                SFSafariExtensionManager.getStateOfExtension(withIdentifier: identifier) { state, error in
                    if let state { continuation.resume(returning: state.isEnabled) }
                    else { continuation.resume(throwing: error ?? ClipperError.message("Safari did not return an extension status.")) }
                }
            }
            guard generation == request, !Task.isCancelled else { return }
            extensionStatus = enabled ? .enabled : .disabled
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            extensionStatus = .unavailable(error.localizedDescription)
        }
    }

    private func refreshConnection(request: UUID) async {
        guard UIApplication.shared.canOpenURL(pennedURL) else {
            connectionStatus = .missingPenned; return
        }
        do {
            let connection = try await Task.detached(priority: .utility) {
                try ClipperShared.locked { try ClipperShared.connection() }
            }.value
            guard generation == request, !Task.isCancelled else { return }
            if let connection { connectionStatus = .connected(name: connection.accountName, spaces: connection.spaces.count) }
            else { connectionStatus = .disconnected }
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            connectionStatus = .unavailable(error.localizedDescription)
        }
    }

    func openPenned() {
        guard UIApplication.shared.canOpenURL(pennedURL) else {
            connectionStatus = .missingPenned
            actionError = "Install Penned on this device, then sign in using its Account Settings. The clipper does not have a separate sign-in."
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let opened = await UIApplication.shared.open(self.pennedURL, options: [:])
            if !opened { self.actionError = "Penned could not be opened. Open it from your Home Screen and visit Account Settings." }
        }
    }

    func openSafariSettings() async {
        guard let identifier = extensionIdentifier else { actionError = "The Safari extension identifier is missing."; return }
        do { try await SFSafariSettings.openExtensionsSettings(forIdentifiers: [identifier]) }
        catch { actionError = "Safari's extension settings could not be opened. Go to Settings > Apps > Safari > Extensions > Penned Web Clipper. " + error.localizedDescription }
    }
}
