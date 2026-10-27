import SwiftUI

struct TaskCompletionCircle: View {
    let isChecked: Bool
    var isSkipped = false
    var isEnabled = true
    var ink = VellixSurface.controlInk
    var hitSize: CGFloat = 44
    var alignment: Alignment = .center
    var finish: (_ skipped: Bool) -> Void

    private var isMarked: Bool { isChecked || isSkipped }

    var body: some View {
        ZStack {
            Circle().fill(isMarked ? PennedSheetStyle.accent : .clear)
            Circle().strokeBorder(isMarked ? PennedSheetStyle.accent : ink.opacity(0.55), lineWidth: 2)
            if isMarked {
                LibraryIcon(name: isSkipped ? "xmarkwavy" : "checkwavy", size: 13).foregroundStyle(.white)
            }
        }
        .frame(width: 19, height: 19)
        .frame(width: hitSize, height: hitSize, alignment: alignment)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { value in
            guard isEnabled else { return }
            switch value {
            case .first: finish(true)
            case .second: finish(false)
            }
        })
        .allowsHitTesting(isEnabled)
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isMarked ? "Mark task incomplete" : "Complete task")
        .accessibilityValue(isSkipped ? "Skipped" : isChecked ? "Completed" : "Incomplete")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if isEnabled { finish(false) } }
        .accessibilityAction(named: Text("Skip occurrence")) { if isEnabled { finish(true) } }
    }
}
