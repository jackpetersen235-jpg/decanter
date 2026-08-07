import SwiftUI

/// A glossy Frutiger Aero button: coloured fill, painted gloss, hue-matched shadow.
struct AeroButtonStyle: ButtonStyle {
    var accent: Color = AeroTokens.aqua
    /// Prominent buttons carry a coloured fill; ordinary ones a pale chrome fill with dark type.
    var prominent: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var radius: CGFloat { 6 }

    func makeBody(configuration: Configuration) -> some View {
        let fill = prominent ? accent : AeroTokens.chromeTop
        // Increase Contrast darkens the fill rather than adding text shadow. Shadow does not raise
        // measured contrast at all — it only smears the glyph edges.
        let effectiveFill = contrast == .increased
            ? Color(nsColor: NSColor(fill).blended(withFraction: 0.18, of: .black) ?? .black)
            : fill

        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? .white : AeroTokens.ink)
            // The 1pt white shadow below is for DARK type on LIGHT fills only. On a coloured
            // prominent fill the type is white, and a white shadow under white type is invisible
            // at best and a halo at worst.
            .aeroTextShadow(!prominent)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(colors: prominent
                                       ? [effectiveFill, effectiveFill.opacity(0.82)]
                                       : [AeroTokens.chromeTop, AeroTokens.chromeBottom],
                                       startPoint: .top, endPoint: .bottom)
                    )
            }
            .aeroGloss(cornerRadius: radius)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.black.opacity(prominent ? 0.28 : 0.20), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: AeroTokens.shadow(for: prominent ? effectiveFill : AeroTokens.chromeBottom),
                    radius: AeroTokens.shadowRadius, x: 0, y: AeroTokens.shadowY)
            // Pressed state is a static darkening, not an animation. The 2006 originals were
            // essentially static; adding a ripple or shimmer here dates the theme wrongly.
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A clear Liquid Glass button — refractive, picking up whatever sits behind it.
///
/// The genuine `.glassEffect(.clear,…)` needs macOS 26. The package deploys to macOS 14, so older
/// systems get a translucent material fallback rather than failing to build. That fallback is NOT
/// the same effect and is not used for Aero anywhere — Aero gloss is painted (see `AeroGloss`).
struct LiquidGlassButtonStyle: ButtonStyle {
    var prominent: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

        return Group {
            if reduceTransparency {
                // Reduce Transparency means an opaque fill, not a thinner glass.
                label.background(
                    Capsule().fill(prominent ? Color.accentColor : Color(nsColor: .controlColor)))
                    .foregroundStyle(prominent ? .white : Color(nsColor: .labelColor))
            } else if #available(macOS 26.0, *) {
                label
                    .foregroundStyle(prominent ? .white : Color(nsColor: .labelColor))
                    .glassEffect(prominent ? .clear.tint(.accentColor) : .clear, in: .capsule)
            } else {
                label
                    .foregroundStyle(prominent ? .white : Color(nsColor: .labelColor))
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
            }
        }
        .brightness(configuration.isPressed ? -0.05 : 0)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: Theme-aware application

/// Applies whichever button style the active theme calls for.
///
/// Components ask for a ROLE (prominent or not) and let the theme decide how that looks, so a
/// screen can never end up with one Aero button beside one glass button.
struct ThemedButton: ViewModifier {
    var prominent: Bool
    var accent: Color
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        switch theme {
        case .frutigerAero:
            content.buttonStyle(AeroButtonStyle(accent: accent, prominent: prominent))
        case .liquidGlass:
            content.buttonStyle(LiquidGlassButtonStyle(prominent: prominent))
        }
    }
}

extension View {
    func themedButton(prominent: Bool = false, accent: Color = AeroTokens.aqua) -> some View {
        modifier(ThemedButton(prominent: prominent, accent: accent))
    }

    /// A focus ring that is visible in both themes.
    ///
    /// The Aero gloss is decoration and is present whether or not a control has focus, so it can
    /// never serve as the focus indicator. This ring appears only on focus.
    func themedFocusRing(_ focused: Bool, cornerRadius: CGFloat = 6) -> some View {
        overlay {
            if focused {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AeroTokens.focusRing, lineWidth: AeroTokens.focusRingWidth)
                    .padding(-AeroTokens.focusRingOffset)
            }
        }
    }
}
