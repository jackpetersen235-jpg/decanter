import SwiftUI

/// The Frutiger Aero gloss: a four-stop vertical white gradient painted OVER an object's own fill.
///
/// **This is the whole theme.** Every Aero component composes this one modifier — if the stops
/// drift between components the aesthetic collapses, so nothing else is allowed to hand-roll a
/// highlight.
///
/// | Position | White opacity |
/// |---|---|
/// | 0%   | 0.72 |
/// | 48%  | 0.26 |
/// | 49%  | 0.04 |
/// | 100% | 0.18 |
///
/// Two things people "fix" and must not:
///
/// 1. **Stops 2 and 3 sit one percentage point apart on purpose.** That near-discontinuity is the
///    hard specular break across the middle of a 2006 button. Smooth it into a fade and the object
///    stops reading as glossy plastic — no amount of correct colour elsewhere recovers it.
/// 2. **The bottom stop rises back to 0.18.** That is bounce light off the surface below. Dropping
///    it to zero makes the object look like it is falling out of the frame.
///
/// Aero gloss is PAINTED. It is not `.ultraThinMaterial` / `.regularMaterial` / `.glassEffect()` —
/// those refract what is behind them, which is the Liquid Glass idea and the opposite of this one.
/// Mixing them yields a muddy hybrid that reads as neither.
struct AeroGloss: ViewModifier {
    /// Corner radius of the shape the gloss is clipped to. Must match the object's own shape or a
    /// bright sliver leaks past the corners.
    var cornerRadius: CGFloat = 6
    /// Reduce Transparency drops the gloss to a flat wash rather than removing it, so buttons keep
    /// their affordance instead of turning into rectangles.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static let stops: [Gradient.Stop] = [
        .init(color: .white.opacity(0.72), location: 0.00),
        .init(color: .white.opacity(0.26), location: 0.48),
        .init(color: .white.opacity(0.04), location: 0.49),
        .init(color: .white.opacity(0.18), location: 1.00),
    ]

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(reduceTransparency
                      ? AnyShapeStyle(Color.white.opacity(0.12))
                      : AnyShapeStyle(LinearGradient(stops: Self.stops,
                                                     startPoint: .top, endPoint: .bottom)))
                .allowsHitTesting(false)
        }
    }
}

/// Applies the raised panel only in Aero. Liquid Glass has its own depth model and must not get a
/// painted one layered on top.
struct ThemedPanel: ViewModifier {
    var cornerRadius: CGFloat = 12
    var tint: Color = AeroTokens.aqua
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        switch theme {
        case .liquidGlass, .system: content
        case .frutigerAero:         content.modifier(AeroPanel(cornerRadius: cornerRadius, tint: tint))
        }
    }
}

/// A raised, rounded Aero panel — the surface treatment for headers and grouped areas.
///
/// Exists because a flat band of colour meeting the content below in a straight square edge reads
/// as a rendering seam, not as a design. Everything else in this theme is rounded and has depth,
/// so a full-width rectangle is the one element that looks unfinished. This gives the band the
/// same vocabulary as the buttons: rounded corners, a vertical fill, the same painted gloss, a
/// bright top bevel and a hue-matched drop shadow.
struct AeroPanel: ViewModifier {
    var cornerRadius: CGFloat = 12
    var tint: Color = AeroTokens.chromeTop

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    // OPAQUE. The gloss is defined as painting over an object's own fill, so a
                    // translucent one breaks it: the first attempt used a 38%-opacity tint, the sky
                    // showed through, and the 0.72 top stop washed the upper half to near-white
                    // while the lower half stayed mid-blue. It read as two stacked bands rather
                    // than one raised object, and no text colour was legible across both.
                    .fill(LinearGradient(colors: [tint, AeroTokens.chromeBottom],
                                         startPoint: .top, endPoint: .bottom))
            }
            .aeroGloss(cornerRadius: cornerRadius)
            .overlay {
                // Two-tone edge: a bright top rim and a darker lower rim is what makes a surface
                // read as raised rather than as a coloured rectangle with a border.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.85), .black.opacity(0.22)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Hue-matched to the panel, like every other shadow in the theme.
            .shadow(color: AeroTokens.shadow(for: AeroTokens.chromeBottom), radius: 5, x: 0, y: 3)
    }
}

extension View {
    /// Paint the Aero gloss over this view. See `AeroGloss` before changing any number.
    func aeroGloss(cornerRadius: CGFloat = 6) -> some View {
        modifier(AeroGloss(cornerRadius: cornerRadius))
    }

    /// Raised rounded panel — Aero only, a no-op in Liquid Glass.
    func aeroPanel(cornerRadius: CGFloat = 12, tint: Color = AeroTokens.aqua) -> some View {
        modifier(ThemedPanel(cornerRadius: cornerRadius, tint: tint))
    }

    /// The period text treatment: dark type on a light fill gets a 1pt white shadow BELOW it.
    ///
    /// This is what makes 2006 type sit *into* a surface rather than float on top of it. It is a
    /// legibility aid, not a contrast fix — if a pairing fails 4.5:1, darken the fill. Adding more
    /// shadow to rescue contrast produces a smeared, illegible result.
    func aeroTextShadow(_ enabled: Bool = true) -> some View {
        shadow(color: enabled ? .white.opacity(0.9) : .clear, radius: 0, x: 0, y: 1)
    }
}
