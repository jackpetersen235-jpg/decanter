import Foundation

/// Which installed games Decanter adds to the sidebar by itself, so a game installed in Steam shows
/// up with a Play button and no "+" step (the way CrossOver lists installed games).
///
/// Deliberately narrow: only finished Steam games, never anything the user deleted. Pure, so the
/// rule is testable without a scan or an `AppModel`.
enum AutoAddGames {

    /// Identifies a game the user removed, so it stays removed. Keyed on the PREFIX as well as the
    /// app id because the same game can live in two prefixes; the prefix part is case-folded
    /// (`PrefixSharing.key`) because APFS is case-insensitive.
    static func key(appID: String, prefix: URL) -> String {
        "\(PrefixSharing.key(for: prefix))|\(appID)"
    }

    /// `appIDsWithBottles`: Steam games some bottle already plays, from ANY prefix. The same game can
    /// be installed in two Windows setups, and a second entry for it reads as a duplicate to anyone
    /// who doesn't know what a prefix is. (The "+" picker still lists both, with their prefixes.)
    static func gamesToAdd(_ found: [GameScanner.FoundGame],
                           alreadyHasBottle: (GameScanner.FoundGame) -> Bool,
                           appIDsWithBottles: Set<String> = [],
                           dismissed: Set<String>) -> [GameScanner.FoundGame] {
        var adding = Set<String>()
        return found.filter { game in
            // Steam games only: anything else in Program Files could be a utility or an installer,
            // and those stay behind "+". Half-downloaded games wait until Steam says they're done.
            guard let appID = game.appID, game.isFullyInstalled else { return false }
            guard !appIDsWithBottles.contains(appID), !adding.contains(appID),
                  !dismissed.contains(key(appID: appID, prefix: game.prefix)),
                  !alreadyHasBottle(game) else { return false }
            adding.insert(appID)        // one entry even if this scan found it in two prefixes
            return true
        }
    }
}
