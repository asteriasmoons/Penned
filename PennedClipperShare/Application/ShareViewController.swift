import SwiftUI
import UIKit

/// Entry point for Penned's iOS Share Extension.
final class ShareViewController: UIViewController {
    private var hostingController: UIHostingController<ShareClipperView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let clipper = ShareClipperView(extensionItems: items) { [weak self] in
            self?.finishSharing()
        }
        let host = UIHostingController(rootView: clipper)
        hostingController = host

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
    }

    private func finishSharing() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
