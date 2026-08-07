import SwiftUI

/// The divide between the sidebar and the detail column.
///
/// Since the two columns are laid out by hand in an `HStack`, nothing draws a boundary between
/// them — and with one continuous sky running behind both, the join showed up as an accidental
/// seam rather than a deliberate edge. This makes it intentional.
///
/// Each theme gets the separator its own vocabulary calls for:
///
/// - **Aero** — a two-tone edge: a dark hairline with a bright highlight beside it. That is the
///   same bevel language as `AeroPanel`'s rim, turned on its side, so the columns read as two
///   raised surfaces meeting rather than one surface with a crack in it.
/// - **Liquid Glass** — a single faint light hairline. Glass edges are defined by refraction, not
///   by drawn lines, so anything heavier fights the material.
/// - **Standard** — the system `Divider`, which is what an ordinary Mac app would use.
struct ColumnSeparator: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        switch theme {
        case .frutigerAero:
            HStack(spacing: 0) {
                Color.black.opacity(0.14).frame(width: 1)
                Color.white.opacity(0.55).frame(width: 1)
            }
            .frame(width: 2)
        case .liquidGlass:
            Color.white.opacity(0.16).frame(width: 1)
        case .system:
            Divider()
        }
    }
}

/// A faint lightening of the sidebar so it reads as its own surface.
///
/// Separation needs more than a line: with an identical backdrop on both sides, a 1pt edge alone
/// still looks like a seam. Lifting the sidebar very slightly gives the two columns different
/// values, which is what makes the boundary read as intentional.
///
/// Kept subtle on purpose — the sky is meant to feel continuous across the window, and a heavier
/// tint would turn the sidebar into a separate panel floating on a different background.
struct SidebarLift: ViewModifier {
    @Environment(\.appTheme) private var theme

    /// Rounded on the LEADING corners only.
    ///
    /// A plain rectangle here pokes past the window's own rounded corners at the top-left and
    /// bottom-left, leaving two sharp points against a rounded window. The trailing edge stays
    /// square because that side butts against the separator — rounding it would open a wedge of
    /// backdrop between the two columns, which is the seam this was meant to close.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: Self.windowCornerRadius,
                               bottomLeadingRadius: Self.windowCornerRadius,
                               bottomTrailingRadius: 0,
                               topTrailingRadius: 0,
                               style: .continuous)
    }

    /// Matches the macOS window corner radius closely enough that the fill sits inside it.
    private static let windowCornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        switch theme {
        case .frutigerAero: content.background(Color.white.opacity(0.16), in: shape)
        case .liquidGlass:  content.background(Color.white.opacity(0.04), in: shape)
        case .system:       content
        }
    }
}

extension View {
    /// Lift this column slightly so it reads as a distinct surface from its neighbour.
    func sidebarLift() -> some View { modifier(SidebarLift()) }
}
