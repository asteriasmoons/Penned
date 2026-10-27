import SwiftUI

struct MacSlider: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    var step: Double?
    @Environment(\.isEnabled) private var enabled
    init(value: Binding<Double>, in bounds: ClosedRange<Double>, step: Double? = nil) { _value = value; self.bounds = bounds; self.step = step }
    private var fraction: Double { min(1, max(0, (value - bounds.lowerBound) / max(0.0001, bounds.upperBound - bounds.lowerBound))) }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 18)
            ZStack(alignment: .leading) {
                Capsule().fill(VellixSurface.subtleFill).frame(height: 5)
                Capsule().fill(VellixSurface.violet).frame(width: 9 + width * fraction, height: 5)
                Circle().fill(VellixSurface.ink).frame(width: 16, height: 16).offset(x: width * fraction)
            }.frame(maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    set(bounds.lowerBound + min(1, max(0, (event.location.x - 9) / width)) * (bounds.upperBound - bounds.lowerBound))
                })
        }.frame(height: 22).opacity(enabled ? 1 : 0.4)
            .accessibilityElement().accessibilityValue(value.formatted(.number.precision(.fractionLength(0...2))))
            .accessibilityAdjustableAction { direction in set(value + (direction == .increment ? 1 : -1) * increment) }
            .focusable().onKeyPress(.rightArrow) { set(value + increment); return .handled }
            .onKeyPress(.leftArrow) { set(value - increment); return .handled }
    }
    private var increment: Double { step ?? (bounds.upperBound - bounds.lowerBound) / 100 }
    private func set(_ next: Double) {
        guard enabled else { return }
        let result = step.map { bounds.lowerBound + ((next - bounds.lowerBound) / $0).rounded() * $0 } ?? next
        value = min(bounds.upperBound, max(bounds.lowerBound, result))
    }
}

struct MacStepper: View {
    let title: String
    @Binding var value: Int
    let bounds: ClosedRange<Int>
    init(_ title: String, value: Binding<Int>, in bounds: ClosedRange<Int>) { self.title = title; _value = value; self.bounds = bounds }
    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            MacIconButton("Decrease " + title, icon: "chevleft") { value = max(bounds.lowerBound, value - 1) }.disabled(value <= bounds.lowerBound)
            Text(value.formatted()).monospacedDigit().frame(minWidth: 28)
            MacIconButton("Increase " + title, icon: "chevright") { value = min(bounds.upperBound, value + 1) }.disabled(value >= bounds.upperBound)
        }.font(.system(size: 12, weight: .semibold, design: .rounded))
    }
}

struct MacDatePicker: View {
    let title: String
    @Binding var selection: Date
    var displayedComponents: DatePickerComponents = [.date, .hourAndMinute]
    @State private var expanded = false
    @State private var month: Date
    private var calendar: Calendar { .autoupdatingCurrent }
    init(_ title: String, selection: Binding<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.title = title; _selection = selection; self.displayedComponents = displayedComponents; _month = State(initialValue: selection.wrappedValue)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if displayedComponents.contains(.date) {
                    Button { month = selection; expanded.toggle() } label: {
                        HStack {
                            LibraryIcon(name: "blackcal", size: 16)
                            Text(selection.formatted(date: .abbreviated, time: .omitted)).frame(maxWidth: .infinity, alignment: .leading)
                            LibraryIcon(name: "chevdown", size: 10)
                        }
                    }.popover(isPresented: $expanded) { calendarPanel.padding(14).frame(width: 300) }
                }
                if displayedComponents.contains(.hourAndMinute) {
                    MacOptionPicker("Hour", selection: time(.hour), options: Array(0...23), label: { String(format: "%02d", $0) }).frame(width: 68)
                    Text(":")
                    MacOptionPicker("Minute", selection: time(.minute), options: Array(0...59), label: { String(format: "%02d", $0) }).frame(width: 68)
                }
            }
        }.accessibilityLabel(title)
    }
    private var calendarPanel: some View {
        VStack(spacing: 10) {
            HStack {
                MacIconButton("Previous Month", icon: "chevleft") { month = calendar.date(byAdding: .month, value: -1, to: month) ?? month }
                Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 13, weight: .bold, design: .rounded)).frame(maxWidth: .infinity)
                MacIconButton("Next Month", icon: "chevright") { month = calendar.date(byAdding: .month, value: 1, to: month) ?? month }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(0..<7, id: \.self) { offset in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + offset) % 7]).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(0..<42, id: \.self) { index in
                    if let date = date(at: index) {
                        let active = calendar.isDate(date, inSameDayAs: selection)
                        Button { choose(date); expanded = false } label: {
                            Text(calendar.component(.day, from: date).formatted()).font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity).frame(height: 29)
                                .foregroundStyle(active ? VellixSurface.violet : VellixSurface.ink)
                                .background(active ? VellixSurface.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).accessibilityLabel(date.formatted(date: .complete, time: .omitted)).accessibilityAddTraits(active ? .isSelected : [])
                    } else { Color.clear.frame(height: 29) }
                }
            }
            Button("Today") { choose(Date()); expanded = false }
        }.foregroundStyle(VellixSurface.ink).macApplicationControls()
    }
    private func date(at index: Int) -> Date? {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let days = calendar.range(of: .day, in: .month, for: month) else { return nil }
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let day = index - offset + 1
        guard days.contains(day) else { return nil }
        return calendar.date(byAdding: .day, value: day - 1, to: start)
    }
    private func choose(_ date: Date) {
        selection = calendar.date(bySettingHour: calendar.component(.hour, from: selection), minute: calendar.component(.minute, from: selection), second: 0, of: date) ?? date
    }
    private func time(_ component: Calendar.Component) -> Binding<Int> {
        Binding(get: { calendar.component(component, from: selection) }, set: { value in
            selection = calendar.date(bySettingHour: component == .hour ? value : calendar.component(.hour, from: selection),
                minute: component == .minute ? value : calendar.component(.minute, from: selection), second: 0, of: selection) ?? selection
        })
    }
}
