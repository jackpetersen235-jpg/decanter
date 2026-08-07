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

/// Apple's OWN Liquid Glass button styles.
///
/// This replaces a hand-rolled `ButtonStyle` that padded a label and applied `.glassEffect(…, in:
/// .capsule)` to it. That was the reason the buttons never looked right: reimplementing a control
/// Apple already ships gets the material but none of the rest of it — the real metrics, the
/// concentric corner radius, the press and hover behaviour, the way the system tunes the material
/// specifically for controls, and the automatic light/dark adaptation. `.glassEffect` is for
/// applying glass to CUSTOM views; a button is not a custom view.
///
/// `.glass` and `.glassProminent` need macOS 26. The package deploys to macOS 14, so older systems
/// get bordered styles rather than failing to build.
struct NativeGlassButton: ViewModifier {
    var prominent: Bool = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // SwiftUI's button styles are distinct TYPES, so they cannot be chosen with a ternary — every
    // branch has to apply its own `.buttonStyle` call. Verbose, but the alternative is erasing the
    // style, which loses the very behaviour this change exists to get back.
    @ViewBuilder
    func body(content: Content) -> some View {
        // Reduce Transparency means an opaque control, not a thinner glass one.
        if reduceTransparency {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        } else if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
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
            content.modifier(NativeGlassButton(prominent: prominent))
        }
    }
}

/// Groups adjacent glass controls so they share one sampling region.
///
/// Required, not cosmetic. Glass cannot sample other glass, so several `.glassEffect` views sitting
/// side by side each sample independently and render inconsistently — which is a large part of why
/// the button row read as flat capsules rather than as one set of glass controls. The container
/// gives them a shared region and lets nearby shapes blend.
///
/// Applies in BOTH themes. It used to be gated to Liquid Glass on the reasoning that Aero's gloss
/// is painted and needs no sampling — but Aero screens now carry glass secondary buttons too, and
/// those need the shared sampling region just as much.
struct GlassGroup: ViewModifier {
    var spacing: CGFloat = 10

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    func themedButton(prominent: Bool = false, accent: Color = AeroTokens.aqua) -> some View {
        modifier(ThemedButton(prominent: prominent, accent: accent))
    }

    /// Wrap a row/cluster of glass controls. See `GlassGroup` — this is required for glass to
    /// render consistently, not an optimisation.
    func glassGroup(spacing: CGFloat = 10) -> some View {
        modifier(GlassGroup(spacing: spacing))
    }

    /// Always Liquid Glass, in both themes.
    ///
    /// Used for every button EXCEPT Play and Launch Steam. Those two are the primary actions and
    /// keep the active theme's own treatment — in Aero, painted gloss — so the eye still lands on
    /// them first. Everything else is secondary and recedes into glass, which is what keeps a row
    /// of eight controls from competing with the two that matter.
    func glassButton(prominent: Bool = false) -> some View {
        modifier(NativeGlassButton(prominent: prominent))
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
