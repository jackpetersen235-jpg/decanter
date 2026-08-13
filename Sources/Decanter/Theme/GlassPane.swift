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
/// - **`.clear` plus a scrim, because neither shipped variant is right on its own.** `.clear` is
///   the most transparent and reads beautifully, but text over a busy wallpaper is hard to read.
///   `.regular` fixes legibility and looks too solid. Apple ships nothing in between, so this
///   uses `.clear` and puts a faint adaptive fill under the CONTENT — `scrim`, default 0.14, where
///   0 is pure `.clear` and ~0.30 approaches `.regular`. That is the dial to turn if it ever looks
///   wrong again, rather than swapping variants and overshooting in the other direction.
struct GlassPane: ViewModifier {
    var cornerRadius: CGFloat = 18
    var inset: CGFloat = 10
    /// How much backing sits under the content. 0 = pure `.clear` glass, ~0.30 ≈ `.regular`.
    /// Tuned by eye against the desktop wallpaper; see the note in `body`.
    var scrim: Double = 0.14

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
                // Between the two variants Apple ships. `.clear` alone is beautiful and unreadable
                // over a busy wallpaper; `.regular` is readable but too solid. There is no variant
                // in between, so: take `.clear` for its transparency and slide a faint scrim under
                // the CONTENT (not under the pane) to hold the text up. `scrim` is the dial —
                // 0 is pure `.clear`, ~0.30 approaches `.regular`.
                //
                // `.windowBackgroundColor` rather than black/white so it follows light and dark.
                content
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(scrim)))
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
    func glassPane(cornerRadius: CGFloat = 18, inset: CGFloat = 10,
                   scrim: Double = 0.14) -> some View {
        modifier(GlassPane(cornerRadius: cornerRadius, inset: inset, scrim: scrim))
    }

    /// Give this region a surface in whichever theme needs one.
    func themedPaneSurface(cornerRadius: CGFloat = 18, inset: CGFloat = 10,
                           plainFill: Color? = nil) -> some View {
        modifier(ThemedPaneSurface(cornerRadius: cornerRadius, inset: inset, plainFill: plainFill))
    }
}
