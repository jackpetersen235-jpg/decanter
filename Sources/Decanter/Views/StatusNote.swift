import SwiftUI

/// A caption that warns or reports a failure. The colour goes on the SYMBOL, never on the text.
///
/// Every warning used to be caption text tinted `.orange` (or `.yellow`, or `.red`). Measured
/// against the light window background (2026-11-02, `NSColor` resolved in Aqua): system orange
/// **2.31:1**, yellow **1.51:1**, red **3.57:1** — all under the 4.5:1 that small text needs, and
/// orange falls to 1.86:1 with Increase Contrast on. They only passed in dark mode.
///
/// So the tint marks the icon, the icon's SHAPE tells a warning from a failure (colour is never
/// the only signal), and the text keeps the readable primary colour. Leaving the text unstyled
/// also lets Aero's ink and the user's text-tone override reach it, which a hardcoded tint
/// blocked.
struct StatusNote: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    init(_ text: String, systemImage: String = "exclamationmark.triangle.fill", tint: Color = .orange) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    /// Something went wrong and did not happen. Red octagon, distinct in shape from a warning.
    static func failure(_ text: String) -> StatusNote {
        StatusNote(text, systemImage: "xmark.octagon.fill", tint: .red)
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.caption)
    }
}
