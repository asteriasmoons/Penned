import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct PublishingSheet: View {
    let document: DocumentRecord
    @ObservedObject var queue: PublishingQueue
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var accounts: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var panel: PublishingPanel?
    @State private var confirm = ""
    @State private var error: String?
    @State private var copied = false
    private var job: PublicationJob? { queue.jobs[document.id] }
    private var status: PublicationStatus? { job?.status }
    private var live: Bool { status?.active == true && job?.intent != "inactive" }
    private var expired: Bool { status?.settings.expiresAt.flatMap(PublishingDate.parse).map { $0 <= Date() } ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Sharing", selection: .constant("Publish")) {
                    Text("Share").tag("Share").disabled(true)
                    Text("Publish").tag("Publish")
                    Text("Export").tag("Export").disabled(true)
                    Text("Transfer").tag("Transfer").disabled(true)
                }.pickerStyle(.segmented)
                heading
                if live, let status { published(status) } else { unpublished }
                if let message = error ?? job?.error ?? queue.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(VellixSurface.coral).textSelection(.enabled)
                    if job?.blocked == true {
                        Button("Publish This Device's Saved Version") { confirm = "replace" }
                    } else { Button("Retry Connection") { retryConnection() } }
                }
                if accounts.currentAccountIdentity == nil {
                    Text("Sign in through Account Settings to publish.").font(.footnote).foregroundStyle(.secondary)
                }
                if queue.busy { Text("Connecting to publishing…").font(.footnote).foregroundStyle(.secondary) }
                Text("Published documents update automatically after changes are successfully saved.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .font(.system(.body, design: .rounded).weight(.bold))
        .foregroundStyle(VellixSurface.controlInk)
        .pennedSheet(title: "Publish to Web", close: { dismiss() })
        .sheet(item: $panel) { value in
            PublishingOptionsSheet(panel: value, documentID: document.id, queue: queue)
        }
        .confirmationDialog(confirm == "remove" ? "Stop publishing this document?" : confirm == "regenerate" ? "Regenerate the public link?" : "Replace the published version with this device's saved document?",
            isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = "" } }), titleVisibility: .visible) {
            Button(confirm == "remove" ? "Remove Link" : confirm == "regenerate" ? "Regenerate Link" : "Publish Saved Version", role: .destructive) {
                let action = confirm; confirm = ""
                perform {
                    if action == "remove" { try await queue.stopPublishing(document.id) }
                    else if action == "regenerate" { try await queue.change(document.id, action: "regenerate") }
                    else { try await queue.publish(document.id) }
                }
            }
            Button("Cancel", role: .cancel) { confirm = "" }
        } message: {
            Text(confirm == "regenerate" ? "The previous link and custom path will stop working. Existing reader access will be revoked." : confirm == "remove" ? "The public document and its media will be revoked when the server confirms removal. Offline requests remain queued." : "Use this only after reviewing changes from your other devices.")
        }
        #if os(iOS)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        #else
        .frame(width: 540, height: 710)
        #endif
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) { LibraryIcon(name: "linkcircle", size: 23); Text("Publish to the Web").font(.title3.bold()) }
            Text(document.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
    }
    private var unpublished: some View {
        VStack(spacing: 16) {
            LibraryDocumentPreview(document: document, fixedAspectRatio: 1.3, showsStar: false, cornerRadius: 8)
                .frame(maxWidth: .infinity).allowsHitTesting(false)
            PublicationPrimaryButton(title: queue.busy ? "Publishing…" : "Create Link") { perform { try await queue.publish(document.id) } }
                .disabled(queue.busy || accounts.currentAccountIdentity == nil)
        }
    }
    private func published(_ status: PublicationStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { copy(status.publicURL) } label: {
                HStack { Text(status.publicURL.absoluteString).lineLimit(1).truncationMode(.middle); LibraryIcon(name: "copy", size: 18) }
                    .padding(12).frame(maxWidth: .infinity).pennedSheetField()
            }.buttonStyle(.plain).accessibilityLabel("Copy published link")
            HStack(spacing: 8) {
                ShareLink(item: status.publicURL) { Text("Share").frame(maxWidth: .infinity, minHeight: 46) }
                    .buttonStyle(.plain).foregroundStyle(Color.black).background(PennedSheetStyle.accent, in: Capsule())
                Button { panel = .qr } label: { Image(systemName: "qrcode").frame(width: 46, height: 46).pennedSheetField() }
                    .buttonStyle(.plain).accessibilityLabel("QR code")
                Button { openURL(status.publicURL) } label: { LibraryIcon(name: "arrowin", size: 20).frame(width: 46, height: 46).pennedSheetField() }
                    .buttonStyle(.plain).accessibilityLabel("Open published document")
            }
            if copied { Text("Link copied").font(.footnote).foregroundStyle(PennedSheetStyle.accent) }
            VStack(spacing: 0) {
                option("Customize URL", "link", status.customPath ?? status.publicURL.host ?? "", .url)
                option("Password", "lockpassword", status.passwordSet == true ? "Password Set" : "No Password", .password)
                option("Email Access", "lovemail", (status.emails?.isEmpty ?? true) && (status.emailDomains?.isEmpty ?? true) ? "Off" : "Restricted", .email)
                option("Expiration", "lovecalendar", expiration(status.settings.expiresAt), .expiration)
                option("Comments", "starchat", "Not Available", .comments)
                option("Advanced Options", "settingswavy", "", .advanced)
                PublicationOptionRow(title: "Regenerate Link", icon: "repeatarrows") { confirm = "regenerate" }.disabled(queue.busy)
                Divider().padding(.leading, 50)
                PublicationOptionRow(title: "Remove Link", icon: "trash", destructive: true) { confirm = "remove" }
            }.pennedSheetField()
            VStack(alignment: .leading, spacing: 5) {
                Text(job?.intent == "stop" ? "Removal pending connection" : expired ? "Expired" : job?.blocked == true ? "Update needs review" : job?.dirty == true ? "Changes waiting to upload" : "Published")
                    .foregroundStyle(PennedSheetStyle.accent)
                if let date = status.publishedAt.flatMap(PublishingDate.parse) {
                    Text("Last published \(date.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary)
                }
            }
            PublicationOptionRow(title: "Readers in the Last 30 Days", icon: "chartcircle", value: "Not Available", inactive: true) {}
                .pennedSheetField()
        }
    }
    private func option(_ title: String, _ icon: String, _ value: String, _ panel: PublishingPanel) -> some View {
        VStack(spacing: 0) {
            PublicationOptionRow(title: title, icon: icon, value: value) { self.panel = panel }
            Divider().padding(.leading, 50)
        }.disabled(queue.busy)
    }
    private func expiration(_ raw: String?) -> String {
        guard let raw, let date = PublishingDate.parse(raw) else { return "Never" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    private func perform(_ operation: @escaping () async throws -> Void) {
        error = nil; Task { do { try await operation() } catch { self.error = error.localizedDescription } }
    }
    private func retryConnection() {
        error = nil
        queue.retry()
        Task { await queue.discover() }
    }
    private func copy(_ url: URL) {
        #if os(iOS)
        UIPasteboard.general.url = url
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
        copied = true
    }
}
