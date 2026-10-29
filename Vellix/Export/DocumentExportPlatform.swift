import SwiftUI
import PDFKit
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
import MessageUI
#else
import AppKit
#endif

@MainActor
enum DocumentExportPlatform {
    static func copy(text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
    static func copyImages(_ urls: [URL]) throws {
        #if os(iOS)
        let data: [[String: Any]] = try urls.map { [UTType.png.identifier: try Data(contentsOf: $0)] }
        UIPasteboard.general.items = data
        #else
        let images = urls.compactMap { NSImage(contentsOf: $0) }
        guard images.count == urls.count else { throw DocumentExportError.failed("An image could not be copied.") }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(images)
        #endif
    }
    static func printDocument(_ url: URL, title: String) throws {
        #if os(iOS)
        guard UIPrintInteractionController.isPrintingAvailable else { throw DocumentExportError.failed("Printing is not available on this device.") }
        let printController = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil); info.jobName = title; info.outputType = .general
        printController.printInfo = info; printController.printingItem = url; printController.showsPageRange = true
        guard let view = presenter()?.view else { throw DocumentExportError.failed("The print window is not available.") }
        if UIDevice.current.userInterfaceIdiom == .pad {
            printController.present(from: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1), in: view, animated: true, completionHandler: nil)
        } else { printController.present(animated: true, completionHandler: nil) }
        #else
        guard let document = PDFDocument(url: url), let operation = document.printOperation(for: NSPrintInfo.shared.copy() as? NSPrintInfo, scalingMode: .pageScaleToFit, autoRotate: true) else {
            throw DocumentExportError.failed("The document could not be prepared for printing.")
        }
        operation.jobTitle = title; operation.showsPrintPanel = true; operation.showsProgressPanel = true
        operation.run()
        #endif
    }

    #if os(iOS)
    static func presenter() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed { controller = presented }
        return controller
    }
    #else
    static func save(_ output: DocumentExportOutput) async throws {
        let file = try DocumentExportService.shareArchive(output)
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.lastPathComponent; panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: file.pathExtension) { panel.allowedContentTypes = [type] }
        let result: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            result = await withCheckedContinuation { continuation in panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        } else { result = panel.runModal() }
        guard result == .OK, let destination = panel.url else { return }
        if destination.standardizedFileURL == file.standardizedFileURL { return }
        let access = destination.startAccessingSecurityScopedResource(); defer { if access { destination.stopAccessingSecurityScopedResource() } }
        // NSSavePanel has already obtained the user's overwrite confirmation.
        let staging = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
        try FileManager.default.copyItem(at: file, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: destination) }
    }
    static func email(_ output: DocumentExportOutput, title: String) throws {
        let file = try DocumentExportService.shareArchive(output)
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [file]) else {
            throw DocumentExportError.failed("No email composer is available. Use Share to choose another application.")
        }
        service.subject = title; service.perform(withItems: [file])
    }
    #endif
}

#if os(iOS)
struct DocumentExportShareView: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: files, applicationActivities: nil)
        if let popover = controller.popoverPresentationController { popover.sourceView = controller.view; popover.sourceRect = CGRect(x: 1, y: 1, width: 1, height: 1) }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct DocumentExportMailView: UIViewControllerRepresentable {
    let file: URL
    let title: String
    let attachment: Data
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator { dismiss() } }
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController(); controller.mailComposeDelegate = context.coordinator
        controller.setSubject(title)
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        controller.addAttachmentData(attachment, mimeType: mime, fileName: file.lastPathComponent)
        return controller
    }
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) { close() }
    }
}

struct DocumentExportPDFView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayDirection = .horizontal
        view.displayMode = .singlePageContinuous; view.usePageViewController(true, withViewOptions: nil)
        view.backgroundColor = .clear; view.document = PDFDocument(url: url); return view
    }
    func updateUIView(_ view: PDFView, context: Context) { if view.document?.documentURL != url { view.document = PDFDocument(url: url) } }
}
#else
struct DocumentExportShareView: NSViewRepresentable {
    let files: [URL]
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share export")
        button.bezelStyle = .rounded; return button
    }
    func updateNSView(_ nsView: NSButton, context: Context) { context.coordinator.files = files }
    func makeCoordinator() -> Coordinator { Coordinator(files: files) }
    final class Coordinator: NSObject {
        var files: [URL]
        private var picker: NSSharingServicePicker?
        init(files: [URL]) { self.files = files }
        @objc func share(_ sender: NSButton) {
            let value = NSSharingServicePicker(items: files); picker = value
            value.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

struct DocumentExportPDFView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .horizontal
        view.document = PDFDocument(url: url); return view
    }
    func updateNSView(_ view: PDFView, context: Context) { if view.document?.documentURL != url { view.document = PDFDocument(url: url) } }
}
#endif
