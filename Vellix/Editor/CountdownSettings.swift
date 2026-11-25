import CoreGraphics
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct CountdownSettings: Equatable, Sendable {
    var width: String
    var icon: String
    var imagePath: String?
    var originalIconColors: Bool
    var title: String
    var targetDate: Date?
    var showIcon: Bool
    var showTitle: Bool
    var showTargetDate: Bool
    var showMonths: Bool
    var showWeeks: Bool
    var showDays: Bool
    var showHours: Bool
    var showMinutes: Bool
    var completionMessage: String
    var countUp: Bool
    var backgroundColor: String
    var borderColor: String
    var borderWidth: Int
    var iconColor: String
    var titleColor: String
    var numberColor: String
    var unitLabelColor: String
    var tileColor: String

    init(_ attrs: [String: Any]) {
        width = attrs["width"] as? String == "half" ? "half" : "full"
        icon = String((attrs["icon"] as? String ?? "clockwavy").prefix(240))
        imagePath = (attrs["imagePath"] as? String).flatMap { AttachmentStore.validRelativePath($0) ? $0 : nil }
        originalIconColors = attrs["originalIconColors"] as? Bool ?? false
        title = String((attrs["title"] as? String ?? "Countdown").prefix(240))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        targetDate = (attrs["targetDate"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        showIcon = attrs["showIcon"] as? Bool ?? true
        showTitle = attrs["showTitle"] as? Bool ?? true
        showTargetDate = attrs["showTargetDate"] as? Bool ?? true
        showMonths = attrs["showMonths"] as? Bool ?? true
        showWeeks = attrs["showWeeks"] as? Bool ?? true
        showDays = attrs["showDays"] as? Bool ?? true
        showHours = attrs["showHours"] as? Bool ?? true
        showMinutes = attrs["showMinutes"] as? Bool ?? true
        completionMessage = String((attrs["completionMessage"] as? String ?? "Time's up!").prefix(1000))
        countUp = attrs["countUp"] as? Bool ?? false
        backgroundColor = GridCardSettings.opaqueHex(attrs["backgroundColor"], fallback: "#151518")
        borderColor = GridCardSettings.opaqueHex(attrs["borderColor"], fallback: "#65606d")
        borderWidth = min(8, max(0, (attrs["borderWidth"] as? NSNumber)?.intValue ?? 2))
        iconColor = GridCardSettings.opaqueHex(attrs["iconColor"], fallback: "#c998f5")
        titleColor = GridCardSettings.opaqueHex(attrs["titleColor"], fallback: "#ffffff")
        numberColor = GridCardSettings.opaqueHex(attrs["numberColor"], fallback: "#ffffff")
        unitLabelColor = GridCardSettings.opaqueHex(attrs["unitLabelColor"], fallback: "#c8c4cf")
        tileColor = GridCardSettings.opaqueHex(attrs["tileColor"], fallback: "#302a39")
    }

    var payload: [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["width": width, "icon": icon, "imagePath": imagePath.map { $0 as Any } ?? NSNull(),
            "originalIconColors": originalIconColors, "title": String(title.prefix(240)),
            "targetDate": targetDate.map { formatter.string(from: $0) as Any } ?? NSNull(),
            "showIcon": showIcon, "showTitle": showTitle, "showTargetDate": showTargetDate,
            "showMonths": showMonths, "showWeeks": showWeeks, "showDays": showDays, "showHours": showHours, "showMinutes": showMinutes,
            "completionMessage": String(completionMessage.prefix(1000)), "countUp": countUp,
            "backgroundColor": backgroundColor, "borderColor": borderColor, "borderWidth": borderWidth,
            "iconColor": iconColor, "titleColor": titleColor, "numberColor": numberColor, "unitLabelColor": unitLabelColor, "tileColor": tileColor]
    }

    var hasIcon: Bool { imagePath != nil || !icon.isEmpty }

    var enabledUnits: [(String, Calendar.Component)] {
        let values: [(String, Calendar.Component, Bool)] = [("Months", .month, showMonths), ("Weeks", .weekOfYear, showWeeks),
            ("Days", .day, showDays), ("Hours", .hour, showHours), ("Minutes", .minute, showMinutes)]
        return values.compactMap { label, component, shown in shown ? (label, component) : nil }
    }

    func isComplete(at now: Date) -> Bool { targetDate.map { now >= $0 } ?? false }

    func timeRows(at now: Date) -> [[CountdownUnitValue]] {
        let enabled = enabledUnits
        guard !enabled.isEmpty, !isComplete(at: now) || countUp else { return [] }
        let complete = isComplete(at: now)
        let start = complete ? targetDate ?? now : now, end = complete ? now : targetDate ?? now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents(Set(enabled.map { $0.1 }), from: start, to: end)
        let values = enabled.map { CountdownUnitValue(unit: $0.0, value: max(0, components.value(for: $0.1) ?? 0)) }
        let count = Int(ceil(Double(values.count) / Double(width == "half" ? 3 : 5)))
        let base = values.count / count, extra = values.count % count
        var offset = 0
        return (0..<count).map { index in
            let size = base + (index < extra ? 1 : 0)
            defer { offset += size }
            return Array(values[offset..<(offset + size)])
        }
    }
}

nonisolated struct CountdownUnitValue: Equatable, Sendable {
    let unit: String
    let value: Int
}

struct CountdownSettingsRequest: Identifiable, Equatable {
    let id = UUID()
    let blockID: String
    let settings: CountdownSettings
}

struct CountdownSettingsSheet: View {
    private enum Field: Hashable { case title, message }
    let request: CountdownSettingsRequest
    let onSave: (CountdownSettings, Data?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @FocusState private var focusedField: Field?
    @State private var draft: CountdownSettings
    @State private var iconPicker = false
    @State private var photo: PhotosPickerItem?
    @State private var pickingFile = false
    @State private var imageData: Data?
    @State private var image: CGImage?
    @State private var saving = false
    @State private var error: String?
    @State private var defaultDate = Date().addingTimeInterval(86400)

    init(request: CountdownSettingsRequest, onSave: @escaping (CountdownSettings, Data?) async throws -> Void) {
        self.request = request; self.onSave = onSave
        _draft = State(initialValue: request.settings)
    }

    private func color(_ path: WritableKeyPath<CountdownSettings, String>) -> Binding<Color> {
        Binding(get: { Color(vellixHex: draft[keyPath: path]) }, set: {
            draft[keyPath: path] = $0.vellixHexString(fallback: draft[keyPath: path])
            if path == \.iconColor { draft.originalIconColors = false }
        })
    }

    private var existingImage: CGImage? {
        WashiTapePreview.documentImage(path: draft.imagePath, attachments: environment.attachments, store: environment.attachmentStore)
    }

    private func source(_ title: String, icon: String) -> some View {
        Label { Text(title) } icon: { LibraryIcon(name: icon, size: 20) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).contentShape(Rectangle()).pennedSheetField()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        CountdownWidgetPreview(settings: draft, iconImage: image ?? existingImage).frame(maxWidth: .infinity)
                        if draft.width == "half" { Color.clear.frame(maxWidth: .infinity).frame(height: 1) }
                    }
                    Picker("Size", selection: $draft.width) {
                        Text("Half Size").tag("half"); Text("Full Size").tag("full")
                    }.pickerStyle(.segmented)
                    TextField("Title", text: $draft.title).focused($focusedField, equals: .title).padding(12).pennedSheetField()
                    DatePicker("Target Date and Time", selection: Binding(get: { draft.targetDate ?? defaultDate }, set: { draft.targetDate = $0 }),
                        displayedComponents: [.date, .hourAndMinute]).padding(12).pennedSheetField()
                    Button { focusedField = nil; iconPicker = true } label: {
                        source("Icon Library", icon: "sparkle")
                    }.buttonStyle(.plain)
                    PhotosPicker(selection: $photo, matching: .images) {
                        source("Photo Library", icon: "imagesign")
                    }.buttonStyle(.plain)
                    Button { focusedField = nil; pickingFile = true } label: {
                        source("Choose File", icon: "folderhand")
                    }.buttonStyle(.plain)
                    if draft.imagePath != nil || imageData != nil {
                        Button("Remove Custom Image", role: .destructive, action: clearImage)
                    }
                    Toggle("Keep Original Colors", isOn: $draft.originalIconColors).padding(12).pennedSheetField()
                    Group {
                        Toggle("Show Icon", isOn: $draft.showIcon)
                        Toggle("Show Title", isOn: $draft.showTitle)
                        Toggle("Show Target Date", isOn: $draft.showTargetDate)
                        Toggle("Months", isOn: $draft.showMonths)
                        Toggle("Weeks", isOn: $draft.showWeeks)
                        Toggle("Days", isOn: $draft.showDays)
                        Toggle("Hours", isOn: $draft.showHours)
                        Toggle("Minutes", isOn: $draft.showMinutes)
                    }.padding(12).pennedSheetField()
                    TextField("Completion Message", text: $draft.completionMessage, axis: .vertical)
                        .focused($focusedField, equals: .message).lineLimit(2...4).padding(12).pennedSheetField()
                    Toggle("Count Up After Completion", isOn: $draft.countUp).padding(12).pennedSheetField()
                    Group {
                        ColorPicker("Background", selection: color(\.backgroundColor), supportsOpacity: false)
                        ColorPicker("Border Color", selection: color(\.borderColor), supportsOpacity: false)
                        Stepper("Border Thickness: \(draft.borderWidth)", value: $draft.borderWidth, in: 0...8)
                        ColorPicker("Icon Color", selection: color(\.iconColor), supportsOpacity: false)
                        ColorPicker("Title Color", selection: color(\.titleColor), supportsOpacity: false)
                        ColorPicker("Number Color", selection: color(\.numberColor), supportsOpacity: false)
                        ColorPicker("Unit Label Color", selection: color(\.unitLabelColor), supportsOpacity: false)
                        ColorPicker("Time-Tile Background", selection: color(\.tileColor), supportsOpacity: false)
                    }.padding(12).pennedSheetField()
                }.padding(18)
            }
            .scrollDismissesKeyboard(.interactively).disabled(saving)
            .pennedSheet(title: "Countdown Settings", closeDisabled: saving, close: { dismiss() }) {
                #if os(iOS)
                PennedSheetKeyboardDismissButton { focusedField = nil }.disabled(saving)
                #endif
                Button("Done", action: save).disabled(saving)
            }
        }
        .interactiveDismissDisabled(saving)
        .sheet(isPresented: $iconPicker) {
            VellixIconLibraryPicker(title: "Countdown Icon", selectedIcon: draft.icon) { icon in
                draft.icon = icon.name; clearImage(); iconPicker = false
            }
            #if os(macOS)
                .frame(width: 540, height: 600)
            #endif
        }
        .task(id: photo) {
            guard let photo else { return }
            focusedField = nil
            await load {
                guard let bytes = try await photo.loadTransferable(type: Data.self) else {
                    throw VellixError.attachmentImport("The photo could not be loaded.")
                }
                return bytes
            }
            self.photo = nil
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.image]) { result in
            Task {
                await load {
                    let url = try result.get()
                    return try await Task.detached(priority: .userInitiated) { try CustomCalloutIconImage.readFile(url) }.value
                }
            }
        }
        .alert("Countdown Settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func clearImage() {
        draft.imagePath = nil
        imageData = nil
        image = nil
    }

    private func load(_ read: () async throws -> Data) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let input = try await read()
            let prepared = try await Task.detached(priority: .userInitiated) {
                try CustomCalloutIconImage.prepare(input, removeHairlines: false)
            }.value
            try Task.checkCancellation()
            image = CustomCalloutIconImage.image(prepared)
            imageData = prepared
            draft.imagePath = nil
            draft.originalIconColors = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard !saving else { return }
        focusedField = nil; saving = true
        Task { @MainActor in
            defer { saving = false }
            do { try await onSave(draft, imageData); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct CountdownIcon: View {
    let settings: CountdownSettings
    var image: CGImage?
    var size: CGFloat = 22

    var body: some View {
        IconCalloutGlyph(settings: calloutSettings, image: image, size: size, originalLibraryColors: settings.originalIconColors)
    }

    private var calloutSettings: IconCalloutSettings {
        var values = settings.payload
        values["imageTint"] = settings.originalIconColors ? nil : settings.iconColor
        return IconCalloutSettings(values)
    }
}

struct CountdownWidgetPreview: View {
    let settings: CountdownSettings
    var iconImage: CGImage?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            DocumentWidgetFrame(mode: settings.width, background: settings.backgroundColor, border: settings.borderColor, borderWidth: settings.borderWidth) { metrics in
                let rows = settings.timeRows(at: context.date)
                let hasHeader = (settings.showIcon && (settings.hasIcon || iconImage != nil)) || (settings.showTitle && !settings.title.isEmpty) || (settings.showTargetDate && settings.targetDate != nil)
                let hasCompletion = settings.isComplete(at: context.date) && !settings.completionMessage.isEmpty
                VStack(alignment: .leading, spacing: metrics.spacing) {
                    if hasHeader {
                        HStack(spacing: metrics.spacing) {
                            if settings.showIcon && (settings.hasIcon || iconImage != nil) {
                                CountdownIcon(settings: settings, image: iconImage, size: metrics.compact ? 18 : 22)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                if settings.showTitle && !settings.title.isEmpty {
                                    Text(settings.title).font(.system(size: metrics.compact ? 14 : 16, weight: .black, design: .rounded))
                                        .foregroundStyle(Color(vellixHex: settings.titleColor)).lineLimit(1).minimumScaleFactor(0.75)
                                }
                                if settings.showTargetDate, let target = settings.targetDate {
                                    Text(target.formatted(date: .abbreviated, time: .shortened)).font(.system(size: metrics.compact ? 9 : 10, design: .rounded))
                                        .foregroundStyle(Color(vellixHex: settings.unitLabelColor)).lineLimit(2)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    }
                    if hasCompletion {
                        Text(settings.completionMessage).font(.system(size: rows.isEmpty && !metrics.compact ? 14 : 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(vellixHex: settings.titleColor)).lineLimit(rows.isEmpty ? 3 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                    }
                    if !rows.isEmpty {
                        GeometryReader { remaining in
                            let rowHeight = max(0, (remaining.size.height - CGFloat(rows.count - 1) * metrics.spacing) / CGFloat(rows.count))
                            VStack(spacing: metrics.spacing) {
                                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                    HStack(spacing: metrics.keyGap) {
                                        ForEach(row, id: \.unit) { item in
                                            CountdownUnitTile(settings: settings, item: item)
                                        }
                                    }.frame(height: rowHeight)
                                }
                            }.frame(width: remaining.size.width, height: remaining.size.height, alignment: .topLeading)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.allowsHitTesting(false)
    }
}

private struct CountdownUnitTile: View {
    let settings: CountdownSettings
    let item: CountdownUnitValue

    var body: some View {
        GeometryReader { tile in
            let inset = max(2, min(6, min(tile.size.width, tile.size.height) * 0.06))
            let gap = max(2, min(6, tile.size.height * 0.04))
            let width = max(1, tile.size.width - inset * 2)
            let height = max(1, tile.size.height - inset * 2)
            let unitSize = max(5, min(15, max(8, min(tile.size.width * 0.22, tile.size.height * 0.16)), width / CGFloat(max(1, item.unit.count)) / 0.56))
            let numberSize = max(5, min(52, max(16, min(tile.size.width * 0.52, tile.size.height * 0.44)),
                width / CGFloat(max(1, String(item.value).count)) / 0.68, (height - gap - unitSize * 1.2) / 1.1))
            VStack(spacing: gap) {
                Text(String(item.value)).font(.system(size: numberSize, weight: .black, design: .rounded))
                    .foregroundStyle(Color(vellixHex: settings.numberColor)).lineLimit(1).minimumScaleFactor(0.25)
                Text(item.unit).font(.system(size: unitSize, design: .rounded))
                    .foregroundStyle(Color(vellixHex: settings.unitLabelColor)).lineLimit(1).minimumScaleFactor(0.5)
            }.frame(width: width, height: height).padding(inset)
        }
        .background(Color(vellixHex: settings.tileColor), in: RoundedRectangle(cornerRadius: 6))
    }
}
