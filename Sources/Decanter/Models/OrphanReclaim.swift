import Foundation

/// F5 (bug-sweep): pure categorization for "what in Bottles/ and ShaderCache/ is safe to reclaim."
///
/// An orphan can NOT be defined as "unreferenced by bottles.json" alone — `ShaderCache/Sekiro` and
/// `/ASBR` are unreferenced there and genuinely live, consumed by hand-made launchers
/// (`~/Applications/Sekiro.app`, `/JJBA All-Star Battle.app`) that set `DXMT_SHADER_CACHE_PATH`
/// directly and are structurally invisible to Decanter's own model. Both a bottle reference AND an
/// external-launcher reference must be checked before anything is called reclaimable.
///
/// `Backups/` is never a candidate at all — it holds the rollback material RESTORE-*.sh depends on
/// (see F21). It is deliberately not passed into this type's inputs, not merely filtered out, so a
/// caller can't accidentally feed it in and get a false "safe to reclaim."
///
/// List-only, by design: this type only classifies directory NAMES already handed to it. It never
/// walks the filesystem and never deletes anything — that stays a human decision.
enum OrphanReclaim {
    struct Item: Equatable {
        let name: String
        let reason: String
    }

    /// Bottle-folder names present on disk with no bottle in `bottles.json` pointing at them.
    ///
    /// F24 (bug-sweep): this used to compare names with raw `Set.contains` — case-sensitive, on
    /// APFS's default case-insensitive volume. A bottle whose stored `url` differed only in case
    /// from the real on-disk directory would list that directory reclaimable, sizes and all —
    /// including, on the machine this was built for, the live 25 GB `Steam-Wine11` prefix. Folded
    /// via `PrefixSharing.nameKey` now, the name-level counterpart to the URL-level `key(for:)`
    /// that already closed this exact gap for `deleteBottle`'s guard (F18). `Item.name` still
    /// carries the ON-DISK spelling, not the folded key — the report prints it and a person may
    /// paste it into a command.
    static func orphanedBottleDirs(present: [String], referencedByBottles: Set<String>) -> [Item] {
        let referenced = Set(referencedByBottles.map(PrefixSharing.nameKey))
        return present
            .filter { !referenced.contains(PrefixSharing.nameKey($0)) }
            .map { Item(name: $0, reason: "no bottle in bottles.json points at this prefix") }
    }

    /// ShaderCache-folder names neither referenced by a live bottle's prefix name nor by a
    /// hand-made launcher's `DXMT_SHADER_CACHE_PATH`. Both checks matter — see the type doc above.
    /// Same F24 case-folding fix as `orphanedBottleDirs`, applied to both reference sets: an
    /// unfolded comparison here could list a live, launcher-referenced cache as reclaimable just as
    /// easily as it could list the prefix itself.
    static func orphanedShaderCacheDirs(present: [String], referencedByBottles: Set<String>,
                                        referencedByLaunchers: Set<String>) -> [Item] {
        let bottleKeys = Set(referencedByBottles.map(PrefixSharing.nameKey))
        let launcherKeys = Set(referencedByLaunchers.map(PrefixSharing.nameKey))
        return present
            .filter { !bottleKeys.contains(PrefixSharing.nameKey($0)) && !launcherKeys.contains(PrefixSharing.nameKey($0)) }
            .map { Item(name: $0, reason: "no bottle prefix or external launcher references this cache") }
    }
}
