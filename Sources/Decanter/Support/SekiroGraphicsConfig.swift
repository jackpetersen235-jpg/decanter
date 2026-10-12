import Foundation

/// Sekiro's own display settings — `GraphicsConfig.xml`, which the game reads at start-up and
/// which outranks anything Wine does with the window. Sekiro-specific ON PURPOSE: this is one
/// game's file and schema, not a Wine mechanism, so callers gate on the exe name.
///
/// The file is UTF-16LE with no byte-order mark (verified on the real file before any code
/// touched it: a decode/re-encode round-trip came back byte-identical). It is written by the
/// game's OWN first run, so a bottle that has never launched the game has nothing to patch.
///
/// Its "auto-detect best rendering settings" can silently reset the window mode and resolution
/// to what IT thinks is best, undoing any patch on the next launch — hence every value set
/// below turns that off too.
enum SekiroGraphicsConfig {

    /// Where the game keeps it inside `bottle`'s prefix.
    static func file(in bottle: Bottle, user: String = NSUserName()) -> URL {
        bottle.url.appendingPathComponent(
            "drive_c/users/\(user)/AppData/Roaming/Sekiro/GraphicsConfig.xml")
    }

    /// Exclusive-fullscreen settings, for the borderless-desktop mode: the game fills Wine's
    /// per-app virtual desktop, which is sized to the screen.
    static func fullscreenValues(width: Int, height: Int) -> [String: String] {
        [
            "ScreenMode": "FULLSCREEN",
            "Auto-detectBestRenderingSettings": "OFF",
            "Resolution-FullScreenWidth": "\(width)",
            "Resolution-FullScreenHeight": "\(height)",
        ]
    }

    /// Windowed settings, for the "Real game window" mode. The window size is what the game
    /// RENDERS at — it does not grow when macOS puts the window into native fullscreen — so
    /// callers pass the fullscreen content size (`NativeWindow.fullscreenContentSize`). Anything
    /// smaller shows up as black bars around the game in fullscreen (measured: 1280×720 sat
    /// centered on black, 2026-10-12).
    static func windowedValues(width: Int, height: Int) -> [String: String] {
        [
            "ScreenMode": "WINDOW",
            "Auto-detectBestRenderingSettings": "OFF",
            "Resolution-WindowScreenWidth": "\(width)",
            "Resolution-WindowScreenHeight": "\(height)",
        ]
    }

    /// `text` with each `<Tag>…</Tag>` in `values` replaced, or nil when nothing changed — so the
    /// caller can skip the write entirely. A tag missing from this version of the file is left
    /// alone rather than invented: the game, not us, decides the schema.
    static func patched(_ text: String, values: [String: String]) -> String? {
        var result = text
        var changed = false
        for (tag, value) in values.sorted(by: { $0.key < $1.key }) {
            let escapedTag = NSRegularExpression.escapedPattern(for: tag)
            guard let range = result.range(of: "<\(escapedTag)>[^<]*</\(escapedTag)>",
                                           options: .regularExpression)
            else { continue }
            let replacement = "<\(tag)>\(value)</\(tag)>"
            if result[range] != replacement {
                result.replaceSubrange(range, with: replacement)
                changed = true
            }
        }
        return changed ? result : nil
    }
}
