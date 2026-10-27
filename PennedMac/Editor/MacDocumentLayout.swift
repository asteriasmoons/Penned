import CoreGraphics

enum MacDocumentLayout {
    // Match the existing HTML page's 720-point maximum without adding a second centered inset.
    static let maximumContentWidth: CGFloat = 720
    static let contentInset: CGFloat = 28
    static let maximumPageWidth = maximumContentWidth + 2 * contentInset
}
