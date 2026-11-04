import Foundation

/// UI-level publishing eligibility, based on Penned's Sign in with Apple identity.
/// This is NOT a server-side authorization boundary. Gallery writes are checked
/// independently by the authenticated Supabase Edge Function.
enum TemplateGalleryAuthorization {
    private static let publisherAppleUserID =
        "001664.f2fefbb84f024544b98e865fa6c6b49e.1524"

    static func canShowPublishingControls(appleUserID: String?) -> Bool {
        guard let appleUserID else { return false }
        return appleUserID == publisherAppleUserID
    }

    static func visibleCategories(_ categories: [GalleryCategory], isPublisher: Bool) -> [GalleryCategory] {
        categories.filter {
            isPublisher || $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(TemplateRepository.unsortedCategory) != .orderedSame
        }
    }
}
