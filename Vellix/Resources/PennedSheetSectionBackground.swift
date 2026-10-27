import SwiftUI

#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit

private struct PennedSheetSectionBackgroundOwnerKey: EnvironmentKey {
    static let defaultValue: PennedSheetSectionBackgroundOwner? = nil
}

private struct PennedSheetSectionBackgroundIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var pennedSheetSectionBackgroundOwner: PennedSheetSectionBackgroundOwner? {
        get { self[PennedSheetSectionBackgroundOwnerKey.self] }
        set { self[PennedSheetSectionBackgroundOwnerKey.self] = newValue }
    }

    var pennedSheetSectionBackgroundID: String? {
        get { self[PennedSheetSectionBackgroundIDKey.self] }
        set { self[PennedSheetSectionBackgroundIDKey.self] = newValue }
    }
}

private struct PennedSheetGroupedSections: ViewModifier {
    @State private var owner = PennedSheetSectionBackgroundOwner()

    func body(content: Content) -> some View {
        content.environment(\.pennedSheetSectionBackgroundOwner, owner)
    }
}

struct PennedSheetSectionRowProbe: UIViewRepresentable {
    let owner: PennedSheetSectionBackgroundOwner
    let sectionID: String

    func makeUIView(context: Context) -> PennedSheetSectionBackgroundOwner.Probe {
        PennedSheetSectionBackgroundOwner.Probe()
    }

    func updateUIView(_ view: PennedSheetSectionBackgroundOwner.Probe, context: Context) {
        if view.owner !== owner { view.owner?.remove(view) }
        view.owner = owner
        view.sectionID = sectionID
        view.accessibilityIdentifier = "Penned.SectionRow.\(sectionID)"
        owner.update(view)
    }

    static func dismantleUIView(_ view: PennedSheetSectionBackgroundOwner.Probe, coordinator: ()) {
        view.owner?.remove(view)
        view.owner = nil
    }
}

// Native rows remain the layout and interaction owners. Only their background
// geometry is collected, without publishing geometry back into SwiftUI layout.
final class PennedSheetSectionBackgroundOwner {
    private struct WeakProbe {
        weak var view: Probe?
    }

    private var probes: [ObjectIdentifier: WeakProbe] = [:]
    private var planes: [ObjectIdentifier: Plane] = [:]

    func update(_ probe: Probe) {
        guard probe.window != nil, let list = probe.list else { remove(probe); return }
        probes[ObjectIdentifier(probe)] = WeakProbe(view: probe)
        let key = ObjectIdentifier(list)
        if planes[key] == nil {
            let plane = Plane(owner: self, list: list)
            planes[key] = plane
            list.insertSubview(plane, at: 0)
        }
        refreshPlanes()
    }

    func remove(_ probe: Probe) {
        probes.removeValue(forKey: ObjectIdentifier(probe))
        refreshPlanes()
    }

    private func refreshPlanes() {
        let activeLists = Set(probes.values.compactMap(\.view).filter { $0.window != nil }
            .compactMap(\.list).map(ObjectIdentifier.init))
        for key in Array(planes.keys) {
            if activeLists.contains(key) {
                planes[key]?.setNeedsLayout()
            } else {
                planes.removeValue(forKey: key)?.detach()
            }
        }
    }

    private func layout(_ plane: Plane) {
        guard let list = plane.list else { return }
        probes = probes.filter { $0.value.view != nil }
        let attached = probes.values.compactMap(\.view).filter { $0.window != nil && $0.list === list }
        guard !attached.isEmpty else {
            planes.removeValue(forKey: ObjectIdentifier(list))?.detach()
            return
        }
        let rows = attached.filter { $0.isVisibleRow && !$0.bounds.isEmpty }

        let contentFrame = CGRect(origin: .zero, size: CGSize(width: list.bounds.width,
            height: max(list.bounds.height, list.contentSize.height)))
        if plane.frame != contentFrame { plane.frame = contentFrame }
        if list.subviews.first !== plane { list.sendSubviewToBack(plane) }
        let sections = Dictionary(grouping: rows, by: \.sectionID)
        for id in Array(plane.surfaces.keys) where sections[id] == nil {
            plane.surfaces.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (id, members) in sections {
            let positioned = members.map { ($0, $0.convert($0.bounds, to: list)) }
                .filter { !$0.1.isNull && !$0.1.isInfinite && !$0.1.isEmpty
                    && $0.1.minX.isFinite && $0.1.minY.isFinite }
                .sorted { $0.1.minY < $1.1.minY }
            guard let first = positioned.first, let last = positioned.last else { continue }
            let frame = positioned.dropFirst().reduce(first.1) { $0.union($1.1) }
            let top = first.0.nativeCorners(in: list)
            let bottom = last.0.nativeCorners(in: list)
            let corners = Corners(topLeft: top.topLeft, topRight: top.topRight,
                                  bottomLeft: bottom.bottomLeft, bottomRight: bottom.bottomRight)
            let surface: Surface
            if let existing = plane.surfaces[id] {
                surface = existing
            } else {
                surface = Surface(sectionID: id)
                plane.surfaces[id] = surface
                plane.addSubview(surface)
            }
            surface.apply(frame: frame, corners: corners)
        }
    }

    fileprivate struct Corners: Equatable {
        var topLeft: CGFloat = 0
        var topRight: CGFloat = 0
        var bottomLeft: CGFloat = 0
        var bottomRight: CGFloat = 0
    }

    final class Probe: UIView {
        weak var owner: PennedSheetSectionBackgroundOwner?
        var sectionID = ""

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { return nil }

        var list: UIScrollView? {
            var candidate = superview
            while let view = candidate {
                if view is UICollectionView || view is UITableView { return view as? UIScrollView }
                candidate = view.superview
            }
            return nil
        }

        fileprivate var isVisibleRow: Bool {
            var candidate = superview
            while let view = candidate {
                if let cell = view as? UICollectionViewCell, let list = list as? UICollectionView {
                    return list.indexPath(for: cell).map { list.cellForItem(at: $0) === cell } ?? false
                }
                if let cell = view as? UITableViewCell, let list = list as? UITableView {
                    return list.visibleCells.contains { $0 === cell }
                }
                candidate = view.superview
            }
            return false
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { owner?.remove(self) } else { owner?.update(self) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            owner?.update(self)
        }

        fileprivate func nativeCorners(in list: UIScrollView) -> Corners {
            let row = convert(bounds, to: list)
            let tolerance = 1 / max(1, traitCollection.displayScale)
            var result = Corners()
            var candidate = superview
            func radius(_ view: UIView, _ corner: UIRectCorner, _ layerCorner: CACornerMask) -> CGFloat {
                let layerRadius = view.layer.maskedCorners.contains(layerCorner) ? view.layer.cornerRadius : 0
                return max(view.effectiveRadius(corner: corner), layerRadius)
            }
            while let view = candidate, view !== list {
                // Read the native clipping geometry rather than introducing a
                // new group radius or changing any cell's existing mask.
                if view.clipsToBounds || view.layer.cornerRadius > 0 || view.layer.mask != nil {
                    let rect = view.convert(view.bounds, to: list)
                    if abs(rect.minY - row.minY) <= tolerance {
                        if abs(rect.minX - row.minX) <= tolerance {
                            result.topLeft = max(result.topLeft, radius(view, .topLeft, .layerMinXMinYCorner))
                        }
                        if abs(rect.maxX - row.maxX) <= tolerance {
                            result.topRight = max(result.topRight, radius(view, .topRight, .layerMaxXMinYCorner))
                        }
                    }
                    if abs(rect.maxY - row.maxY) <= tolerance {
                        if abs(rect.minX - row.minX) <= tolerance {
                            result.bottomLeft = max(result.bottomLeft, radius(view, .bottomLeft, .layerMinXMaxYCorner))
                        }
                        if abs(rect.maxX - row.maxX) <= tolerance {
                            result.bottomRight = max(result.bottomRight, radius(view, .bottomRight, .layerMaxXMaxYCorner))
                        }
                    }
                }
                candidate = view.superview
            }
            return result
        }
    }

    private final class Plane: UIView {
        weak var owner: PennedSheetSectionBackgroundOwner?
        weak var list: UIScrollView?
        var surfaces: [String: Surface] = [:]
        private var geometryObservations: [NSKeyValueObservation] = []

        init(owner: PennedSheetSectionBackgroundOwner, list: UIScrollView) {
            self.owner = owner
            self.list = list
            super.init(frame: CGRect(origin: .zero, size: CGSize(width: list.bounds.width,
                height: max(list.bounds.height, list.contentSize.height))))
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            accessibilityIdentifier = "Penned.SectionBackgroundPlane"
            geometryObservations = [
                list.observe(\.bounds) { [weak self] _, _ in self?.setNeedsLayout() },
                list.observe(\.contentSize) { [weak self] _, _ in self?.setNeedsLayout() }
            ]
        }

        required init?(coder: NSCoder) { return nil }

        func detach() {
            geometryObservations.forEach { $0.invalidate() }
            geometryObservations.removeAll()
            surfaces.values.forEach { $0.removeFromSuperview() }
            surfaces.removeAll()
            removeFromSuperview()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            owner?.layout(self)
        }
    }

    private final class Surface: UIView {
        private let materialView: UIView
        private var installedCorners: Corners?

        init(sectionID: String) {
            // Host one canonical material per group, with no cell margins or sizing.
            materialView = UIHostingConfiguration {
                PennedFrostedMaterial(tint: PennedSheetStyle.fieldTint, cornerRadius: 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .margins(.all, 0)
            .minSize(width: 0, height: 0)
            .background { Color.clear }
            .makeContentView()
            super.init(frame: .zero)
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            accessibilityIdentifier = "Penned.SectionBackground.\(sectionID)"
            clipsToBounds = true
            layer.cornerCurve = .continuous
            materialView.backgroundColor = .clear
            materialView.isOpaque = false
            materialView.isUserInteractionEnabled = false
            materialView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(materialView)
        }

        required init?(coder: NSCoder) { return nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            if materialView.frame != bounds { materialView.frame = bounds }
        }

        func apply(frame: CGRect, corners: Corners) {
            if self.frame != frame { self.frame = frame }
            if installedCorners != corners {
                cornerConfiguration = .corners(topLeftRadius: .fixed(Double(corners.topLeft)),
                    topRightRadius: .fixed(Double(corners.topRight)),
                    bottomLeftRadius: .fixed(Double(corners.bottomLeft)),
                    bottomRightRadius: .fixed(Double(corners.bottomRight)))
                installedCorners = corners
            }
        }
    }
}
#endif

extension View {
    @ViewBuilder func pennedSheetGroupedSections() -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        modifier(PennedSheetGroupedSections())
        #else
        self
        #endif
    }

    @ViewBuilder func pennedSheetSectionBackground(_ id: String) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        environment(\.pennedSheetSectionBackgroundID, id)
        #else
        self
        #endif
    }
}
