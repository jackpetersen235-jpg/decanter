import AppKit

/// Pure pieces of the "Real game window" mode (`BottleSettings.nativeWindow`), kept out of
/// AppModel so they can be tested without launching anything. AppModel does the I/O.
enum NativeWindow {

    /// Set in Decanter's own environment to inject one more x86_64 library into a "Real game
    /// window" game alongside the window hook — e.g. Scripts/sekiro/libframestat.dylib for frame
    /// timing. Diagnostic only. Deliberately NOT spelled DYLD_INSERT_LIBRARIES: that would load
    /// the x86_64 library into Decanter itself (arm64), and dyld kills a process for that.
    static let extraInsertVariable = "DECANTER_EXTRA_INSERT"

    /// Where the window hook writes its log and polls for test commands. Unset = silent.
    static let hookLogDirectoryVariable = "DECANTER_WINDOWHOOK_DIR"

    /// The size macOS gives a window in native fullscreen on a screen of `screenSize` points,
    /// when `topInset` points are reserved at the top (see `fullscreenTopInset`).
    static func fullscreenContentSize(screenSize: CGSize, topInset: CGFloat) -> CGSize {
        CGSize(width: screenSize.width.rounded(.down),
               height: (screenSize.height - max(0, topInset)).rounded(.down))
    }

    /// How much of the top of the screen a native-fullscreen window does NOT get.
    ///
    /// No notch: 0 — fullscreen covers the menu bar. With a notch, fullscreen starts below the
    /// menu-bar strip, which is one point TALLER than the notch AppKit reports: measured on this
    /// MacBook Air, `safeAreaInsets.top` = 32 but fullscreen windows sit at y = 33 and are 923 tall
    /// on a 956-point screen (`frame.maxY - visibleFrame.maxY` = 33). So the menu-bar height is
    /// used, with the notch height as a floor for when the menu bar auto-hides and
    /// `visibleFrame` stops reflecting it.
    static func fullscreenTopInset(notchHeight: CGFloat, menuBarHeight: CGFloat) -> CGFloat {
        notchHeight > 0 ? max(notchHeight, menuBarHeight) : 0
    }

    /// `fullscreenContentSize` for the screen a new window would open on.
    @MainActor
    static func currentFullscreenContentSize() -> CGSize? {
        guard let screen = NSScreen.main else { return nil }
        let inset = fullscreenTopInset(notchHeight: screen.safeAreaInsets.top,
                                       menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
        return fullscreenContentSize(screenSize: screen.frame.size, topInset: inset)
    }

    /// The two files that define a game host build: if either differs, the installed copy is
    /// stale (an older Decanter put it there) and gets replaced.
    static let gameHostIdentityFiles = ["Contents/Info.plist", "Contents/MacOS/decanter-game-host"]

    /// True when `destination` is missing or isn't byte-identical to `template`.
    static func gameHostNeedsInstall(template: URL, destination: URL,
                                     fileManager: FileManager = .default) -> Bool {
        gameHostIdentityFiles.contains { relative in
            let installed = destination.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: installed.path) else { return true }
            return !fileManager.contentsEqual(atPath: template.appendingPathComponent(relative).path,
                                              andPath: installed.path)
        }
    }

    /// Copies the game-host template out of Decanter.app to `destination` (top level — see
    /// `Paths.installedGameHost` for why it can't run from inside the bundle) when it's missing or
    /// out of date, and returns `destination`. Copies to a sibling first and swaps it in, so a
    /// failed copy never leaves a half-written host behind.
    @discardableResult
    static func installGameHost(template: URL, destination: URL,
                                fileManager: FileManager = .default) throws -> URL {
        guard gameHostNeedsInstall(template: template, destination: destination,
                                   fileManager: fileManager) else { return destination }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).installing-\(UUID().uuidString)")
        // Gone after a successful swap; cleans up only when the copy or swap failed partway.
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: template, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        return destination
    }

    /// The libraries to inject: the window hook, plus `extraInsertVariable` if it is set.
    static func insertLibraries(windowHook: String?, base: [String: String]) -> [String] {
        var libraries: [String] = []
        if let windowHook, !windowHook.isEmpty { libraries.append(windowHook) }
        if let extra = base[extraInsertVariable], !extra.isEmpty { libraries.append(extra) }
        return libraries
    }

    /// The environment for "Decanter Game.app" (Helpers/GameHost/game-host.c), which `exec`s
    /// `loader` with it. Every `DYLD_*` variable travels renamed to `DECANTER_HOST_DYLD_*` and is
    /// restored by the host right before exec: SIP strips dyld variables whenever an Apple system
    /// binary is exec'd on the way, and LaunchServices doesn't promise to forward them either.
    static func hostEnvironment(base: [String: String], loader: String,
                                workingDirectory: String?, windowHook: String?) -> [String: String] {
        var env = base
        env.removeValue(forKey: extraInsertVariable)
        let inserts = insertLibraries(windowHook: windowHook, base: base)
        if !inserts.isEmpty {
            env["DYLD_INSERT_LIBRARIES"] = inserts.joined(separator: ":")
        }
        for key in env.keys.filter({ $0.hasPrefix("DYLD_") }) {
            env["DECANTER_HOST_" + key] = env.removeValue(forKey: key)
        }
        env["DECANTER_HOST_EXEC"] = loader
        if let workingDirectory, !workingDirectory.isEmpty {
            env["DECANTER_HOST_CWD"] = workingDirectory
        }
        return env
    }
}
