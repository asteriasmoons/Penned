import SwiftUI
import PDFKit
#if os(iOS)
import UIKit
import MessageUI
#else
import AppKit
#endif

struct DocumentExportTab: View {
    let document: DocumentRecord
    @ObservedObject var queue: PublishingQueue
    @State private var selection: DocumentExportFormat?
    var body: some View {
        VStack(spacing: 0) {
            ForEach(DocumentExportFormat.menuCases) { format in
                PublicationOptionRow(title: format.title, icon: icon(format)) { selection = format }
                if format != .advanced { Divider().padding(.leading, 50) }
            }
        }.pennedSheetField()
        .sheet(item: $selection) { format in
            switch format {
            case .link: DocumentExportLinkSheet(document: document, queue: queue)
            case .duplicate: DocumentExportDuplicateSheet(document: document)
            case .advanced: DocumentExportAdvancedSheet(document: document)
            case .email: DocumentEmailExportSheet(document: document)
            default: DocumentExportPreviewSheet(document: document, format: format)
            }
        }
    }
    private func icon(_ format: DocumentExportFormat) -> String {
        switch format {
        case .markdown: "linedpages"
        case .image: "imagesign"
        case .email: "lovemail"
        case .duplicate: "copy"
        case .link: "link"
        case .advanced: "dotswavy"
        default: "sf:" + format.symbol
        }
    }
}

struct DocumentExportPreviewSheet: View {
    let document: DocumentRecord
    let format: DocumentExportFormat
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = DocumentExportController()
    @State private var settings = DocumentExportSettings()
    @State private var showsSettings = false
    @State private var activity: ExportActivity?
    @State private var actionError: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if controller.busy { ExportWorkingView(text: controller.progress) }
                else if let output = controller.output { preview(output) }
                else if let error = controller.error {
                    ContentUnavailableView { Label("Export Unavailable", systemImage: "exclamationmark.triangle") }
                        description: { Text(error).textSelection(.enabled) }
                        actions: { Button("Retry") { generate() } }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let output = controller.output, !controller.busy {
                if !output.warnings.isEmpty {
                    DisclosureGroup("\(output.warnings.count) unavailable assets") {
                        ForEach(output.warnings, id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(.horizontal, 20)
                }
                controls(output).padding(.horizontal, 20)
            }
            if let actionError { Text(actionError).font(.footnote).foregroundStyle(VellixSurface.coral).padding(.horizontal, 20) }
            if copied { Text("Copied").font(.footnote).foregroundStyle(PennedSheetStyle.accent) }
            HStack {
                Spacer()
                Button { showsSettings = true } label: {
                    Label("Export Options", systemImage: "slider.horizontal.3").padding(.horizontal, 16).frame(minHeight: 44).pennedSheetField()
                }.buttonStyle(.plain)
            }.padding(20)
        }
        .pennedSheet(title: format == .image ? "Image Export" : format.title, close: { controller.cancel(); dismiss() }) {
            if let output = controller.output, !controller.busy { shareButton(output) }
        }
        .sheet(isPresented: $showsSettings) { DocumentExportSettingsSheet(format: format, settings: $settings) }
        #if os(iOS)
        .sheet(item: $activity) { value in DocumentExportShareView(files: value.files) }
        .presentationDetents([.large])
        #else
        .frame(minWidth: 640, idealWidth: 800, maxWidth: .infinity, minHeight: 660, idealHeight: 800)
        #endif
        .task { generate() }
        .onChange(of: settings) { _, _ in generate() }
        .onChange(of: controller.output?.id) { _, _ in
            guard let output = controller.output else { return }
            if format == .print { perform { if let file = output.files.first { try DocumentExportPlatform.printDocument(file, title: document.title) } } }
        }
        .onDisappear { controller.cancel() }
    }

    @ViewBuilder private func preview(_ output: DocumentExportOutput) -> some View {
        if let text = output.previewText {
            ScrollView { Text(text).font(.system(.body, design: .monospaced)).fontWeight(.regular).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
        } else if format == .image {
            ScrollView(.horizontal) {
                HStack(spacing: 12) { ForEach(output.files, id: \.self) { file in ExportImagePage(url: file).frame(width: 300).padding(.vertical, 16) } }.padding(.horizontal, 20)
            }
        } else if [.pdf, .print].contains(format), let file = output.files.first { DocumentExportPDFView(url: file) }
        else {
            VStack(spacing: 16) {
                LibraryIcon(name: "sf:" + format.symbol, size: 48)
                Text(output.files.first?.lastPathComponent ?? document.title).font(.headline).multilineTextAlignment(.center)
                if let file = output.files.first, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(24)
        }
    }
    private func controls(_ output: DocumentExportOutput) -> some View {
        HStack(spacing: 10) {
            #if os(iOS)
            PublicationPrimaryButton(title: format == .image ? "Share Images" : "Share " + format.title) { activity = ExportActivity(files: output.files) }
            #else
            DocumentExportShareView(files: output.files).frame(width: 100, height: 40)
            Button { Task { do { try await DocumentExportPlatform.save(output) } catch { actionError = error.localizedDescription } } } label: {
                Label("Save", systemImage: "square.and.arrow.down").frame(minHeight: 44)
            }
            #endif
            if format == .image {
                Button { perform { try DocumentExportPlatform.copyImages(output.files); copied = true } } label: { LibraryIcon(name: "copy", size: 22).frame(width: 44, height: 44).pennedSheetField() }
                    .buttonStyle(.plain).accessibilityLabel("Copy images")
            } else if let text = output.previewText {
                Button { DocumentExportPlatform.copy(text: text); copied = true } label: { LibraryIcon(name: "copy", size: 22).frame(width: 44, height: 44).pennedSheetField() }
                    .buttonStyle(.plain).accessibilityLabel("Copy Markdown")
            }
            if format == .print || format == .pdf {
                Button { perform { if let file = output.files.first { try DocumentExportPlatform.printDocument(file, title: document.title) } } } label: { Image(systemName: "printer").frame(width: 44, height: 44).pennedSheetField() }
                    .buttonStyle(.plain).accessibilityLabel("Print document")
            }
        }
    }
    @ViewBuilder private func shareButton(_ output: DocumentExportOutput) -> some View {
        #if os(iOS)
        Button { activity = ExportActivity(files: output.files) } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(PennedSheetStyle.accent, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel("Share export")
        #else
        DocumentExportShareView(files: output.files).frame(width: 80, height: 36)
        #endif
    }
    private func generate() { copied = false; actionError = nil; controller.generate(documentID: document.id, format: format, settings: settings, environment: environment, scheme: scheme) }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { actionError = error.localizedDescription } }
}

private struct ExportActivity: Identifiable { let id = UUID(); let files: [URL] }

struct ExportImagePage: View {
    let url: URL
    var body: some View {
        #if os(iOS)
        if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(url.lastPathComponent) }
        #else
        if let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(url.lastPathComponent) }
        #endif
    }
}

private struct ExportWorkingView: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 16) {
            TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { value in
                let active = Int(value.date.timeIntervalSinceReferenceDate / 0.08) % 12
                ZStack { ForEach(0..<12) { index in
                    Circle().fill(PennedSheetStyle.accent).opacity(reduceMotion ? 0.8 : 1 - Double((active - index + 12) % 12) / 15)
                        .frame(width: 4.5, height: 4.5).offset(y: -15).rotationEffect(.degrees(Double(index) * 30))
                } }.frame(width: 40, height: 40)
            }.accessibilityHidden(true)
            Text(text).font(.subheadline).multilineTextAlignment(.center)
        }.padding(24)
    }
}

private struct DocumentExportAdvancedSheet: View {
    let document: DocumentRecord
    @Environment(\.dismiss) private var dismiss
    @State private var selected: DocumentExportFormat?
    var body: some View {
        VStack {
            PublicationOptionRow(title: "TextBundle", icon: "sf:shippingbox") { selected = .textBundle }.pennedSheetField()
            Spacer(minLength: 0)
        }.padding(20).pennedSheet(title: "Advanced", close: { dismiss() })
            .sheet(item: $selected) { DocumentExportPreviewSheet(document: document, format: $0) }
            #if os(iOS)
            .presentationDetents([.medium])
            #else
            .frame(width: 480, height: 260)
            #endif
    }
}

private struct DocumentExportLinkSheet: View {
    let document: DocumentRecord
    @ObservedObject var queue: PublishingQueue
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?
    private var internalURL: URL { DocumentInternalLink.url(documentID: document.id, libraryID: environment.database.libraryID, spaceID: document.spaceID) }
    private var publicURL: URL? {
        guard let job = queue.jobs[document.id], job.intent != "inactive", job.intent != "stop" else { return nil }
        let status = job.status
        guard status.active,
              status.settings.expiresAt.flatMap(PublishingDate.parse).map({ $0 > Date() }) ?? true else { return nil }
        return status.publicURL
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(publicURL == nil ? "Private document link" : "Published document link").font(.subheadline).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                row(publicURL == nil ? "Copy Private Link" : "Copy Published Link", value: (publicURL ?? internalURL).absoluteString)
                Divider().padding(.leading, 50)
                row("Copy Deeplink", value: internalURL.absoluteString)
                Divider().padding(.leading, 50)
                row("Copy Markdown Deeplink", value: "[" + document.title.replacingOccurrences(of: "]", with: "\\]") + "](" + internalURL.absoluteString + ")")
            }.pennedSheetField()
            if let copied { Text(copied).font(.footnote).foregroundStyle(PennedSheetStyle.accent) }
            Spacer(minLength: 0)
        }.padding(20).pennedSheet(title: "Link", close: { dismiss() })
        #if os(iOS)
        .presentationDetents([.medium])
        #else
        .frame(width: 480, height: 360)
        #endif
    }
    private func row(_ title: String, value: String) -> some View {
        PublicationOptionRow(title: title, icon: "link") { DocumentExportPlatform.copy(text: value); copied = "Link copied" }
    }
}

private struct DocumentExportDuplicateSheet: View {
    let document: DocumentRecord
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var busy = false
    @State private var error: String?
    @State private var created: DocumentRecord?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Duplicate Document to…", text: $search).textFieldStyle(.plain).padding(12).pennedSheetField()
                if let created {
                    Label(created.title, systemImage: "checkmark.circle.fill").foregroundStyle(PennedSheetStyle.accent)
                    Text("Created an independent copy.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        PublicationOptionRow(title: "Current Location", icon: "copy") { duplicate(space: document.spaceID, sameLocation: true) }
                        ForEach(environment.allSpaces.filter { !$0.isArchived && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { space in
                            Divider().padding(.leading, 50)
                            PublicationOptionRow(title: space.title, icon: space.icon ?? "spaces") { duplicate(space: space.id, sameLocation: false) }
                        }
                    }.pennedSheetField().disabled(busy)
                }
                if busy { ExportWorkingView(text: "Copying document and nested pages") }
                if let error { Text(error).font(.footnote).foregroundStyle(VellixSurface.coral) }
            }.padding(20)
        }.pennedSheet(title: "Duplicate Document", closeDisabled: busy, close: { dismiss() })
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(width: 500, height: 500)
        #endif
    }
    private func duplicate(space: String?, sameLocation: Bool) {
        guard !busy else { return }; busy = true; error = nil
        Task {
            do { created = try await DocumentExportService.duplicate(documentID: document.id, destinationSpaceID: space, sameLocation: sameLocation, environment: environment) }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

private struct DocumentEmailExportSheet: View {
    let document: DocumentRecord
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = DocumentExportController()
    @State private var actionError: String?
    @State private var activity: ExportActivity?
    #if os(iOS)
    @State private var mail: MailAttachment?
    #endif
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.busy { ExportWorkingView(text: controller.progress).frame(maxWidth: .infinity) }
            else {
                VStack(spacing: 0) {
                    ForEach([DocumentExportFormat.pdf, .word, .markdown, .textBundle]) { format in
                        PublicationOptionRow(title: format.title, icon: "sf:" + format.symbol) {
                            controller.generate(documentID: document.id, format: format, settings: DocumentExportSettings(), environment: environment, scheme: scheme)
                        }
                        if format != .textBundle { Divider().padding(.leading, 50) }
                    }
                }.pennedSheetField()
            }
            if let message = actionError ?? controller.error { Text(message).font(.footnote).foregroundStyle(VellixSurface.coral) }
            if let output = controller.output {
                #if os(iOS)
                PublicationPrimaryButton(title: "Share Attachment") { activity = ExportActivity(files: output.files) }
                #else
                DocumentExportShareView(files: output.files).frame(height: 36)
                #endif
            }
            Spacer(minLength: 0)
        }.padding(20).pennedSheet(title: "Email Attachment", close: { controller.cancel(); dismiss() })
        .onChange(of: controller.output?.id) { _, _ in compose() }
        .onDisappear { controller.cancel() }
        #if os(iOS)
        .sheet(item: $mail) { value in DocumentExportMailView(file: value.url, title: document.title, attachment: value.data) }
        .sheet(item: $activity) { DocumentExportShareView(files: $0.files) }
        .presentationDetents([.medium, .large])
        #else
        .frame(width: 500, height: 480)
        #endif
    }
    private func compose() {
        guard let output = controller.output else { return }; actionError = nil
        do {
            #if os(iOS)
            guard MFMailComposeViewController.canSendMail() else { throw DocumentExportError.failed("Mail is not configured on this device. Use Share Attachment to choose an email application.") }
            let url = try DocumentExportService.shareArchive(output)
            mail = MailAttachment(url: url, data: try Data(contentsOf: url))
            #else
            try DocumentExportPlatform.email(output, title: document.title)
            #endif
        } catch { actionError = error.localizedDescription }
    }
    #if os(iOS)
    private struct MailAttachment: Identifiable { let id = UUID(); let url: URL; let data: Data }
    #endif
}
