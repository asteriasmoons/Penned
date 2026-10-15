import SwiftUI
#if canImport(UIKit)
import UIKit

// Shared by card and document styles; the system owns every color control and mode.
struct CardThreeModeColorPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Color
    var title: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, finish: { dismiss() }) }

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.title = title
        picker.selectedColor = UIColor(selection)
        picker.supportsAlpha = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.selection = $selection
        picker.title = title
        let color = UIColor(selection)
        if !picker.selectedColor.isEqual(color) { picker.selectedColor = color }
    }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var selection: Binding<Color>
        let finish: () -> Void
        init(selection: Binding<Color>, finish: @escaping () -> Void) {
            self.selection = selection
            self.finish = finish
        }
        func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
            selection.wrappedValue = Color(uiColor: viewController.selectedColor)
        }
        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) { finish() }
    }
}
#else
struct CardThreeModeColorPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Color
    var title: String
    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            ColorPicker(title, selection: $selection)
        }.padding(24)
    }
}
#endif
