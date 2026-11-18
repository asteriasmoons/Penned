import Combine
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct CodeBlockEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var draft: CodeBlockConfiguration
    @State private var menu: PickerMenu?
    @State private var focused = false
    @State private var keyboardVisible = false
    @State private var saving = false
    @State private var error: String?
    @State private var copied = false
    @State private var copyFeedback: Task<Void, Never>?
    let onPreview: (CodeBlockConfiguration?) -> Void
    let onSave: (CodeBlockConfiguration) async throws -> Void

    private enum PickerMenu: Equatable { case theme, language }
    private let catalog = CodeBlockCatalog.shared
    private let chrome = Color(vellixHex: "#18171e")
    private let purple = Color(vellixHex: "#8d52f7")
    private let copyMessage = "Code copied to clipboard"
    private var palette: CodeBlockPalette { catalog.palette(draft.theme, scheme: scheme) }

    init(request: CodeBlockEditorRequest, onPreview: @escaping (CodeBlockConfiguration?) -> Void,
         onSave: @escaping (CodeBlockConfiguration) async throws -> Void) {
        _draft = State(initialValue: request.original)
        self.onPreview = onPreview
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    VStack(spacing: 0) {
                        CodeBlockTextEditor(code: $draft.code, language: draft.language, palette: palette) { focused = $0 }
                            .disabled(saving)
                        toolbar
                    }
                    if let menu {
                        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { self.menu = nil }
                            .accessibilityHidden(true)
                        picker(menu)
                            .frame(width: min(232, max(0, geometry.size.width - 44)),
                                   height: min(478, max(0, geometry.size.height - 66)))
                            .padding(.leading, 22).padding(.bottom, 60)
                    }
                }
            }
            .overlay(alignment: .top) {
                if copied {
                    Label(copyMessage, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background { capsule }
                        .padding(.horizontal, 12).padding(.top, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: copied)
        }
        .background(chrome.ignoresSafeArea())
        .presentationBackground(chrome)
        .interactiveDismissDisabled(saving)
        .onChange(of: draft.language) { _, _ in onPreview(draft) }
        .onChange(of: draft.theme) { _, _ in onPreview(draft) }
        .onDisappear { onPreview(nil); copyFeedback?.cancel() }
        .alert("Could Not Save Code", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { keyboardChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { keyboardChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        #endif
    }

    private var header: some View {
        Text("Code")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, minHeight: 66)
            .overlay(alignment: .trailing) {
                Button(action: save) {
                    ZStack {
                        Circle().fill(purple)
                        if saving { ProgressView().tint(.white) }
                        else { Image(systemName: "checkmark").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white) }
                    }.frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(saving).accessibilityLabel("Save Code")
                .padding(.trailing, 18)
            }
            .background(Color(vellixHex: "#201f27"))
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }

    private var toolbar: some View {
        HStack {
            HStack(spacing: 7) {
                Button { toggle(.theme) } label: { LibraryIcon(name: "paintbrush", size: 22).frame(width: 46, height: 44) }
                    .accessibilityLabel("Editor Theme")
                Button { toggle(.language) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 21, weight: .medium)).frame(width: 46, height: 44) }
                    .accessibilityLabel("Editor Language")
            }.padding(.horizontal, 5).background { capsule }
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Button(action: copy) {
                    Group {
                        if copied { Image(systemName: "checkmark").font(.system(size: 19, weight: .medium)) }
                        else { LibraryIcon(name: "copy", size: 21) }
                    }.frame(width: 46, height: 44)
                }.accessibilityLabel(copied ? "Code Copied" : "Copy Code")
                #if os(iOS)
                if focused && keyboardVisible {
                    Button {
                        dismissKeyboard()
                    } label: { LibraryIcon(name: "keyboardclose", size: 22).frame(width: 46, height: 44) }
                        .accessibilityLabel("Dismiss Keyboard")
                }
                #endif
            }.padding(.horizontal, 5).background { capsule }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.95))
        .padding(.horizontal, 22).padding(.vertical, 8)
        .background(chrome)
        .disabled(saving)
    }

    private var capsule: some View {
        Capsule().fill(.ultraThinMaterial)
            .overlay { Capsule().fill(.black.opacity(0.35)) }
            .overlay { Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1) }
            .environment(\.colorScheme, .dark)
    }

    private func picker(_ menu: PickerMenu) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if menu == .theme {
                        ForEach(catalog.themes) { theme in
                            let sample = catalog.palette(theme.id, scheme: scheme)
                            pickerRow(theme.name, selected: draft.theme == theme.id, sample: sample) {
                                draft.theme = theme.id; self.menu = nil
                            }.id(theme.id)
                        }
                    } else {
                        ForEach(catalog.languages) { language in
                            pickerRow(language.name, selected: selectedLanguage == language.id) {
                                draft.language = language.id; self.menu = nil
                            }.accessibilityHint(language.id == "other" ? "Display an unsupported language as plain text" : "")
                                .id(language.id)
                        }
                    }
                }.padding(.vertical, 8).padding(.horizontal, 10)
            }
                .scrollDismissesKeyboard(.never)
                .defaultScrollAnchor(.top)
                .task(id: menu) { proxy.scrollTo(menu == .theme ? draft.theme : selectedLanguage, anchor: .center) }
        }
        .foregroundStyle(.white.opacity(0.94))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .background(Color(vellixHex: "#2a2930").opacity(0.9), in: RoundedRectangle(cornerRadius: 28))
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.3), radius: 15, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(menu == .theme ? "Editor Theme" : "Editor Language")
    }

    private func pickerRow(_ title: String, selected: Bool, sample: CodeBlockPalette? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .opacity(selected ? 1 : 0).frame(width: 16).accessibilityHidden(true)
                if let sample {
                    Text("A").font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(vellixHex: sample.hex("text")))
                        .frame(width: 22, height: 22).background(Color(vellixHex: sample.hex("background")), in: Circle())
                        .accessibilityHidden(true)
                }
                Text(title).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 4).frame(minHeight: 34).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var selectedLanguage: String {
        catalog.languages.contains { $0.id == draft.language } ? draft.language : "other"
    }

    private func toggle(_ next: PickerMenu) {
        menu = menu == next ? nil : next
    }

    private func save() {
        guard !saving else { return }
        let pendingDraft = draft
        menu = nil
        saving = true
        Task {
            defer { saving = false }
            do { try await onSave(pendingDraft); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = draft.code
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(draft.code, forType: .string) else { return }
        #endif
        copied = true
        copyFeedback?.cancel()
        copyFeedback = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }

    #if os(iOS)
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func keyboardChanged(_ notification: Notification) {
        guard let screenFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let overlap = window.bounds.intersection(window.convert(screenFrame, from: window.screen.coordinateSpace))
        keyboardVisible = !overlap.isNull && overlap.height >= 96
    }
    #endif
}
