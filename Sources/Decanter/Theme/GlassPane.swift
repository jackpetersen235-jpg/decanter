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
/// - **`.regular`, not `.clear`.** `.clear` is the most transparent variant, and over a busy
///   wallpaper it is beautiful and hard to read — the trade-off this file used to note and then
///   take the wrong side of. `.regular` is the same material with the same rim refraction, just
///   less see-through, and it is Apple's variant for content that must stay legible against
///   anything. Switch back to `.clear` only if the panes ever sit over something plain.
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
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
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

/// A glass pane in Liquid Glass; nothing in Aero, where the atmosphere is already the surface.
///
/// Necessary once the window is genuinely clear: a pane with no background of its own would put
/// its text directly on the desktop wallpaper. Every region that holds content needs a surface.
struct ThemedPaneSurface: ViewModifier {
    var cornerRadius: CGFloat = 18
    var inset: CGFloat = 10
    /// Standard's fill for this region, if it needs one. The sidebar does — a plain column with no
    /// fill does not read as a sidebar. The detail pane does not; the opaque window is its surface.
    var plainFill: Color?
    @Environment(\.appTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        switch theme {
        case .frutigerAero:
            content
        case .liquidGlass:
            content.glassPane(cornerRadius: cornerRadius, inset: inset)
        case .system:
            // Full height, no inset, no rounding — an ordinary macOS sidebar. The floating inset
            // pane is a Liquid Glass idea (it exists to expose the rim that does the refracting)
            // and has no business in the plain appearance.
            if let plainFill {
                content.background(plainFill)
            } else {
                content
            }
        }
    }
}

extension View {
    /// Float this pane on Liquid Glass. See `GlassPane` — the inset is load-bearing, not styling.
    func glassPane(cornerRadius: CGFloat = 18, inset: CGFloat = 10) -> some View {
        modifier(GlassPane(cornerRadius: cornerRadius, inset: inset))
    }

    /// Give this region a surface in whichever theme needs one.
    func themedPaneSurface(cornerRadius: CGFloat = 18, inset: CGFloat = 10,
                           plainFill: Color? = nil) -> some View {
        modifier(ThemedPaneSurface(cornerRadius: cornerRadius, inset: inset, plainFill: plainFill))
    }
}
