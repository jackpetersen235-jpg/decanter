import SwiftUI
import AppKit

/// Makes the window's backing sample the DESKTOP rather than its own opaque fill.
///
/// This is the piece that was missing through every earlier attempt at Liquid Glass.
///
/// A SwiftUI window is opaque by default, so a glass effect inside it has only the window's own
/// backing to sample — and sampling a flat fill produces a flat tint, which is exactly what kept
/// coming out no matter which `Glass` variant, shape or container was used. The material was never
/// the problem; there was simply nothing behind it.
///
/// `blendingMode = .behindWindow` is the switch: it pulls pixels from the desktop wallpaper and
/// from any windows underneath, which is what the material is designed to refract.
///
/// `state = .active` is not optional either. Without it the effect reverts to a solid system colour
/// the moment the window loses focus, so the app would look correct only while frontmost.
struct DesktopBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // Re-asserted on update: SwiftUI can recreate the backing view, and a reverted blending
        // mode silently returns the flat-tint behaviour this exists to fix.
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
    }
}

/// Applies the desktop-sampling backdrop for the theme that needs it.
///
/// Liquid Glass only. Aero paints its own opaque sky, and letting the desktop through underneath
/// would put a photograph behind a 2006 pastel gradient — the atmosphere is the backdrop there.
struct ThemedWindowBacking: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if theme == .liquidGlass && !reduceTransparency {
            content.background(DesktopBackdrop().ignoresSafeArea())
        } else {
            content
        }
    }
}

extension View {
    /// Let the desktop show through the window so glass has something real to refract.
    func themedWindowBacking() -> some View {
        modifier(ThemedWindowBacking())
    }
}
