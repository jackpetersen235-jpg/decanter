import Foundation

/// Where a bottle's one-time Windows setup (wineboot) stands, as the UI should describe it.
///
/// `Bottle.isInitialized` alone can't say: a bottle is saved BEFORE its wineboot runs, so one
/// whose setup was cut short — Decanter quit mid-setup — stays not-initialized forever with nothing
/// booting it, and the detail pane showed "Setting up…" with a spinner for it indefinitely.
/// A progress indicator has to mean something is in progress.
enum BottleSetupState: Equatable {
    case ready
    /// wineboot is running for it right now.
    case inProgress
    /// Not initialized, and nothing is booting it — setup was cut short and won't resume.
    case interrupted

    static func of(isInitialized: Bool, isBooting: Bool) -> BottleSetupState {
        if isInitialized { return .ready }
        return isBooting ? .inProgress : .interrupted
    }

    /// The sidebar row's second line, or nil when the bottle is fine and the row is one line.
    ///
    /// Every row used to say "Steam ready" — six identical captions that carried no information and
    /// made the list look busy. A caption now appears only when it asks for attention.
    func sidebarCaption(isSteamInstalled: Bool) -> String? {
        switch self {
        case .inProgress:  return "Initializing…"
        case .interrupted: return "Setup didn't finish"
        case .ready:       return isSteamInstalled ? nil : "Steam not installed"
        }
    }
}
