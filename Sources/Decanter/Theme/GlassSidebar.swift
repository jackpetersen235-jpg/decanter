import SwiftUI

/// A clear Liquid Glass surface for the bottles sidebar.
///
/// Applied in **both** themes on purpose. Everywhere else the two appearances are kept strictly
/// apart — painted Aero gloss and refractive glass in the same object reads as a rendering fault —
/// but the sidebar is a distinct pane with its own edge, so the boundary between the two materials
/// falls on a seam that already exists rather than through the middle of a control.
///
/// This is glass, so it refracts. It must NOT be given the Aero gloss on top; that combination is
/// the muddy hybrid both treatments exist to avoid.
struct GlassSidebar: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                // Opaque, not thinner glass. Reduce Transparency means no see-through surfaces.
                content.background(Color(nsColor: .windowBackgroundColor))
            } else if #available(macOS 26.0, *) {
                content.background {
                    Rectangle().fill(.clear).glassEffect(.clear, in: .rect)
                }
            } else {
                // The package deploys to macOS 14, so this fallback is what older systems get.
                content.background(.ultraThinMaterial)
            }
        }
        // The List paints its own opaque backdrop otherwise, and the glass never shows.
        .scrollContentBackground(.hidden)
    }
}

extension View {
    /// Clear Liquid Glass backing for the sidebar, in both themes.
    func glassSidebar() -> some View {
        modifier(GlassSidebar())
    }
}
