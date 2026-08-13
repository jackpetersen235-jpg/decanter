import Foundation

/// What a bottle actually plays.
///
/// **This used to generate a `.app` per game into `~/Applications`, and Play opened that bundle
/// rather than launching anything itself.** The whole generator — script emission, Info.plist,
/// the version stamp that forced stale bundles to rebuild — was removed as "a useless extra step
/// that just gets in the way": creating a bottle produced a second artifact the user then had to
/// keep track of, and Play went through it instead of just starting the game.
///
/// `AppModel.launchSteam` does everything that script did, and does it in the app where its
/// behaviour is visible: waits for Steam to log in, runs `steam.exe -applaunch <id>` (or the
/// binary directly for bottles whose Steam entry point is an anti-cheat shim), and installs the
/// per-game graphics DLLs first.
///
/// The type below is all that remains, and it is still the single answer to "which executable
/// does this bottle run" — `resolvedGame` builds it, and the Play button, the graphics-driver
/// installer and the doctor report all read it. Keep it that way: a second opinion about which
/// game a bottle plays is how the picker and the launcher drifted apart when there were two.
///
/// Git history has the generator if it is ever wanted back.
enum GameAppBuilder {

    struct Game {
        let name: String
        let folder: URL
        let executable: URL
        /// Steam's numeric app id.
        let appID: String?
        /// True when the bottle explicitly names a `directExecutable`.
        ///
        /// That setting exists for titles whose Steam entry point is an anti-cheat shim (JJBA),
        /// where going through Steam runs the wrong binary.
        var prefersDirectLaunch: Bool = false
    }
}
