import Foundation

/// Which bottles share one WINEPREFIX, and what follows from that.
///
/// A `Bottle` is presented as an isolated unit, but several of its settings — anything that lands
/// in `HKLM` (Windows version), `HKCU\Control Panel\Desktop` (DPI), `HKCU\Software\Wine\Mac Driver`
/// (Retina) — are properties of the PREFIX, i.e. shared by every bottle pointing at it. So is the
/// process tree `wineserver -k` tears down. Bugs traced to this gap:
///
/// - Setting one bottle's Windows version to 7 silently changed three other bottles that showed
///   "Windows 10" in their own Configuration tab (observed: `system.reg` changed prefix-wide).
/// - "Quit Steam" on one bottle can kill a game running under a DIFFERENT bottle sharing the same
///   prefix — the confirmation dialog said "any game running in this bottle", which understates
///   the real blast radius.
/// - The software-2D per-exe registry key is fought over by two bottles resolving the same game in
///   the same prefix (one wants it on, the other off) — same root cause, a third shape.
///
/// This file is the one place that answers "which bottles share this prefix" and "what does that
/// imply". Everything that used to re-derive the answer (or not ask at all) now asks here — the
/// same discipline as `resolvedGame` for "which game does this bottle play": a second opinion is
/// how the picker and the launcher resolver drifted apart earlier in this project, and duplicating
/// prefix logic at each call site is the same mistake in a new shape.
enum PrefixSharing {

    /// Canonical identity of a bottle's prefix directory — the thing to COMPARE, never the raw URL.
    ///
    /// ⚠️ CORRECTED CLAIM: an earlier draft of this comment said percent-encoding (this repo's own
    /// `Bottles/Half%20Sword/` vs an unencoded `Bottles/Half Sword/`) needed handling here. It does
    /// not — proven, not assumed: `URL.path` already decodes percent-encoding unconditionally
    /// regardless of how the URL was built (`URL(string:)` vs `URL(fileURLWithPath:)`), and plain
    /// `URL ==` already treats the two forms as equal. Verified with a standalone probe before
    /// writing this comment, after the ORIGINAL comment's claim turned out to be wrong: a test built
    /// to catch it passed even against a naive `url.path` key, which is what caught the mistake.
    /// Same for the trailing slash — `.path` already drops it for both construction paths tested.
    ///
    /// The one gap `.path` does NOT close, and the one thing this function exists for:
    ///
    /// **Case folding.** APFS is case-insensitive (not merely case-preserving) by default, so
    /// `Steam-Wine11` and `steam-wine11` name ONE directory there — proven by the naive-key test,
    /// which is the only one of the group that actually failed without this function. Folding case
    /// is right for that default and WRONG on a case-sensitive APFS volume (a real, rarer option),
    /// stated rather than silently assumed — there is no cheap way to ask "is this volume
    /// case-sensitive" from a pure function with no filesystem access.
    ///
    /// `standardizedFileURL` is kept anyway as defense-in-depth against `.`/`..` components that
    /// were not specifically tested, not because a concrete bug was found in them.
    static func key(for url: URL) -> String {
        URL(fileURLWithPath: url.path, isDirectory: true)
            .standardizedFileURL.path.lowercased()
    }

    /// Every bottle whose prefix matches `bottle`'s, INCLUDING `bottle` itself.
    /// Order is stable (input order preserved) so UI text built from this does not reshuffle
    /// between renders.
    static func group(of bottle: Bottle, in all: [Bottle]) -> [Bottle] {
        let k = key(for: bottle.url)
        return all.filter { key(for: $0.url) == k }
    }

    /// The other bottles this one shares a prefix with — what a confirmation dialog names.
    /// Excludes by ID, not name: two bottles are allowed to share a name.
    static func others(of bottle: Bottle, in all: [Bottle]) -> [Bottle] {
        group(of: bottle, in: all).filter { $0.id != bottle.id }
    }

    static func isShared(_ bottle: Bottle, in all: [Bottle]) -> Bool {
        !others(of: bottle, in: all).isEmpty
    }

    /// Should the per-exe software-2D override be ON, given every bottle that resolves to `exe` in
    /// this prefix?
    ///
    /// The key is per-EXECUTABLE, but two bottles can independently resolve to the same executable
    /// (two "Peggle Deluxe" bottles in one prefix — the picker explicitly allows this, flagging the
    /// second as "Added" rather than refusing it). If bottle A wants software rendering on and
    /// bottle B wants it off, the key must reflect the UNION of wants: turning it off from B must
    /// not silently undo what A asked for. `resolve` maps a bottle to the executable name it plays,
    /// or nil if it resolves none (e.g. a launcher bottle).
    static func software2DWanted(forExe exe: String, in group: [Bottle],
                                 resolve: (Bottle) -> String?) -> Bool {
        group.contains { resolve($0)?.lowercased() == exe.lowercased() && $0.settings.software2D }
    }
}
