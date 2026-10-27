import SwiftUI
import CoreImage.CIFilterBuiltins

struct PublishingOptionsSheet: View {
    let panel: PublishingPanel
    let documentID: String
    @ObservedObject var queue: PublishingQueue
    @Environment(\.dismiss) private var dismiss
    @State private var child: PublishingPanel?
    @State private var value = ""
    @State private var date = Date()
    @State private var settings = PublishingSettings()
    @State private var error: String?
    private var status: PublicationStatus? { queue.jobs[documentID]?.status }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
                if let error { Text(error).font(.footnote).foregroundStyle(VellixSurface.coral) }
            }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity).disabled(queue.busy)
        }
        .font(.system(.body, design: .rounded).weight(.bold))
        .foregroundStyle(VellixSurface.controlInk)
        .pennedSheet(title: panel.title, close: { dismiss() })
        .onAppear {
            settings = status?.settings ?? .init()
            if panel == .url { value = status?.customPath ?? "" }
            if let raw = settings.expiresAt, let saved = PublishingDate.parse(raw) { date = saved }
        }
        .sheet(item: $child) { panel in PublishingOptionsSheet(panel: panel, documentID: documentID, queue: queue) }
        #if os(iOS)
        .presentationDetents(panel == .advanced || panel == .expiration ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 520, height: panel == .advanced ? 700 : 540)
        #endif
    }

    @ViewBuilder private var content: some View {
        switch panel {
        case .url: urlOptions
        case .password: passwordOptions
        case .email: emailOptions
        case .people: addressEntry(domain: false)
        case .domains: addressEntry(domain: true)
        case .emailSettings: emailSettings
        case .expiration: expirationOptions
        case .comments: comments
        case .advanced: advanced
        case .qr:
            if let url = status?.publicURL {
                PublicationQRCode(url: url).frame(maxWidth: .infinity)
                Text(url.absoluteString).font(.footnote).textSelection(.enabled)
                ShareLink(item: url).frame(maxWidth: .infinity)
            }
        }
    }
    private var urlOptions: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Publish this page to your domain.").foregroundStyle(.secondary)
            VStack(spacing: 0) {
                HStack { Text(status?.publicURL.host ?? "Penned"); Spacer(); LibraryIcon(name: "checkwavy", size: 20).foregroundStyle(PennedSheetStyle.accent) }.padding(14)
                Divider()
                PublicationOptionRow(title: "Add External Domain", icon: "addwavy", value: "Not Available", inactive: true) {}
            }.pennedSheetField()
            Text("Path")
            TextField("Custom path (optional)", text: $value).textFieldStyle(.plain).padding(14).pennedSheetField()
                .autocorrectionDisabled().textCase(.lowercase)
            Text("Use 3–80 lowercase letters, numbers, or hyphens. Changing the path replaces the previous custom link.").font(.footnote).foregroundStyle(.secondary)
            actions { try await queue.change(documentID, action: "access", path: value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
    private var passwordOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("When a password is set, visitors must enter it to access this document and its media.").foregroundStyle(.secondary)
            SecureField("Enter Password", text: $value).textFieldStyle(.plain).padding(14).pennedSheetField()
            Text("At least 8 characters. Existing reader sessions are revoked when access settings change.").font(.footnote).foregroundStyle(.secondary)
            actions { try await queue.change(documentID, action: "access", password: value) }
            if status?.passwordSet == true {
                Button("Remove Password", role: .destructive) { save { try await queue.change(documentID, action: "access", password: "") } }
                    .frame(maxWidth: .infinity)
            }
        }
    }
    private var emailOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                PublicationOptionRow(title: "Add People", icon: "lovemail") { child = .people }
                Text("Restrict access to specific individuals").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 50).padding(.bottom, 14)
            }.pennedSheetField()
            VStack(spacing: 0) {
                PublicationOptionRow(title: "Add Email Domain Access", icon: "linkcircle") { child = .domains }
                Text("Restrict access to verified email domains").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 50).padding(.bottom, 14)
            }.pennedSheetField()
            HStack { Text("People with access").foregroundStyle(.secondary); Spacer(); Button { child = .emailSettings } label: { LibraryIcon(name: "settingswavy", size: 20) }.buttonStyle(.plain).accessibilityLabel("Email access settings") }
            if (status?.emails ?? []).isEmpty && (status?.emailDomains ?? []).isEmpty {
                Text("Add people to restrict link access").italic().foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 64)
            }
            ForEach(status?.emails ?? [], id: \.self) { address in accessRow(address, domain: false) }
            ForEach(status?.emailDomains ?? [], id: \.self) { address in accessRow(address, domain: true) }
        }
    }
    private func accessRow(_ address: String, domain: Bool) -> some View {
        HStack {
            Text(domain ? "@" + address : address).font(.subheadline).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(role: .destructive) {
                save(close: false) {
                    try await queue.change(documentID, action: "access", emails: domain ? nil : (status?.emails ?? []).filter { $0 != address }, domains: domain ? (status?.emailDomains ?? []).filter { $0 != address } : nil)
                }
            } label: { LibraryIcon(name: "trash", size: 18) }.buttonStyle(.plain).accessibilityLabel("Remove " + address)
        }.padding(14).pennedSheetField()
    }
    private func addressEntry(domain: Bool) -> some View {
        VStack(spacing: 18) {
            TextField(domain ? "example.com" : "Add Emails", text: $value, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...5).autocorrectionDisabled().padding(14).pennedSheetField()
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.emailAddress)
                #endif
            Text(domain ? "Add more domains separated by commas." : "Add email addresses separated by commas. Visitors verify their address using an email code.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            actions {
                let added = value.components(separatedBy: CharacterSet(charactersIn: ",;\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
                guard !added.isEmpty else { throw PublishingFailure.invalidContent("Enter an email address or domain.") }
                try await queue.change(documentID, action: "access", emails: domain ? nil : Array(Set((status?.emails ?? []) + added)).sorted(), domains: domain ? Array(Set((status?.emailDomains ?? []) + added)).sorted() : nil)
            }
        }
    }
    private var emailSettings: some View {
        VStack(spacing: 16) {
            PublicationOptionRow(title: "Remove All", icon: "trash", destructive: true, inactive: (status?.emails ?? []).isEmpty && (status?.emailDomains ?? []).isEmpty) {
                save { try await queue.change(documentID, action: "access", emails: [], domains: []) }
            }.pennedSheetField()
            Text("Allowed people and domains must verify their email address. A password, if configured, is required as well.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var expirationOptions: some View {
        VStack(spacing: 16) {
            DatePicker("Expiration Date", selection: $date, in: Date()..., displayedComponents: .date).datePickerStyle(.graphical)
            PublicationPrimaryButton(title: "Expire on " + date.formatted(date: .abbreviated, time: .omitted)) {
                save {
                    let calendar = Calendar.current
                    guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else { return }
                    settings.expiresAt = ISO8601DateFormatter().string(from: next)
                    try await queue.change(documentID, settings: settings)
                }
            }
            Button("Never Expire") { save { settings.expiresAt = nil; try await queue.change(documentID, settings: settings) } }
                .frame(maxWidth: .infinity, minHeight: 46).pennedSheetField()
        }
    }
    private var comments: some View {
        VStack(spacing: 18) {
            Toggle("Visitors Can View Comments", isOn: .constant(false)).disabled(true)
            Toggle("Visitors Can Add Comments", isOn: .constant(false)).disabled(true)
            Text("Comments are not available yet.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Visual Options")
            Toggle("Show Table of Contents", isOn: $settings.showTableOfContents)
            Toggle("Show Title", isOn: $settings.showTitle)
            Toggle("Show Author", isOn: $settings.showAuthor)
            if settings.showAuthor { TextField("Author Name", text: $settings.authorName).textFieldStyle(.plain).padding(12).pennedSheetField() }
            Toggle("Show Created With Penned", isOn: $settings.showBranding)
            Toggle("Show Presentation Mode", isOn: .constant(false)).disabled(true)
            Toggle("Hide Words Starting With Hashtag", isOn: $settings.hideHashtags)
            Divider()
            section("User Interactivity")
            Toggle("Visitors Can Duplicate", isOn: .constant(false)).disabled(true)
            Text("Duplication and presentation mode are not available yet.").font(.footnote).foregroundStyle(.secondary)
            Toggle("Visitors Can Follow Block Links", isOn: $settings.allowFollowLinkedContent)
            Text("Opens separately published linked pages owned by this account. Unpublished content stays private.").font(.footnote).foregroundStyle(.secondary)
            Divider()
            section("Search Engines")
            Toggle("Enable Search Engine Indexing", isOn: $settings.allowIndexing)
                .disabled(status?.passwordSet == true || !(status?.emails ?? []).isEmpty || !(status?.emailDomains ?? []).isEmpty)
            Text("Only available for links without password or email restrictions.").font(.footnote).foregroundStyle(.secondary)
            actions { try await queue.change(documentID, settings: settings) }
        }
    }
    private func section(_ title: String) -> some View { Text(title).font(.subheadline).foregroundStyle(.secondary) }
    private func actions(_ operation: @escaping () async throws -> Void) -> some View {
        HStack(spacing: 10) {
            Button("Cancel") { dismiss() }.frame(maxWidth: .infinity, minHeight: 46).pennedSheetField()
            PublicationPrimaryButton(title: "Save") { save(operation: operation) }
        }
    }
    private func save(close: Bool = true, operation: @escaping () async throws -> Void) {
        error = nil
        Task { do { try await operation(); if close { dismiss() } } catch { self.error = error.localizedDescription } }
    }
}

private struct PublicationQRCode: View {
    let url: URL
    private var image: CGImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(url.absoluteString.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                .padding(16).background(.white).frame(maxWidth: 300).accessibilityLabel("QR code for published link")
        }
    }
}
