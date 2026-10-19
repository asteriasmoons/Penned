import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CardThreeModeColorPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Color
    var title: String

    var body: some View {
        Group {
            #if canImport(UIKit)
            SheetNativeColorPicker(selection: $selection)
            #else
            Form { ColorPicker(title, selection: $selection, supportsOpacity: false).pennedSheetRows() }
            #endif
        }
        .pennedSheet(title: title, close: { dismiss() })
    }
}

#if canImport(UIKit)
// Embed the native palette as content so its modal toolbar does not compete with the shared sheet controls.
private struct SheetNativeColorPicker: UIViewControllerRepresentable {
    @Binding var selection: Color

    final class Host: UIViewController {
        let picker = UIColorPickerViewController()
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isOpaque = false
            addChild(picker)
            picker.view.backgroundColor = .clear
            picker.view.isOpaque = false
            picker.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(picker.view)
            NSLayoutConstraint.activate([
                picker.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                picker.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                picker.view.topAnchor.constraint(equalTo: view.topAnchor),
                picker.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            picker.didMove(toParent: self)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.picker.supportsAlpha = false
        host.picker.selectedColor = UIColor(selection)
        host.picker.delegate = context.coordinator
        return host
    }

    func updateUIViewController(_ host: Host, context: Context) {
        context.coordinator.selection = $selection
        let color = UIColor(selection)
        if !host.picker.selectedColor.isEqual(color) { host.picker.selectedColor = color }
    }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var selection: Binding<Color>
        init(selection: Binding<Color>) { self.selection = selection }
        func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
            selection.wrappedValue = Color(uiColor: viewController.selectedColor)
        }
    }
}
#endif
