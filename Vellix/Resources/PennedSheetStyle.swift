import SwiftUI
#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
#endif

enum PennedSheetStyle {
    static let accent = VellixSurface.violet
    static let fieldTint = VellixSurface.input
    static let cornerRadius: CGFloat = 32
    static let blurIntensity: CGFloat = 0.35
    static let compactRowVerticalInset: CGFloat = 9
}

private struct PennedSheetDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct PennedSheetCompactRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var pennedSheetDismiss: (() -> Void)? {
        get { self[PennedSheetDismissKey.self] }
        set { self[PennedSheetDismissKey.self] = newValue }
    }

    var pennedSheetCompactRows: Bool {
        get { self[PennedSheetCompactRowsKey.self] }
        set { self[PennedSheetCompactRowsKey.self] = newValue }
    }
}

private struct PennedSheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .pennedApplicationAppearance()
            .tint(PennedSheetStyle.accent)
            .toggleStyle(PennedSheetToggleStyle())
            .pennedSheetBackdrop()
            .presentationCornerRadius(PennedSheetStyle.cornerRadius)
            .overlay {
                RoundedRectangle(cornerRadius: PennedSheetStyle.cornerRadius, style: .continuous)
                    .strokeBorder(VellixSurface.controlInk.opacity(0.10))
                    .ignoresSafeArea(.container)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
@available(iOS 26.1, *)
private struct PennedSheetBackdrop: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.applyBackdrop()
    }

    final class Controller: UIViewController {
        private static let transparentBase = UIColorEffect(color: .clear)

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isOpaque = false
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyBackdrop()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyBackdrop()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyBackdrop()
        }

        override func viewWillLayoutSubviews() {
            super.viewWillLayoutSubviews()
            applyBackdrop()
        }

        override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                guard let self, self.viewIfLoaded?.window != nil else { return }
                self.applyBackdrop()
            }
        }

        func applyBackdrop() {
            let transparentBase = Self.transparentBase
            var ancestors: [UIViewController] = []
            var candidate = parent
            while let controller = candidate {
                ancestors.append(controller)
                // Only the controller actually presented modally owns this surface.
                if let presenter = controller.presentingViewController,
                   presenter.presentedViewController === controller {
                    guard let sheet = controller.presentationController as? UISheetPresentationController else { return }
                    for ancestor in ancestors {
                        guard let surface = ancestor.viewIfLoaded else { continue }
                        if surface.backgroundColor != .clear { surface.backgroundColor = .clear }
                        if surface.isOpaque { surface.isOpaque = false }
                    }
                    // Only the presentationBackground view supplies blur; disable the system's second layer.
                    if sheet.backgroundEffect !== transparentBase { sheet.backgroundEffect = transparentBase }
                    for detent in sheet.detents where detent.backgroundEffect !== transparentBase {
                        detent.backgroundEffect = transparentBase
                    }
                    return
                }
                candidate = controller.parent
            }
        }
    }
}

struct PennedSheetBlurSurface: UIViewControllerRepresentable {
    var style: UIBlurEffect.Style = .systemUltraThinMaterialLight
    var intensity: CGFloat = PennedSheetStyle.blurIntensity
    var cornerRadius: CGFloat = 0
    var clipsToBounds = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.blurView.configure(style: style, intensity: reduceTransparency ? 1 : intensity,
                                      phase: scenePhase, contrast: contrast)
        controller.blurView.layer.cornerRadius = max(0, cornerRadius)
        controller.blurView.layer.cornerCurve = .continuous
        controller.blurView.clipsToBounds = clipsToBounds || cornerRadius > 0
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.blurView.endPresentation()
    }

    final class Controller: UIViewController {
        let blurView = BlurView()

        override func loadView() { view = blurView }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            blurView.refreshForAppearance()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Rebind after UIKit finishes the sheet's presentation transition.
            blurView.refreshForAppearance()
        }

        override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                guard let self, self.viewIfLoaded?.window != nil else { return }
                self.blurView.refreshForAppearance()
            }
        }
    }

    final class BlurView: UIVisualEffectView {
        private var style: UIBlurEffect.Style = .systemUltraThinMaterialLight
        private var blur = UIBlurEffect(style: .systemUltraThinMaterialLight)
        private var animator: UIViewPropertyAnimator?
        private var intensity = PennedSheetStyle.blurIntensity
        private var installedIntensity: CGFloat?
        private var phase: ScenePhase?
        private var contrast: ColorSchemeContrast?
        private var updatingBlur = false
        private var isPresentationReady = false

        init() {
            super.init(effect: nil)
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { return nil }

        func configure(style: UIBlurEffect.Style, intensity: CGFloat, phase: ScenePhase, contrast: ColorSchemeContrast) {
            let fraction = intensity.isFinite ? min(1, max(0, intensity)) : PennedSheetStyle.blurIntensity
            let changed = style != self.style || fraction != self.intensity || contrast != self.contrast
                || (phase == .active && self.phase != .active)
            if style != self.style {
                self.style = style
                blur = UIBlurEffect(style: style)
            }
            self.intensity = fraction
            self.phase = phase
            self.contrast = contrast
            updateBlur(force: changed)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { endPresentation() }
            else {
                // Presentation backgrounds can reattach without another controller appearance callback.
                isPresentationReady = true
                updateBlur(force: true)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateBlur()
        }

        func refreshForAppearance() {
            isPresentationReady = true
            updateBlur(force: true)
        }

        func endPresentation() {
            isPresentationReady = false
            removeBlur()
        }

        private func removeBlur() {
            if animator?.state == .active { animator?.stopAnimation(true) }
            animator = nil
            installedIntensity = nil
            effect = nil
        }

        private func updateBlur(force: Bool = false) {
            guard isPresentationReady, !updatingBlur, window != nil, bounds.width > 0, bounds.height > 0 else { return }
            if !force, installedIntensity == intensity {
                if intensity == 0 || intensity == 1 { return }
                if let animator, animator.state == .active, !animator.isRunning,
                   abs(animator.fractionComplete - intensity) < 0.0001 { return }
            }
            updatingBlur = true
            defer { updatingBlur = false }
            removeBlur()
            if intensity == 1 {
                effect = blur
            } else if intensity > 0 {
                let animation = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
                    guard let self else { return }
                    self.effect = self.blur
                }
                animation.scrubsLinearly = true
                animation.pausesOnCompletion = true
                animation.startAnimation()
                animation.pauseAnimation()
                animation.fractionComplete = intensity
                animator = animation
            }
            installedIntensity = intensity
        }
    }
}
#endif

private struct PennedSheetFieldBackground: View {
    var cornerRadius: CGFloat = 8

    var body: some View {
        PennedFrostedMaterial(tint: PennedSheetStyle.fieldTint, cornerRadius: cornerRadius)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct PennedSheetFieldDivider: View {
    @Environment(\.pixelLength) private var pixelLength

    var body: some View {
        Divider().frame(height: pixelLength)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct PennedSheetRowInsets: ViewModifier {
    @Environment(\.pennedSheetCompactRows) private var compact
    var isHeader = false

    func body(content: Content) -> some View {
        if compact {
            content.listRowInsets(EdgeInsets(top: isHeader ? 0 : PennedSheetStyle.compactRowVerticalInset,
                                            leading: VellixSpacing.lg,
                                            bottom: isHeader ? VellixSpacing.xs : PennedSheetStyle.compactRowVerticalInset,
                                            trailing: VellixSpacing.lg))
        } else {
            content
        }
    }
}

private struct PennedSheetRowBackground: View {
    var showsSeparator: Bool
    @Environment(\.pixelLength) private var pixelLength
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @Environment(\.pennedSheetSectionBackgroundOwner) private var sectionBackgroundOwner
    @Environment(\.pennedSheetSectionBackgroundID) private var sectionBackgroundID
    #endif

    var body: some View {
        surface
            .overlay(alignment: .bottom) {
                if showsSeparator {
                    // Keep the line above this row's blur and inside its bounds.
                    PennedSheetFieldDivider().padding(.horizontal, 20).padding(.bottom, pixelLength)
                }
            }
    }

    @ViewBuilder private var surface: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if let sectionBackgroundOwner, let sectionBackgroundID {
            PennedSheetSectionRowProbe(owner: sectionBackgroundOwner, sectionID: sectionBackgroundID)
                .allowsHitTesting(false).accessibilityHidden(true)
        } else {
            PennedSheetFieldBackground(cornerRadius: 0)
        }
        #else
        PennedSheetFieldBackground(cornerRadius: 0)
        #endif
    }
}

private struct PennedSheetChrome<Actions: View, Leading: View>: ViewModifier {
    let title: String?
    let closeDisabled: Bool
    let close: () -> Void
    let actions: Actions
    let leading: Leading
    let headerBottomPadding: CGFloat
    #if os(iOS)
    @State private var editMode = EditMode.inactive
    #endif

    func body(content: Content) -> some View {
        content
            .environment(\.pennedSheetDismiss, close)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            heading
                            PennedSheetControls(closeDisabled: closeDisabled, close: close, actions: actions)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 12) {
                            PennedSheetControls(closeDisabled: closeDisabled, close: close, actions: actions)
                            heading
                        }
                    }
                    if title != nil { Divider().opacity(0.35) }
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, headerBottomPadding)
            }
            .pennedSheetNavigationHidden()
            #if os(iOS)
            .environment(\.editMode, $editMode)
            #endif
            .pennedSheetPresentation()
    }

    @ViewBuilder private var heading: some View {
        if let title {
            Text(title).font(.system(.title3, design: .rounded).weight(.black))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            leading
        }
    }
}

private struct PennedSheetControls<Actions: View>: View {
    let closeDisabled: Bool
    let close: () -> Void
    let actions: Actions

    var body: some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: 12) {
                controls
            }
        } else {
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actionButtons; closeButton }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) { actionButtons; closeButton }
                }
                .scrollBounceBehavior(.basedOnSize).defaultScrollAnchor(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(.subheadline, design: .rounded).weight(.black))
        .controlSize(.large)
    }

    @ViewBuilder private var actionButtons: some View {
        if #available(iOS 26, macOS 26, *) {
            actions.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        } else {
            actions.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            LibraryIcon(name: "xmarkwavy", size: 23).frame(width: 44, height: 44)
                .pennedSheetCloseGlass()
        }
        .buttonStyle(.plain).disabled(closeDisabled)
        .accessibilityLabel("Close sheet").help("Close")
    }
}

struct PennedSheetToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 16) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? PennedSheetStyle.accent.opacity(0.38) : VellixSurface.controlInk.opacity(0.10))
                        .overlay(Capsule().strokeBorder(VellixSurface.controlInk.opacity(0.16)))
                    LibraryIcon(name: configuration.isOn ? "checkwavy" : "xmarkwavy", size: 15)
                        .foregroundStyle(configuration.isOn ? PennedSheetStyle.accent : Color.secondary)
                        .frame(width: 28, height: 28).background(.white.opacity(0.94), in: Circle())
                        .padding(3)
                }
                .frame(width: 60, height: 34)
                .accessibilityHidden(true)
            }
            .font(.system(.body, design: .rounded).weight(.black))
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

struct PennedSheetSearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 10) {
            LibraryIcon(name: "searchwavy", size: 19).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { LibraryIcon(name: "xmarkwavy", size: 14) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(12).pennedSheetField()
    }
}

extension View {
    func pennedSheetPresentation() -> some View { modifier(PennedSheetPresentation()) }

    func pennedSheetField(cornerRadius: CGFloat = 8) -> some View {
        background { PennedSheetFieldBackground(cornerRadius: cornerRadius) }
    }

    @ViewBuilder func pennedSheetRows(showsSeparator: Bool = false, when isSheet: Bool = true) -> some View {
        if isSheet {
            listRowBackground(PennedSheetRowBackground(showsSeparator: showsSeparator))
                .listRowSeparator(.hidden)
                .modifier(PennedSheetRowInsets())
        } else { self }
    }

    func pennedSheetSectionHeader() -> some View {
        modifier(PennedSheetRowInsets(isHeader: true))
    }

    @ViewBuilder fileprivate func pennedSheetBackdrop() -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.1, *) {
            // The ShapeStyle presentationBackground overload flattens materials on iOS 26.
            background { PennedSheetBackdrop().allowsHitTesting(false).accessibilityHidden(true) }
                .presentationBackground {
                    PennedSheetBlurSurface().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
        } else {
            presentationBackground(.ultraThinMaterial)
        }
        #else
        presentationBackground(.ultraThinMaterial)
        #endif
    }

    func pennedSheet<Actions: View>(title: String? = nil, closeDisabled: Bool = false,
                                  close: @escaping () -> Void, @ViewBuilder actions: () -> Actions) -> some View {
        modifier(PennedSheetChrome(title: title, closeDisabled: closeDisabled, close: close, actions: actions(),
                                  leading: EmptyView(), headerBottomPadding: 12))
    }

    func pennedSheet<Header: View>(header: Header, closeDisabled: Bool = false,
                                  close: @escaping () -> Void) -> some View {
        modifier(PennedSheetChrome(title: nil, closeDisabled: closeDisabled, close: close, actions: EmptyView(),
                                  leading: header, headerBottomPadding: 0))
    }

    func pennedSheet(title: String? = nil, closeDisabled: Bool = false, close: @escaping () -> Void) -> some View {
        pennedSheet(title: title, closeDisabled: closeDisabled, close: close) { EmptyView() }
    }

    @ViewBuilder fileprivate func pennedSheetNavigationHidden() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar).toolbarBackground(.hidden, for: .navigationBar)
        #elseif os(macOS)
        toolbar(.hidden, for: .windowToolbar)
        #else
        self
        #endif
    }

    @ViewBuilder fileprivate func pennedSheetCloseGlass() -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.interactive(), in: .circle)
        } else {
            background(.thinMaterial, in: Circle())
        }
    }
}
