import SwiftUI

/// Colour tokens for the Frutiger Aero theme.
///
/// Values live here and nowhere else. Every fill, shadow and accent a component uses must name a
/// token — a component reaching for a literal colour is the first step to the theme drifting apart,
/// and the second is a pile of per-component exceptions.
enum AeroTokens {

    // MARK: Accents

    /// The signature lime, darkened 30% from the period swatch.
    ///
    /// `#6BA821` is the authentic colour but white type on it measures **2.89:1** — a clear fail.
    /// This is `#4B7617`, which measures **5.39:1**. Darkening the fill is the only correct fix:
    /// piling on more text shadow does not raise measured contrast, it just smears the glyphs.
    static let lime = Color(red: 0.294, green: 0.462, blue: 0.091)       // #4B7617
    /// Period "web 2.0" blue, darkened 12% for the same reason as `lime`.
    /// `#1C82C9` measures 4.12:1 against white — large-text-only. This is `#1972B1` at 5.12:1.
    static let aqua = Color(red: 0.097, green: 0.449, blue: 0.695)       // #1972B1

    // MARK: Surfaces

    static let chromeTop = Color(red: 0.93, green: 0.96, blue: 0.99)
    static let chromeBottom = Color(red: 0.80, green: 0.87, blue: 0.94)
    /// Dense screens use a SOLID fill — no gloss, no atmosphere. See `restrainedSurface`.
    static let restrainedSurface = Color(red: 0.96, green: 0.97, blue: 0.98)

    // MARK: Type

    /// Dark ink for light fills. Chosen for contrast, not for period accuracy.
    static let ink = Color(red: 0.09, green: 0.13, blue: 0.17)
    static let inkSecondary = Color(red: 0.32, green: 0.38, blue: 0.44)

    // MARK: Shadows

    /// Shadows take the HUE OF THEIR OBJECT, never neutral gray.
    ///
    /// A lime button casts a dark-lime shadow; a blue one casts dark blue. Neutral shadows are the
    /// single fastest way to flatten this theme into generic 2010s flat design — the coloured
    /// shadow is what makes the object look like tinted plastic sitting on a surface.
    static func shadow(for accent: Color) -> Color {
        Color(nsColor: NSColor(accent).blended(withFraction: 0.62, of: .black) ?? .black)
            .opacity(0.45)
    }

    static let shadowRadius: CGFloat = 3
    static let shadowY: CGFloat = 2

    // MARK: Atmosphere

    /// Haze at the very top of the sky.
    ///
    /// Close to the toolbar's own near-white. Without it the sky began at full-saturation
    /// `skyTop` directly beneath the light toolbar and left a hard horizontal seam across the
    /// window. Real skies wash out toward the top of frame anyway, so this reads as atmosphere
    /// rather than as a fix.
    static let skyHaze = Color(red: 0.90, green: 0.95, blue: 0.99)
    static let skyTop = Color(red: 0.42, green: 0.74, blue: 0.94)
    static let skyBottom = Color(red: 0.82, green: 0.93, blue: 0.98)
    static let grass = Color(red: 0.38, green: 0.68, blue: 0.24)
}
