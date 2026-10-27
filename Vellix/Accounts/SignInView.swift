//
//  SignInView.swift
//  Penned
//

import SwiftUI
import SwiftData
import AuthenticationServices

struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @Query private var authUsers: [AuthUser]

    @State private var isSigningIn = false
    @State private var errorText: String?
    @State private var emailFlow = false
    @State private var emailAddress = ""
    @State private var sentTo: String?
    @State private var code = ""
    @State private var attempt = UUID()
    @State private var emailTask: Task<Void, Never>?
    @State private var codeResent = false
    @State private var publishingNonce: PublishingAppleNonce?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VellixSpacing.lg) {
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(VellixSurface.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if emailFlow {
                    emailFields
                } else {
                    appleButton
                    Button { emailFlow = true; errorText = nil } label: {
                        Label { Text("Continue with Email") } icon: { LibraryIcon(name: "luvmail", size: 22) }
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(VellixSurface.violet).pennedSheetField()
                    }.buttonStyle(.plain).disabled(isSigningIn)
                }
                if isSigningIn { ProgressView().frame(maxWidth: .infinity) }
            }
            .fontDesign(.rounded)
            .fontWeight(.black)
            .foregroundStyle(VellixSurface.ink)
            .padding(VellixSpacing.lg)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .pennedSheet(title: emailFlow ? "Continue with Email" : "Sign In", close: { cancelEmail(); dismiss() })
        .onDisappear { cancelEmail() }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            errorText = nil
            isSigningIn = true
            request.requestedScopes = [.fullName, .email]
            publishingNonce = try? PublishingAppleNonce()
            request.nonce = publishingNonce?.hashedValue
        } onCompletion: { result in
            handleAppleSignIn(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 50)
        .overlay(
            RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous)
                .strokeBorder(VellixSurface.violet, lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous))
        .disabled(isSigningIn)
    }

    @ViewBuilder private var emailFields: some View {
        if let sentTo {
            Text(sentTo).font(.body).textSelection(.enabled)
            TextField("Verification code", text: $code)
                .textContentType(.oneTimeCode)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .textFieldStyle(.plain).padding(VellixSpacing.md).pennedSheetField()
                .disabled(isSigningIn).onSubmit { verifyCode() }
            emailAction("Verify and Continue", icon: "checkwavy", action: verifyCode)
                .disabled(isSigningIn || !(6...10).contains(code.trimmingCharacters(in: .whitespacesAndNewlines).count))
            Button("Resend Code") { sendCode() }.disabled(isSigningIn)
                .foregroundStyle(VellixSurface.violet)
            if codeResent { Text("A new verification code was sent.").font(.footnote).foregroundStyle(.secondary) }
            Button("Change Email") {
                cancelEmail(); attempt = UUID(); self.sentTo = nil; code = ""; codeResent = false; errorText = nil
            }.disabled(isSigningIn).foregroundStyle(VellixSurface.violet)
        } else {
            TextField("Email address", text: $emailAddress)
                .textContentType(.emailAddress).autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                #endif
                .textFieldStyle(.plain).padding(VellixSpacing.md).pennedSheetField()
                .disabled(isSigningIn).onSubmit { sendCode() }
            emailAction("Send Verification Code", icon: "sendbutton", action: sendCode)
                .disabled(isSigningIn || (try? AccountValidation.email(emailAddress)) == nil)
            Button("Other Sign-In Methods") { emailFlow = false; errorText = nil }
                .disabled(isSigningIn).foregroundStyle(VellixSurface.violet)
        }
    }

    private func emailAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { LibraryIcon(name: icon, size: 22) }
                .frame(maxWidth: .infinity, minHeight: 50)
        }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(VellixSurface.violet)
    }

    private func sendCode() {
        guard !isSigningIn else { return }
        isSigningIn = true; errorText = nil; codeResent = false
        let request = attempt
        let address = sentTo ?? emailAddress
        emailTask = Task {
            defer { if attempt == request { isSigningIn = false } }
            do {
                let address = try await appState.requestEmailCode(address, attempt: request)
                try Task.checkCancellation()
                guard attempt == request else { return }
                codeResent = sentTo != nil; sentTo = address; code = ""
            } catch is CancellationError {} catch { if attempt == request { errorText = error.localizedDescription } }
        }
    }

    private func verifyCode() {
        guard !isSigningIn, let sentTo else { return }
        isSigningIn = true; errorText = nil
        let request = attempt
        emailTask = Task {
            defer { if attempt == request { isSigningIn = false } }
            do {
                try await appState.verifyEmailCode(sentTo, code: code, attempt: request)
                try Task.checkCancellation()
                guard attempt == request else { return }
                dismiss()
            } catch is CancellationError {} catch { if attempt == request { errorText = error.localizedDescription } }
        }
    }

    private func cancelEmail() {
        emailTask?.cancel()
        appState.cancelEmailSignIn(attempt: attempt)
        isSigningIn = false
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        errorText = nil
        isSigningIn = true

        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                isSigningIn = false
                errorText = "Apple Sign In returned an unexpected credential."
                return
            }

            do {
                try appState.signInWithApple(
                    credential: credential,
                    existingUsers: authUsers,
                    modelContext: modelContext,
                    nonce: publishingNonce
                )

                isSigningIn = false
                dismiss()
            } catch {
                isSigningIn = false
                errorText = error.localizedDescription
            }

        case .failure(let error):
            isSigningIn = false
            if let authError = error as? ASAuthorizationError,
               authError.code == .canceled {
                return
            }
            errorText = error.localizedDescription
        }
    }
}
