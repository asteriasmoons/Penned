import AppKit
import SwiftUI

struct MacSplitSizing: NSViewRepresentable {
    let sidebarVisible: Bool
    let inspectorVisible: Bool
    @Binding var sidebarWidth: Double
    @Binding var inspectorWidth: Double
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.save = { left, right in
            if let left, abs(sidebarWidth - left) > 0.5 { sidebarWidth = left }
            if let right, abs(inspectorWidth - right) > 0.5 { inspectorWidth = right }
        }
        let mask = (sidebarVisible ? 1 : 0) + (inspectorVisible ? 2 : 0)
        let left = sidebarWidth, right = inspectorWidth
        DispatchQueue.main.async {
            var ancestor = view.superview
            while ancestor != nil && !(ancestor is NSSplitView) { ancestor = ancestor?.superview }
            guard let split = ancestor as? NSSplitView ?? Coordinator.findSplit(view.window?.contentView), coordinator.mask != mask else { return }
            split.layoutSubtreeIfNeeded()
            guard split.bounds.width > 0, split.subviews.count == 1 + (sidebarVisible ? 1 : 0) + (inspectorVisible ? 1 : 0) else { return }
            coordinator.observe(split)
            coordinator.applying = true
            if sidebarVisible { split.setPosition(max(200, min(340, left)), ofDividerAt: 0) }
            if inspectorVisible { split.setPosition(split.bounds.width - max(270, min(390, right)), ofDividerAt: sidebarVisible ? 1 : 0) }
            coordinator.mask = mask; coordinator.applying = false
        }
    }
    @MainActor final class Coordinator: NSObject {
        var mask: Int?
        var applying = false
        weak var split: NSSplitView?
        var save: ((Double?, Double?) -> Void)?
        static func findSplit(_ view: NSView?) -> NSSplitView? {
            guard let view else { return nil }
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { findSplit($0) }.first
        }
        func observe(_ split: NSSplitView) {
            guard self.split !== split else { return }
            NotificationCenter.default.removeObserver(self)
            self.split = split
            NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSSplitView.didResizeSubviewsNotification, object: split)
        }
        @objc private func resized() {
            guard !applying, let mask, let split, split.subviews.count == 1 + (mask & 1 == 1 ? 1 : 0) + (mask & 2 == 2 ? 1 : 0) else { return }
            let left = mask & 1 == 1 ? split.subviews.first?.frame.width : nil
            let right = mask & 2 == 2 ? split.subviews.last?.frame.width : nil
            DispatchQueue.main.async { self.save?(left.map(Double.init), right.map(Double.init)) }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
