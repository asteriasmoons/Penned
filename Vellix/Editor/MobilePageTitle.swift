import SwiftUI

extension Binding where Value == String {
    var singleLinePageTitle: Binding<String> {
        singleLinePageTitle(onReturn: {})
    }

    func singleLinePageTitle(onReturn: @escaping () -> Void) -> Binding<String> {
        Binding(
            get: { wrappedValue.split(whereSeparator: \.isNewline).joined(separator: " ") },
            set: { value in
                if value.contains(where: \.isNewline) {
                    // Return finishes editing; pasted lines retain all their text.
                    if value.filter({ !$0.isNewline }) != wrappedValue {
                        wrappedValue = value.split(whereSeparator: \.isNewline).joined(separator: " ")
                    }
                    onReturn()
                } else {
                    wrappedValue = value
                }
            }
        )
    }
}
