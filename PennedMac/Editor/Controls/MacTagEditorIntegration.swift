// Mac-target platform adapter. Based on Vellix/Tags/TagEditorIntegration.swift.
// iPhone/iPad implementations remain in their original target.
import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif

struct TagEditorIntegration: ViewModifier {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: DocumentEditorModel
    @ObservedObject var session: TipTapEditorSession
    var locked: Bool
    @State private var menuRequest: InlineTagRequest?
    @State private var pendingTagName: String?
    @State private var destination: TagDestinationRect?
    @State private var commitQueue: Task<Bool, Never>?

    private var navigationKey: String {
        guard environment.selectedDocumentID == model.documentID, session.isPresentationReady,
              session.renderedDocumentID == model.documentID,
              let target = environment.tagNavigationTarget, target.documentID == model.documentID else { return "" }
        return target.id.uuidString + ":" + String(Double(session.tagNavigationWebView?.bounds.width ?? 0))
    }

    func body(content: Content) -> some View {
        content
            .onReceive(session.$tagRequest) { request in
                guard let request else { return }
                session.tagRequest = nil
                guard environment.selectedDocumentID == model.documentID else { discard(request); return }
                if request.action == "commit" {
                    guard !locked else { discard(request); return }
                    Task { await apply(request, name: request.name) }
                } else { menuRequest = request }
            }
            .sheet(item: $menuRequest, onDismiss: {
                let name = pendingTagName
                pendingTagName = nil
                guard let name, environment.selectedDocumentID == model.documentID else { return }
                Task { await environment.browseTags(named: name) }
            }) { request in
                TagActionsSheet(
                    locked: locked,
                    browse: { pendingTagName = request.name },
                    choose: { name in await apply(request, name: name) },
                    turnIntoText: { await apply(request, name: request.name, asText: true) }
                )
                .onDisappear { discard(request) }
            }
            .task(id: session.isReady.description + (session.renderedDocumentID ?? "")) { await updateCatalogue() }
            .onReceive(NotificationCenter.default.publisher(for: .pennedTagsChanged)) { _ in Task { await updateCatalogue() } }
            .onReceive(NotificationCenter.default.publisher(for: .pennedCollectionsChanged)) { _ in Task { await updateCatalogue() } }
            .task(id: navigationKey) {
                guard !navigationKey.isEmpty, let target = environment.tagNavigationTarget else { destination = nil; return }
                do {
                    guard let value = try await session.tagCommand("tagLocate", args: targetArguments(target)) as? [String: Any],
                          let x = value["x"] as? Double, let y = value["y"] as? Double,
                          let width = value["width"] as? Double, let height = value["height"] as? Double,
                          [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else {
                        throw VellixError.tagging("This tagged block is no longer in the document.")
                    }
                    guard !Task.isCancelled, environment.tagNavigationTarget?.id == target.id else { return }
                    destination = TagDestinationRect(target: target, rect: CGRect(x: x, y: y, width: width, height: height))
                } catch {
                    guard !Task.isCancelled, environment.tagNavigationTarget?.id == target.id else { return }
                    environment.tagNavigationTarget = nil; environment.report(error)
                }
            }
            .background {
                if let destination, environment.selectedDocumentID == model.documentID {
                    TagBlockScrollResolver(webView: session.tagNavigationWebView, destination: destination) {
                        guard environment.tagNavigationTarget?.id == destination.target.id else { return }
                        Task {
                            _ = try? await session.tagCommand("tagHighlight", args: targetArguments(destination.target))
                            if environment.tagNavigationTarget?.id == destination.target.id { environment.tagNavigationTarget = nil }
                        }
                    }.allowsHitTesting(false)
                }
            }
    }

    private func targetArguments(_ target: TagNavigationTarget) -> [String: Any] {
        var args: [String: Any] = ["blockID": target.blockID]
        if let occurrence = target.occurrenceID { args["occurrenceID"] = occurrence }
        return args
    }

    private func discard(_ request: InlineTagRequest) {
        Task { _ = try? await session.tagCommand("tagDismiss", args: ["token": request.token]) }
    }

    private func updateCatalogue() async {
        guard session.isReady else { return }
        do {
            let tags = try environment.tags.catalogue().map { ["id": $0.id, "name": $0.name, "normalizedName": $0.normalizedName] }
            _ = try await session.tagCommand("tagCatalogue", args: ["tags": tags])
        } catch { model.errorMessage = error.localizedDescription }
    }

    @discardableResult private func apply(_ request: InlineTagRequest, name: String, asText: Bool = false) async -> Bool {
        let previous = commitQueue
        let next = Task { () -> Bool in
            _ = await previous?.value
            return await commit(request, name: name, asText: asText)
        }
        commitQueue = next
        return await next.value
    }

    private func commit(_ request: InlineTagRequest, name: String, asText: Bool) async -> Bool {
        guard !locked, environment.selectedDocumentID == model.documentID,
              session.renderedDocumentID == model.documentID else { discard(request); return false }
        let operation = model.beginPersistentOperation()
        defer { model.endPersistentOperation(operation) }
        do {
            var args: [String: Any] = ["token": request.token, "name": name]
            if !asText {
                let tag = try environment.tags.resolve(name)
                args["tagID"] = tag.id; args["name"] = tag.name
            }
            guard (try await session.tagCommand(asText ? "tagToText" : "tagApply", args: args) as? Bool) == true else {
                throw VellixError.tagging("The tag's editing position changed. Tap the tag or type # again.")
            }
            try await model.captureAndSave()
            return true
        } catch { model.errorMessage = error.localizedDescription; return false }
    }
}

private struct TagActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var locked: Bool
    var browse: () -> Void
    var choose: (String) async -> Bool
    var turnIntoText: () async -> Bool
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 60
    @State private var swapping = false
    @State private var busy = false

    private var actionHeight: CGFloat { max(44, rowHeight - 16) }
    private var compactHeight: CGFloat { min(460, actionHeight * (locked ? 1 : 3) + 34) }

    var body: some View {
        VStack(spacing: 0) {
            if swapping {
                TagSelectorSheet { name in
                    busy = true
                    defer { busy = false }
                    return await choose(name)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if !locked {
                            Divider().opacity(0.25)
                            action("Swap Tag", icon: "repeatarrows") { swapping = true }
                            Divider().opacity(0.25)
                            action("Turn into Text", icon: "text") {
                                busy = true
                                Task {
                                    if await turnIntoText() { dismiss() }
                                    busy = false
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .disabled(busy)
                .pennedSheet(
                    header: action("Go to Tag", icon: "hashtagwavy") {
                        browse()
                        dismiss()
                    }.disabled(busy),
                    closeDisabled: busy, close: { dismiss() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(VellixSurface.controlInk)
        .presentationDragIndicator(.visible)
        .presentationDetents(swapping ? [.medium, .large] : [.height(compactHeight), .large])
        .interactiveDismissDisabled(busy)
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 16) {
                LibraryIcon(name: icon, size: 23).foregroundStyle(.secondary)
                Text(title).font(.system(.body, design: .rounded).weight(.black))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10).frame(minHeight: actionHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TagSelectorSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    var choose: (String) async -> Bool
    @State private var query = ""
    @State private var tags: [DocumentTag] = []
    @State private var busy = false
    private var matches: [DocumentTag] {
        let normalized = query.replacingOccurrences(of: "#", with: "").precomposedStringWithCanonicalMapping
            .uppercased(with: Locale(identifier: "en_US_POSIX")).lowercased(with: Locale(identifier: "en_US_POSIX"))
        return tags.filter { normalized.isEmpty || $0.normalizedName.contains(normalized) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("Search tags", text: $query).textFieldStyle(.plain).padding(12)
                    .pennedSheetField()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { tag in
                            Button { select(tag.name) } label: { Text("#" + tag.name).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14).contentShape(Rectangle()) }
                                .buttonStyle(.plain)
                        }
                        if let clean = TagName.clean(query), !tags.contains(where: { $0.normalizedName == TagName.normalized(clean) }) {
                            Button { select(clean) } label: {
                                Text("Create #" + clean).fontWeight(.black).foregroundStyle(VellixSurface.lilac)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(20).disabled(busy).navigationTitle("Swap Tag")
                .pennedSheet(title: "Swap Tag", closeDisabled: busy, close: { dismiss() })
                .task { reload() }
                .onReceive(NotificationCenter.default.publisher(for: .pennedTagsChanged)) { _ in reload() }
        }
        .font(.system(.body, design: .rounded).weight(.black))
        .fontDesign(.rounded).fontWeight(.black)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    private func reload() { do { tags = try environment.tags.catalogue() } catch { environment.report(error) } }
    private func select(_ name: String) { busy = true; Task { if await choose(name) { dismiss() }; busy = false } }
}

private struct TagDestinationRect {
    var target: TagNavigationTarget
    var rect: CGRect
}

#if canImport(UIKit)
// Wait for native layout/content-size changes, not a timer or an estimated scroll offset.
private struct TagBlockScrollResolver: UIViewRepresentable {
    weak var webView: WKWebView?
    var destination: TagDestinationRect
    var completed: () -> Void
    final class Probe: UIView {
        var resolve: (() -> Void)?
        override func layoutSubviews() { super.layoutSubviews(); resolve?() }
        override func didMoveToWindow() { super.didMoveToWindow(); resolve?() }
    }
    final class Coordinator {
        var request: TagBlockScrollResolver?
        var observation: NSKeyValueObservation?
        weak var scroll: UIScrollView?
        var completedID: UUID?
        func resolve() {
            guard let request, completedID != request.destination.target.id,
                  let web = request.webView, web.window != nil else { return }
            var parent = web.superview
            while let current = parent, !(current is UIScrollView) { parent = current.superview }
            guard let scroll = parent as? UIScrollView else { return }
            if self.scroll !== scroll {
                self.scroll = scroll
                observation = scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.resolve() }
            }
            guard !scroll.isTracking, !scroll.isDragging, request.destination.rect.maxY <= web.bounds.height + 1 else { return }
            let rect = web.convert(request.destination.rect, to: scroll)
            guard rect.maxY <= scroll.contentSize.height + 1, scroll.bounds.height > 0 else { return }
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            // Match the document's existing floating top controls and bring the tag itself into view.
            let inset: CGFloat = scroll.traitCollection.horizontalSizeClass == .regular ? 158 : 82
            let offset = max(top, min(bottom, rect.minY - inset))
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
            completedID = request.destination.target.id
            DispatchQueue.main.async { request.completed() }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); view.isUserInteractionEnabled = false
        view.resolve = { [weak coordinator = context.coordinator] in coordinator?.resolve() }
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        context.coordinator.request = self
        DispatchQueue.main.async { context.coordinator.resolve() }
    }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) { coordinator.observation?.invalidate(); view.resolve = nil }
}
#else
private struct TagBlockScrollResolver: NSViewRepresentable {
    weak var webView: WKWebView?
    var destination: TagDestinationRect
    var completed: () -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard let webView, let scroll = webView.enclosingScrollView else { return }
        let rect = webView.convert(destination.rect, to: scroll.documentView)
        scroll.documentView?.scrollToVisible(rect)
        DispatchQueue.main.async { completed() }
    }
}
#endif
