import SwiftUI

struct PennedLibraryLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let dotCount = 12

    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion || scenePhase != .active)) { context in
                let activeDot = Int(context.date.timeIntervalSinceReferenceDate / 0.08) % dotCount
                ZStack {
                    ForEach(0..<dotCount, id: \.self) { index in
                        let distance = (activeDot - index + dotCount) % dotCount
                        Circle()
                            .fill(VellixSurface.violet)
                            .opacity(reduceMotion ? 0.8 : 1 - Double(distance) / Double(dotCount) * 0.8)
                            .frame(width: 4.5, height: 4.5)
                            .offset(y: -15)
                            .rotationEffect(.degrees(Double(index) * 360 / Double(dotCount)))
                    }
                }
                .frame(width: 40, height: 40)
            }
            Text("Opening library")
                .font(.system(size: 15, weight: .medium, design: .rounded))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening library")
    }
}
