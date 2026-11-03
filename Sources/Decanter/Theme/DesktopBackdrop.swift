import SwiftUI
import AppKit

/// Makes the window itself genuinely clear, so glass samples the desktop with no tint of its own.
///
/// Two steps were needed to get here, and the first was only half the answer:
///
/// 1. A SwiftUI window is **opaque** by default, so a glass effect inside it can only sample the
///    window's own flat backing. Sampling a flat fill produces a flat tint — which is why every
///    variant, shape and container tried before this looked the same.
/// 2. Backing the window with an `NSVisualEffectView` fixed the sampling but introduced a **grey
///    cast**, because every `NSVisualEffectView.Material` tints. There is no "clear" material;
///    `.underWindowBackground` and friends all add grey. `containerBackground(_:for: .window)`
///    cannot help either — it takes a `ShapeStyle`, so it always paints *something*.
///
/// The only way to a genuinely clear window is AppKit: `isOpaque = false` plus a clear
/// `backgroundColor`. That is what this does. Nothing is painted at all, so the desktop shows
/// through untinted and the glass panes above it have real, unmodified content to refract.
///
/// **Content must therefore carry its own surface.** With the window clear, any pane without a
/// background puts its text straight over the wallpaper. The floating glass panes provide that
/// surface; anything else that holds text needs one too.
struct ClearWindowBacking: NSViewRepresentable {
    /// Whether the window should currently be clear.
    ///
    /// A parameter rather than a fact about this view's existence. The first version simply wasn't
    /// installed unless the theme wanted a clear window — which meant switching AWAY from Liquid
    /// Glass removed the view without ever running `updateNSView` again, so nothing set `isOpaque`
    /// back to `true` and the window stayed transparent until relaunch. The detail pane then looked
    /// like glass in the Standard theme while the sidebar, which has an opaque fill, looked right.
    ///
    /// Window state is global and sticky: whatever sets it must be able to UNSET it. So this view
    /// is always installed and drives the property in both directions.
    var clear: Bool
    /// Whether the window shows its title in a real toolbar (Standard) or floats the traffic lights
    /// over hand-laid-out content (the themed looks). The scene's `.hiddenTitleBar` style can't vary
    /// by theme, so the window is set here — in both directions, for the same reason as `clear`.
    var showsTitleBar = false

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // `view.window` is nil while the view is still being inserted, so this has to run after
        // the current layout pass rather than inline.
        let clear = self.clear
        let showsTitleBar = self.showsTitleBar
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = !clear
            window.backgroundColor = clear ? .clear : .windowBackgroundColor
            window.titleVisibility = showsTitleBar ? .visible : .hidden
            window.titlebarAppearsTransparent = !showsTitleBar
        }
    }
}

/// Applies the clear window backing for the theme that wants it.
///
/// Liquid Glass only. Aero paints its own opaque sky — letting the desktop through underneath
/// would put a photograph behind a 2006 pastel gradient. Skipped under Reduce Transparency, where
/// the whole point is that surfaces stop being see-through.
struct ThemedWindowBacking: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        // ALWAYS installed, so it can restore the window as well as clear it. Conditionally
        // inserting it is what left the window transparent after switching to another theme.
        content.background(
            ClearWindowBacking(clear: theme == .liquidGlass && !reduceTransparency,
                               // Standard is laid out with the system's split view and toolbar,
                               // which put the bottle's name in the window title (see ContentView).
                               showsTitleBar: theme == .system)
                .allowsHitTesting(false))
    }
}

extension View {
    /// Make the window clear so glass has real, untinted content to refract.
    func themedWindowBacking() -> some View {
        modifier(ThemedWindowBacking())
    }
}
