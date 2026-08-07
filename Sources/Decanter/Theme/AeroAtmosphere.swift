import SwiftUI

/// The sky-and-bubbles backdrop for the Frutiger Aero theme.
///
/// Hard rules this enforces, all of them for the same reason — decoration must never compete with
/// or obscure a control:
///
/// - It renders **strictly behind** window chrome. Nothing decorative overlaps a control or label.
/// - Bubbles are `allowsHitTesting(false)` and `accessibilityHidden(true)`. They cannot be clicked,
///   focused, or read by VoiceOver, and they never react to input.
/// - **Nothing moves.** Bubbles are placed deterministically and drawn once. The 2006 originals
///   were static; animating them would read as a screensaver, and Reduce Motion would have to
///   switch it off anyway.
/// - It does not draw at all on dense screens (see the `restrained` variant), where an atmosphere
///   behind eight-plus rows of text is pure noise.
struct AeroAtmosphere: View {
    /// Bubbles are seeded from a fixed table rather than `random()` so the layout is identical on
    /// every launch and every redraw. A view body that produces new randomness each time it runs
    /// makes the backdrop flicker as SwiftUI re-evaluates.
    /// Positions are kept OUT of the two regions that hold text: the sidebar's list (roughly the
    /// left quarter) and the detail pane's label column (upper-middle). Bubbles are pushed to the
    /// margins, the corners and the empty lower half instead.
    ///
    /// This matters more now that the backdrop runs the full width of the window. It has to, or
    /// the floating glass panes have nothing to refract — but texture that gives glass its edge
    /// also sits behind body copy, and a bubble rim crossing a row of text is exactly the kind of
    /// decoration that must never compete with a label.
    private static let bubbles: [(x: CGFloat, y: CGFloat, r: CGFloat, o: Double)] = [
        (0.16, 0.05, 26, 0.18),      // above the sidebar list, beside the traffic lights
        (0.06, 0.90, 34, 0.15),      // below it, in the footer margin
        (0.36, 0.92, 30, 0.14),      // empty lower band of the detail pane
        (0.53, 0.85, 22, 0.16),
        (0.68, 0.95, 18, 0.13),
        (0.72, 0.08, 40, 0.14),      // top-right, clear of the header panel's text
        (0.88, 0.26, 24, 0.18),
        (0.94, 0.62, 32, 0.15),      // right margin, past the value column
        (0.83, 0.88, 20, 0.12),
    ]

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Three stops, not two. The first is haze at the top so the sky meets the light
                // toolbar without a visible seam — starting straight at `skyTop` put a hard
                // horizontal edge across the window where the two met.
                LinearGradient(stops: [
                    .init(color: AeroTokens.skyHaze, location: 0.00),
                    .init(color: AeroTokens.skyTop, location: 0.22),
                    .init(color: AeroTokens.skyBottom, location: 1.00),
                ], startPoint: .top, endPoint: .bottom)

                if !reduceTransparency {
                    ForEach(Array(Self.bubbles.enumerated()), id: \.offset) { _, b in
                        Circle()
                            .fill(
                                RadialGradient(colors: [.white.opacity(b.o * 1.6),
                                                        .white.opacity(b.o * 0.25)],
                                               center: .init(x: 0.35, y: 0.3),
                                               startRadius: 1, endRadius: b.r)
                            )
                            .overlay {
                                Circle().strokeBorder(.white.opacity(b.o), lineWidth: 1)
                            }
                            .frame(width: b.r * 2, height: b.r * 2)
                            .position(x: geo.size.width * b.x, y: geo.size.height * b.y)
                    }

                    // A soft green horizon, the period's other signature. Kept low and faint so it
                    // never rises far enough to sit behind body text.
                    LinearGradient(colors: [.clear, AeroTokens.grass.opacity(0.55)],
                                   startPoint: .center, endPoint: .bottom)
                        .frame(height: geo.size.height * 0.32)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.84)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }
}

/// Places the active theme's backdrop behind a view.
///
/// `restrained` is the dense-screen variant from the theme's own rules: settings, DLL overrides,
/// logs — anything past roughly eight rows — get a solid fill, no gloss on rows, and no atmosphere.
/// Gloss survives only on a bottom action bar.
struct ThemedBackground: ViewModifier {
    var restrained: Bool = false
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        switch theme {
        case .liquidGlass:
            content
        case .frutigerAero:
            if restrained {
                content
                    .aeroLightChrome()
                    .background(AeroTokens.restrainedSurface)
            } else {
                // Atmosphere directly behind content — no opaque plate over it.
                //
                // An earlier version put a 93%-opaque chrome plate between the two. It fixed
                // legibility but muted the sky to almost nothing, which loses the point of the
                // theme. What actually made the unplated version unreadable was not the sky: it
                // was the text still being coloured for DARK chrome. Setting the ink here is the
                // real fix, and it keeps the atmosphere at full strength.
                content
                    .aeroLightChrome()
                    .background { AeroAtmosphere() }
            }
        }
    }
}

/// The backdrop ALONE, with no ink or chrome changes.
///
/// Split out from `ThemedBackground` because the two now belong at different levels: the atmosphere
/// has to span the whole window so the floating glass panes have something to refract, while the
/// ink and light-chrome treatment belongs only to the detail column — applying it window-wide would
/// force the sidebar's own text to a colour chosen for a different surface.
struct ThemedAtmosphere: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        switch theme {
        case .liquidGlass:  content
        case .frutigerAero: content.background { AeroAtmosphere() }
        }
    }
}

/// The ink and light-chrome treatment ALONE, with no backdrop.
///
/// Paired with `ThemedAtmosphere`: the backdrop spans the window, this applies only to the surface
/// whose colours it was chosen against. Forcing it window-wide would recolour the sidebar's text
/// for a surface it no longer sits on.
struct AeroInk: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        switch theme {
        case .liquidGlass:  content
        case .frutigerAero: content.aeroLightChrome()
        }
    }
}

extension View {
    /// Aero ink + light system chrome, without painting a backdrop. No-op in Liquid Glass.
    func aeroInk() -> some View {
        modifier(AeroInk())
    }

    /// Paint the theme's backdrop behind this view, changing nothing else.
    func themedAtmosphere() -> some View {
        modifier(ThemedAtmosphere())
    }

    /// - Parameter restrained: pass `true` for dense screens (see `ThemedBackground`).
    func themedBackground(restrained: Bool = false) -> some View {
        modifier(ThemedBackground(restrained: restrained))
    }

    /// Force system-drawn chrome into its light appearance and set the Aero ink.
    ///
    /// Setting `foregroundStyle` alone was not enough and produced an unreadable Configuration
    /// tab: `Form(.grouped)`, pickers and toggles draw their own backgrounds from the SYSTEM
    /// appearance, which on this Mac is dark. Dark Aero ink then landed on dark system rows.
    ///
    /// Aero is inherently a light aesthetic — sky, chrome, white gloss — so the fix is one lever
    /// rather than a per-control fight: tell the whole subtree it is in light mode, and every
    /// system-drawn surface comes back light, which is what the ink was chosen against.
    /// `scrollContentBackground(.hidden)` then lets the theme's own surface show through the form.
    func aeroLightChrome() -> some View {
        self
            .environment(\.colorScheme, .light)
            .foregroundStyle(AeroTokens.ink)
            .scrollContentBackground(.hidden)
    }
}
