#if os(iOS)
import SwiftUI
import UIKit

struct StyleNameAlert: UIViewControllerRepresentable {
    let title: String
    @Binding var isPresented: Bool
    @Binding var name: String
    let onSave: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> HostController {
        let controller = HostController()
        controller.didAppear = { [weak coordinator = context.coordinator, weak controller] in
            guard let controller else { return }
            coordinator?.update(in: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: HostController, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.update(in: controller)
    }

    static func dismantleUIViewController(_ controller: HostController, coordinator: Coordinator) {
        controller.didAppear = nil
        coordinator.alert?.dismiss(animated: false)
    }

    final class HostController: UIViewController {
        var didAppear: (() -> Void)?
        private(set) var isVisible = false

        override func loadView() { view = UIView(); view.backgroundColor = .clear }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            didAppear?()
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isVisible = false
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var configuration: StyleNameAlert
        var alert: UIAlertController?
        private var saveAction: UIAlertAction?
        private var finishing = false

        init(_ configuration: StyleNameAlert) { self.configuration = configuration }

        func update(in controller: HostController) {
            guard configuration.isPresented else {
                if alert != nil && !finishing { finish(save: false) }
                return
            }
            if let field = alert?.textFields?.first {
                if field.text != configuration.name { field.text = configuration.name }
                validate(field)
                return
            }
            guard controller.isVisible, controller.view.window != nil,
                  controller.presentedViewController == nil else { return }
            let prompt = UIAlertController(title: configuration.title, message: nil, preferredStyle: .alert)
            prompt.addTextField { [weak self] field in
                guard let self else { return }
                field.placeholder = "Style name"
                field.text = self.configuration.name
                field.returnKeyType = .done
                field.delegate = self
                field.addTarget(self, action: #selector(self.nameChanged(_:)), for: .editingChanged)
            }
            let save = UIAlertAction(title: "Save", style: .default) { [weak self] _ in self?.finish(save: true) }
            saveAction = save
            if let field = prompt.textFields?.first { validate(field) }
            prompt.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finish(save: false) })
            prompt.addAction(save)
            alert = prompt
            controller.present(prompt, animated: true) { [weak self, weak prompt] in
                guard let self, self.configuration.isPresented, self.alert === prompt,
                      let field = prompt?.textFields?.first else { return }
                // Wait for the native presentation to finish before requesting the keyboard.
                field.becomeFirstResponder()
                field.reloadInputViews()
            }
        }

        private func validate(_ field: UITextField) {
            saveAction?.isEnabled = !(field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        @objc private func nameChanged(_ field: UITextField) {
            configuration.name = field.text ?? ""
            validate(field)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard saveAction?.isEnabled == true else { return false }
            finish(save: true)
            return false
        }

        private func finish(save: Bool) {
            guard !finishing, let prompt = alert else { return }
            let name = prompt.textFields?.first?.text ?? configuration.name
            guard !save || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            finishing = true
            let onSave = configuration.onSave
            configuration.name = name
            configuration.isPresented = false
            prompt.dismiss(animated: true) { [self] in
                alert = nil
                saveAction = nil
                finishing = false
                if save { onSave(name) }
            }
        }
    }
}
#endif
