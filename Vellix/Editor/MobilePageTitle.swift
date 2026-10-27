#if os(iOS)
import SwiftUI

extension Binding where Value == String {
    var singleLinePageTitle: Binding<String> {
        Binding(
            get: { wrappedValue.split(whereSeparator: \.isNewline).joined(separator: " ") },
            set: { wrappedValue = $0.split(whereSeparator: \.isNewline).joined(separator: " ") }
        )
    }
}
#endif
