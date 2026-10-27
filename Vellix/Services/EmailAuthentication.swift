import Foundation

struct VerifiedEmailAccount: Equatable, Sendable {
    let identity: AccountIdentity
    let email: String
}

@MainActor
protocol EmailAuthenticating {
    func sendCode(email: String, attempt: UUID) async throws
    func verifyCode(email: String, code: String, attempt: UUID) async throws -> VerifiedEmailAccount
    func cancel(attempt: UUID)
    func restore(_ identity: AccountIdentity) async throws -> VerifiedEmailAccount
    func signOut(_ identity: AccountIdentity) async throws
    func forget(_ identity: AccountIdentity) throws
    func deleteAccount(_ identity: AccountIdentity) async throws
    func publishingAccessToken(_ identity: AccountIdentity) async throws -> String
}

extension EmailAuthenticating {
    func publishingAccessToken(_ identity: AccountIdentity) async throws -> String { throw PublishingFailure.authenticationRequired }
}

enum EmailAuthError: LocalizedError, Equatable {
    case configurationMissing, wrongProject, invalidCode, expiredCode, sessionExpired
    case network, rateLimited, codeNotRequested, deletionUnavailable, deletionFailed, unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .configurationMissing: return "Email sign-in is not configured. Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY in Configuration/Supabase.xcconfig. Use the public publishable key, never a secret or service-role key."
        case .wrongProject: return "This account belongs to a different Supabase project. Restore its project configuration to sign in."
        case .invalidCode: return "That verification code is invalid. Check the code and try again."
        case .expiredCode: return "That verification code is invalid, expired, or already used. Check it or request a new code."
        case .sessionExpired: return "This email session is no longer valid. Continue with Email to sign in again."
        case .network: return "Could not reach the email sign-in service. Check your connection and try again."
        case .rateLimited: return "Too many requests. Wait before requesting another verification code."
        case .codeNotRequested: return "Request a verification code first."
        case .deletionUnavailable: return "Remote email-account deletion is not configured. Deploy the penned-delete-account Supabase function described in Docs/Accounts.md. Your account has not been reported as deleted."
        case .deletionFailed: return "Supabase could not confirm account deletion. Your local account details were kept. Please try again."
        case .unexpectedResponse: return "The email sign-in service returned an unexpected response. Please try again."
        }
    }
}
