import AppKit
import SwiftUI

struct LibraryIcon: View {
    var name: String
    var size: CGFloat = 20
    var body: some View {
        let icon = VellixAssetIcon(name: name)
        Group {
            if let symbol = icon.systemName { Image(systemName: symbol).resizable() }
            else { Image(nsImage: MacIconImages.image(name, size: size)).renderingMode(.template).resizable() }
        }.scaledToFit().frame(width: size, height: size)
    }
}

@MainActor private enum MacIconImages {
    static let cache = NSCache<NSString, NSImage>()
    static func image(_ name: String, size: CGFloat) -> NSImage {
        let key = "\(name)-\(size)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let source = NSImage(named: name) ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(named: "linedpages") ?? NSImage(size: NSSize(width: size, height: size))
        // AppKit menus/pickers consume intrinsic NSImage size, not SwiftUI's frame.
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in source.draw(in: rect); return true }
        image.isTemplate = true
        cache.setObject(image, forKey: key)
        return image
    }
}

struct MacIconButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    init(_ title: String, icon: String, action: @escaping () -> Void) { self.title = title; self.icon = icon; self.action = action }
    var body: some View {
        Button(action: action) { LibraryIcon(name: icon, size: 17).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(VellixSurface.ink).help(title).accessibilityLabel(title)
    }
}

struct MacInspectorSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(VellixSurface.secondaryInk).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
    }
}

enum CalendarStyle { static let accent = VellixSurface.lilac }
extension CalendarEvent { var calendarColor: Color { Color(red: colorRed, green: colorGreen, blue: colorBlue) } }
