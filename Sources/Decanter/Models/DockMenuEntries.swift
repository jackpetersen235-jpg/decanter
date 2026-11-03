import Foundation

/// What Decanter's Dock menu lists: "Launch <bottle>" for every bottle that can launch, in sidebar
/// order, greyed out while that bottle is already launching. Pure, so it's testable without AppKit
/// or real prefixes — `hasSteam` is injected because `Bottle.isSteamInstalled` reads the disk.
enum DockMenuEntries {
    struct Entry: Equatable {
        let bottleID: Bottle.ID
        let title: String
        let isEnabled: Bool
    }

    static func make(for bottles: [Bottle], hasSteam: (Bottle) -> Bool,
                     launching: Set<Bottle.ID>) -> [Entry] {
        bottles.filter(hasSteam).map { bottle in
            Entry(bottleID: bottle.id, title: "Launch \(bottle.name)",
                  isEnabled: !launching.contains(bottle.id))
        }
    }
}
