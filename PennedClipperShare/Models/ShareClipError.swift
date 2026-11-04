import Foundation

/// Errors presented by Penned's Share Extension during clipping.
enum ShareClipError: LocalizedError {
    case noSharedContent
    case unsupportedContent
    case invalidWebpageURL
    case articleExtractionFailed(String)
    case pennedNotConnected
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSharedContent:
            return "Nothing was shared with Penned."
        case .unsupportedContent:
            return "Penned cannot clip this type of shared content."
        case .invalidWebpageURL:
            return "The shared webpage link is invalid or unsupported."
        case .articleExtractionFailed(let reason):
            return "Could not extract this article. \(reason)"
        case .pennedNotConnected:
            return "Open Penned and sign in before saving a clip."
        case .saveFailed(let reason):
            return "Could not save this clip. \(reason)"
        }
    }
}
