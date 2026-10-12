import Foundation

/// A genuine "remove everything" path.
///
/// COMMERCIAL-READINESS.md item 3: dragging the app to Trash leaves behind the engine (~480 MB,
/// up to three profiles — offline/online/legacy), every bottle prefix (25+ GB on the machine this
/// was built on), shader caches, downloads and logs. A paid Mac app with no clean removal is a
/// predictable review complaint, and on some distribution channels a rejection.
///
/// List-and-confirm, same shape as `OrphanReclaim`/`reclaimReport()` (F5) — this type only
/// classifies and sizes what WOULD be removed; it never touches disk itself. The caller (a
/// confirmation dialog) decides whether `execute()` actually runs, and only after the user has
/// seen every item and its size, not a single "delete everything?" button asking them to trust it.
enum Uninstaller {
    struct Item {
        let label: String
        let url: URL
        let bytes: Int
    }

    /// Everything a full uninstall would remove, present ones only, each with its real on-disk
    /// size. `Backups/` IS included here — unlike `OrphanReclaim`, which deliberately never scans
    /// it (F21: it holds `RESTORE-*.sh`'s rollback material, live for as long as the app is in
    /// use). An uninstall is the one context where removing it too is exactly the point: the user
    /// is leaving, not freeing spare space while staying.
    static func plan() -> [Item] {
        let fm = FileManager.default
        let candidates: [(String, URL)] = [
            ("Wine engine — offline", Paths.wineEngineRoot),
            ("Wine engine — online", Paths.onlineEngineRoot),
            ("Wine engine — legacy", Paths.legacyEngineRoot),
            ("Bottles (installed games, saves, settings)", Paths.bottlesRoot),
            ("Shader cache", Paths.shaderCacheRoot),
            ("Downloads (installers)", Paths.downloads),
            ("Logs", Paths.logsRoot),
            ("Game launcher (Decanter Game.app)", Paths.installedGameHost),
            ("Backups", Paths.appSupport.appendingPathComponent("Backups", isDirectory: true)),
            ("Bottle index (bottles.json)", Paths.bottlesIndex),
        ]
        return candidates.compactMap { label, url in
            guard fm.fileExists(atPath: url.path) else { return nil }
            let bytes = size(of: url, fm: fm)
            // Skip an empty skeleton directory — `Paths.ensureDirectories()` creates Bottles/,
            // Downloads/ and Logs/ on first launch whether or not anything is ever installed, so
            // a never-set-up Decanter would otherwise list three "0 bytes" rows that have nothing
            // real behind them. `bottles.json` stays even if tiny — its mere presence is
            // meaningful, unlike an empty folder.
            guard bytes > 0 || url == Paths.bottlesIndex else { return nil }
            return Item(label: label, url: url, bytes: bytes)
        }
    }

    /// Total bytes across every item in `plan()` — what the confirmation dialog headlines.
    static func totalBytes() -> Int { plan().reduce(0) { $0 + $1.bytes } }

    /// Removes every item in `plan()`. The caller is responsible for confirming with the user
    /// FIRST — this performs no confirmation of its own and, once called, does not stop partway:
    /// a half-finished uninstall (some prefixes gone, others not) would be a worse state than
    /// either finishing or never starting, so failures on individual items are collected and
    /// reported rather than aborting the rest.
    ///
    /// Returns the labels of anything that could NOT be removed (e.g. a permissions issue), empty
    /// on full success.
    @discardableResult
    static func execute() -> [String] {
        var failed: [String] = []
        for item in plan() {
            do {
                try FileManager.default.removeItem(at: item.url)
            } catch {
                failed.append("\(item.label): \(error.localizedDescription)")
            }
        }
        return failed
    }

    private static func size(of url: URL, fm: FileManager) -> Int {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                             options: [.skipsHiddenFiles])
        else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            total += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
