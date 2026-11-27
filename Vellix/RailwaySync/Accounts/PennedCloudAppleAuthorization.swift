import Foundation
import AuthenticationServices
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// This is ordinary Penned account proof, not an infrastructure login.
@MainActor final class PennedCloudAppleAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<Data, Error>?
    private var anchor: ASPresentationAnchor?
    private var expectedSubject = ""

    static var activeAnchor: ASPresentationAnchor? {
        #if os(macOS)
        guard NSApp.isActive else { return nil }
        return NSApp.keyWindow ?? NSApp.mainWindow
        #else
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first { $0.isKeyWindow }
        #endif
    }

    func authorize(subject:String,challenge:RailwayAppleChallenge) async throws -> Data {
        guard continuation == nil, let anchor=Self.activeAnchor else{throw CancellationError()}
        self.anchor=anchor; expectedSubject=subject
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {continuation.resume(throwing:CancellationError());return}
                self.continuation=continuation
                let request=ASAuthorizationAppleIDProvider().createRequest()
                request.user=subject
                request.nonce=challenge.nonce
                let controller=ASAuthorizationController(authorizationRequests:[request])
                self.controller=controller
                controller.delegate=self;controller.presentationContextProvider=self
                controller.performRequests()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Kept strongly until the request completes.
        anchor ?? ASPresentationAnchor()
    }
    func authorizationController(controller:ASAuthorizationController,didCompleteWithAuthorization authorization:ASAuthorization) {
        guard controller === self.controller else{return}
        guard let credential=authorization.credential as? ASAuthorizationAppleIDCredential,
              credential.user==expectedSubject,let token=credential.identityToken else{
            finish(.failure(RailwayError.accountMismatch));return
        }
        finish(.success(token))
    }
    func authorizationController(controller:ASAuthorizationController,didCompleteWithError error:Error) {
        guard controller === self.controller else{return}
        finish(.failure(error))
    }
    private func cancel(){controller?.cancel();finish(.failure(CancellationError()))}
    private func finish(_ result:Result<Data,Error>){
        let pending=continuation
        continuation=nil;controller=nil;anchor=nil;expectedSubject=""
        pending?.resume(with:result)
    }
}

nonisolated struct PennedCloudAppleProof:Sendable {
    let ownerKey:String
    let challenge:RailwayAppleChallenge
    let token:Data
    let createdAt:Date
    var isFresh:Bool {Date().timeIntervalSince(createdAt)<240}
}
