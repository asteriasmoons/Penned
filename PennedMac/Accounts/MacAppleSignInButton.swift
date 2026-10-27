import AppKit
import AuthenticationServices
import SwiftUI

struct MacAppleSignInButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let onRequest: (ASAuthorizationAppleIDRequest) -> Void
    let onCompletion: (Result<ASAuthorization, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: .black)
        button.cornerRadius = VellixRadius.md
        button.focusRingType = .none
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.signIn)
        context.coordinator.button = button
        return button
    }
    func updateNSView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ASAuthorizationAppleIDButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 375, height: proposal.height ?? 50)
    }
    static func dismantleNSView(_ nsView: ASAuthorizationAppleIDButton, coordinator: Coordinator) {
        coordinator.cancel()
    }

    final class Coordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        var parent: MacAppleSignInButton
        weak var button: ASAuthorizationAppleIDButton?
        private var controller: ASAuthorizationController?
        init(parent: MacAppleSignInButton) { self.parent = parent }
        func cancel() { controller?.cancel() }

        @objc func signIn() {
            guard controller == nil, button?.window != nil else { return }
            let request = ASAuthorizationAppleIDProvider().createRequest()
            parent.onRequest(request)
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            button?.window ?? NSApp.keyWindow ?? NSWindow()
        }
        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            self.controller = nil
            parent.onCompletion(.success(authorization))
        }
        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            self.controller = nil
            parent.onCompletion(.failure(error))
        }
    }
}
