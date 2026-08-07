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
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // `view.window` is nil while the view is still being inserted, so this has to run after
        // the current layout pass rather than inline.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
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
        if theme == .liquidGlass && !reduceTransparency {
            content.background(ClearWindowBacking().allowsHitTesting(false))
        } else {
            content
        }
    }
}

extension View {
    /// Make the window clear so glass has real, untinted content to refract.
    func themedWindowBacking() -> some View {
        modifier(ThemedWindowBacking())
    }
}
