import Foundation

/// The attribute a browser puts on every file of a download, and what Gatekeeper checks before it
/// refuses an app that isn't notarized.
///
/// Decanter isn't notarized, so a copy from GitHub arrives with this on every file of the bundle.
/// The user approves Decanter.app once, where it is — but `FileManager.copyItem` copies the
/// attribute along, so a helper Decanter copies OUT of its bundle is a new quarantined app that
/// Gatekeeper refuses. Measured 2026-11-03 on a copy of "Decanter Game.app" made from the friend
/// zip: `spctl` said rejected. `WineInstaller` clears its own download the same way (`xattr -dr`).
enum Quarantine {
    static let attribute = "com.apple.quarantine"

    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Removes the attribute from `url` and everything under it. Items without it are skipped;
    /// any other failure (a read-only volume, no permission) is thrown, naming the item.
    static func strip(_ url: URL, fileManager: FileManager = .default) throws {
        try clear(url)
        guard let items = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items { try clear(item) }
    }

    private static func clear(_ url: URL) throws {
        guard removexattr(url.path, attribute, XATTR_NOFOLLOW) != 0 else { return }
        let code = errno
        if code == ENOATTR { return }
        throw QuarantineError(item: url.lastPathComponent, code: code)
    }
}

struct QuarantineError: LocalizedError {
    let item: String
    let code: Int32

    var errorDescription: String? {
        "Couldn't clear the download quarantine on \(item) (\(String(cString: strerror(code))))."
    }
}
