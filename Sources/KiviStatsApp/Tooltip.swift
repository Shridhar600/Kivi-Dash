import SwiftUI

/// A tooltip shown on hover, positioned above its content (or below when there
/// is no room above).
///
/// Each hoverable element owns its tooltip rather than sharing one anchored
/// overlay: it keeps positioning local and avoids the coordinate-space plumbing
/// a shared overlay needs. The tooltip has a fixed height so the offset is
/// known without measuring, and it never intercepts the mouse.
struct HoverTip<Content: View>: View {
    let title: String
    var detail: String?
    var preferBelow = false

    @ViewBuilder var content: Content

    @State private var hovering = false

    private var height: CGFloat { detail == nil ? 26 : 40 }

    var body: some View {
        content
            .overlay(alignment: .top) {
                if hovering && !preferBelow {
                    tip.offset(y: -(height + 8))
                }
            }
            .overlay(alignment: .bottom) {
                if hovering && preferBelow {
                    tip.offset(y: height + 8)
                }
            }
            .onHover { inside in hovering = inside }
    }

    private var tip: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        // An overlay is proposed the *content's* size, so `maxWidth: .infinity`
        // would truncate a sparkline tooltip to 44pt and inflate a heatmap
        // tooltip to 309pt. A fixed cap keeps the text intact and guarantees the
        // tooltip is narrower than the 352pt popover, so it cannot be clipped
        // by the window edge.
        .frame(width: 196, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.133, green: 0.157, blue: 0.184))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.line, lineWidth: 1)
        )
        .allowsHitTesting(false)
    }
}
