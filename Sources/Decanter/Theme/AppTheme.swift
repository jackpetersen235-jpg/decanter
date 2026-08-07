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

// MARK: Environment

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .liquidGlass
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

    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.key) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.key) ?? ""
        theme = AppTheme(rawValue: stored) ?? .liquidGlass
    }
}
