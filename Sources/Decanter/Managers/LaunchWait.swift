import Foundation

/// What Decanter says while it HOLDS a game launch until Steam signs in (see
/// `AppModel.launchesWaitingForSteam`). Kept pure so the wording can be tested.
///
/// Found live 2026-10-21: Play on Peggle joined a warm-start, the panel showed only "Opening…",
/// and Decanter was quit from the Dock 44 s in — 22 s before Steam signed in. The launch existed
/// only in Decanter's memory, so it died with the app and Peggle never started. A cold sign-in
/// measured 67 s that morning; the caption then on screen promised "a few seconds".
enum LaunchWait {

    /// Under Play whenever a launch is in progress.
    static let openingCaption = "Steam is opening. Signing in can take a minute or more the "
        + "first time after a restart."

    /// Under Play while Decanter is holding `gameName`'s launch for Steam.
    static func caption(gameName: String) -> String {
        "Waiting for Steam to finish signing in — \(gameName) starts by itself when it does. "
            + "This can take a minute or more, so keep Decanter open until then."
    }

    /// The quit confirmation, or nil when no launch is being held and setup isn't running.
    ///
    /// Setup is here too because quitting it was just as silent: ⌘Q partway through the ~500 MB
    /// engine download quit at once and threw the download away.
    static func quitWarning(gameNames: [String],
                            isSettingUp: Bool = false) -> (title: String, message: String)? {
        if isSettingUp {
            return ("Setup is still running",
                    "Decanter is still downloading and setting things up. If you quit now, "
                    + "the next \"Set everything up for me\" skips whatever already finished, "
                    + "but an unfinished download starts over.")
        }
        guard let first = gameNames.first else { return nil }
        if gameNames.count == 1 {
            return ("\(first) hasn't started yet",
                    "Steam is still signing in, and Decanter starts \(first) as soon as it "
                    + "finishes. If you quit now, \(first) won't start — you'd have to press "
                    + "Play again.")
        }
        return ("\(gameNames.count) games haven't started yet",
                "Steam is still signing in, and Decanter starts "
                + gameNames.joined(separator: " and ")
                + " as soon as it finishes. If you quit now, they won't start — you'd have to "
                + "press Play again.")
    }
}
