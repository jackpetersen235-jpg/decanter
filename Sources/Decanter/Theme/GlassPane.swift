import SwiftUI

/// A floating, inset pane of Liquid Glass.
///
/// **The effect lives in the edges.** Liquid Glass reads as glass because its rim bends and
/// magnifies whatever is behind it, with colour fringing along the border and a clear centre. A
/// full-bleed pane that meets the window on all four sides has no visible rim, so all of that is
/// clipped away and what remains is a flat tint — which is exactly how the first sidebar attempt
/// looked, regardless of which `Glass` variant was used.
///
/// So this insets the pane and rounds it, giving the material four edges to refract along. Two
/// other requirements follow from the same idea:
///
/// - Something with texture must sit behind it. Glass over a flat fill has nothing to bend.
/// - `.clear` is the right variant here: high transparency, so the background reads through the
///   middle and the rim does the work. `.regular` is for small controls that need to stay legible
///   against anything.
struct GlassPane: ViewModifier {
    var cornerRadius: CGFloat = 18
    var inset: CGFloat = 10

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                // Opaque, not thinner glass.
                content
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor)))
            } else if #available(macOS 26.0, *) {
                content
                    .glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
            } else {
                content
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.28), lineWidth: 0.75)
                    }
            }
        }
        // Otherwise the List paints an opaque backdrop and the glass never shows.
        .scrollContentBackground(.hidden)
        .padding(inset)
    }
}

extension View {
    /// Float this pane on Liquid Glass. See `GlassPane` — the inset is load-bearing, not styling.
    func glassPane(cornerRadius: CGFloat = 18, inset: CGFloat = 10) -> some View {
        modifier(GlassPane(cornerRadius: cornerRadius, inset: inset))
    }
}
