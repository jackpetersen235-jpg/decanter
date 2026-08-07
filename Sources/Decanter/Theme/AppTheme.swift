import SwiftUI

/// The app's two appearances.
///
/// Switching is **all or nothing**: there is no per-control override and no mixed screen. A window
/// showing painted Aero gloss beside refracting Liquid Glass reads as a rendering bug, not as
/// choice, so the theme is read once from the environment and every themed component obeys it.
enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case liquidGlass
    case frutigerAero

    var id: String { rawValue }

    /// Sentence case throughout, per the app's copy style.
    var label: String {
        switch self {
        case .liquidGlass:  return "Liquid glass"
        case .frutigerAero: return "Frutiger aero"
        }
    }

    var detail: String {
        switch self {
        case .liquidGlass:  return "Clear, refractive controls that pick up what is behind them."
        case .frutigerAero: return "Glossy 2006-era buttons, sky and bubbles."
        }
    }
}

/// Text colour override.
///
/// A clear window means text sits over whatever wallpaper happens to be behind it, and no single
/// choice is right for every desktop — black disappears on a dark photo, white disappears on a
/// bright one. This is the manual override for that.
///
/// `automatic` is the default and keeps each theme's own choice: Aero's dark ink on its light sky,
/// and the system label colour under Liquid Glass. It exists because a fixed black or white would
/// otherwise be wrong for one of the two themes the moment the wallpaper changed.
enum TextTone: String, CaseIterable, Identifiable, Codable {
    case automatic
    case black
    case white

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .black:     return "Black"
        case .white:     return "White"
        }
    }

    var color: Color? {
        switch self {
        case .automatic: return nil
        case .black:     return .black
        case .white:     return .white
        }
    }
}

// MARK: Environment

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .liquidGlass
}

private struct TextToneKey: EnvironmentKey {
    static let defaultValue: TextTone = .automatic
}

extension EnvironmentValues {
    var textTone: TextTone {
        get { self[TextToneKey.self] }
        set { self[TextToneKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

/// Holds the selected theme and persists it.
///
/// Deliberately separate from `AppModel`: the theme is pure presentation, and `AppModel` is already
/// the app's single largest type. Persisting to `UserDefaults` rather than `bottles.json` keeps a
/// cosmetic preference out of a file whose corruption costs the user their bottles.
@MainActor
final class ThemeController: ObservableObject {
    private static let key = "appTheme"

    private static let toneKey = "appTextTone"

    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.key) }
    }

    @Published var textTone: TextTone {
        didSet { UserDefaults.standard.set(textTone.rawValue, forKey: Self.toneKey) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.key) ?? ""
        theme = AppTheme(rawValue: stored) ?? .liquidGlass
        let tone = UserDefaults.standard.string(forKey: Self.toneKey) ?? ""
        textTone = TextTone(rawValue: tone) ?? .automatic
    }
}

/// Applies the chosen text colour, or leaves the theme's own choice alone on `.automatic`.
///
/// Deliberately applied ALONGSIDE `aeroInk` rather than inside it: the override has to win over the
/// theme, so it is layered on afterwards. On `.automatic` it is a genuine no-op — it must not force
/// a colour, or the Aero ink and the system label colour would both be overwritten with a value
/// chosen for the other theme.
struct TonedText: ViewModifier {
    @Environment(\.textTone) private var tone

    @ViewBuilder
    func body(content: Content) -> some View {
        if let color = tone.color {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}

extension View {
    /// Apply the user's black/white text override, if they set one.
    func tonedText() -> some View { modifier(TonedText()) }
}
