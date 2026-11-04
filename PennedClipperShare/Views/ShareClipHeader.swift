import SwiftUI

/// Header for the Penned Share Extension clipping sheet.
struct ShareClipHeader: View {
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Save to Penned")
                    .font(.headline)
                Text("Web Clipper")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close clipper")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
