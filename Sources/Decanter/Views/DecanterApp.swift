import SwiftUI

@main
struct DecanterApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var themeController = ThemeController()
    @NSApplicationDelegateAdaptor(QuitGuard.self) private var quitGuard

    init() {
        // One window over one bottle list. The system's window tabs (View ▸ Show Tab Bar, Show All
        // Tabs) could only ever offer a second copy of the same window, so they're switched off
        // rather than left as menu items that lead nowhere useful.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(themeController)
                // Injected once, at the root. Every themed component reads it from the
                // environment, which is what makes switching all-or-nothing: there is no path by
                // which one screen can disagree with another about the active theme.
                .environment(\.appTheme, themeController.theme)
                .environment(\.textTone, themeController.textTone)
                .frame(minWidth: 940, minHeight: 580)
                // Clear a Steam menu-bar icon left behind by a previous session. Wine's
                // explorer.exe is not a child of steam.exe, so quitting Steam leaves its
                // NSStatusItem in the menu bar indefinitely. This only fires when nothing is
                // running in any bottle, so a live game's virtual desktop is never touched.
                .task { model.reapOrphanedSystray() }
                .task { quitGuard.model = model }
        }
        // Removes the title-bar STRIP while keeping the window controls.
        //
        // `.toolbar(.hidden, for: .windowToolbar)` was tried first and is wrong: it takes the
        // close, minimise and zoom buttons with it, leaving a window that cannot be closed.
        // `.hiddenTitleBar` drops the chrome and lets the traffic lights float over the content —
        // which is why the sidebar's button row carries a 74pt leading gap to clear them. The
        // lights themselves are left exactly as the system draws them.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Menus follow the HIG menu-bar layout (2026-11-02): creating and importing bottles in
            // File, ways of looking at the window in View, the selected bottle's actions in
            // Bottle, support tools in Help. Import and Export Diagnostics used to sit in View.
            //
            // A MENU ITEM HAS NOWHERE TO PUT A RESULT, so Rescan, Import and Export report through
            // the console sheet. They used to run and return in silence: ⇧⌘R looked identical
            // whether it found five engines or none, and Import CrossOver on a Mac without
            // CrossOver was a complete no-op with its Int result thrown away.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await model.checkForUpdatesInteractively() } }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Bottle…") {
                    NotificationCenter.default.post(name: .newBottleRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Import CrossOver Bottles") {
                    let n = model.importCrossOverBottles()
                    let console = model.openConsole(title: "Import CrossOver Bottles")
                    console.append(n > 0
                        ? "Imported \(n) bottle\(n == 1 ? "" : "s") from CrossOver."
                        : "No CrossOver bottles found. CrossOver keeps them in "
                          + "~/Library/Application Support/CrossOver/Bottles.")
                    console.finish()
                }
            }
            CommandGroup(after: .toolbar) {
                DetailTabCommands(model: model)
                Divider()
                Button("Rescan Wine Installations") {
                    model.rescanInstallations()
                    let console = model.openConsole(title: "Rescan")
                    console.append(model.lastRescanMessage ?? "Rescan finished.")
                    console.finish()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Setup Assistant…") {
                    NotificationCenter.default.post(name: .setupAssistantRequested, object: nil)
                }
            }
            CommandGroup(after: .help) {
                // Phase 4 of the pre-release debug plan: after release, a bug happens on a
                // machine nobody here will ever touch, reported by someone who cannot describe
                // it. This is what makes --diagnose/--verify's questions reachable without a
                // terminal — one click, one zip, ready to attach to an email. No ellipsis: it
                // asks nothing, it saves straight to the Desktop.
                Button("Export Diagnostics") {
                    let console = model.openConsole(title: "Export Diagnostics")
                    console.append("Gathering engine, bottle and log info…")
                    Task {
                        do {
                            let zipURL = try await DiagnosticsExporter.exportAndReveal(model: model)
                            console.append("Saved to \(zipURL.lastPathComponent) on the Desktop.")
                            console.finish(0)
                        } catch {
                            console.append("Failed: \(error.localizedDescription)")
                            console.finish(1)
                        }
                    }
                }
            }
            CommandMenu("Bottle") { BottleCommands(model: model) }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(themeController)
                .environment(\.appTheme, themeController.theme)
                .environment(\.textTone, themeController.textTone)
                .frame(width: 520, height: 500)
        }
    }
}

/// Decanter's app delegate. Two jobs:
///
/// - Asks before quitting while a game launch is still waiting on Steam's sign-in — every quit
///   path (⌘Q, the Dock, the app switcher) goes through `applicationShouldTerminate`. On 2026-10-21
///   a Dock quit 22 s before Steam signed in silently cost a Peggle launch.
/// - Supplies the Dock icon's menu (`DockMenu`): Launch <bottle> for each bottle.
final class QuitGuard: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model else { return nil }
        return DockMenu.make(for: model)
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let warning = model?.quitWarning() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = warning.title
        alert.informativeText = warning.message
        alert.addButton(withTitle: "Keep Waiting")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}

extension Notification.Name {
    static let newBottleRequested = Notification.Name("DecanterNewBottleRequested")
    static let setupAssistantRequested = Notification.Name("DecanterSetupAssistantRequested")
    /// Bottle menu → window. `object` is the bottle's id; `userInfo["removeFiles"]` a Bool.
    static let deleteBottleRequested = Notification.Name("DecanterDeleteBottleRequested")
    /// Bottle menu → detail pane. `object` is the bottle's id.
    static let quitSteamRequested = Notification.Name("DecanterQuitSteamRequested")
    /// View menu → detail pane. `object` is a `BottleDetailView.Tab`.
    static let detailTabRequested = Notification.Name("DecanterDetailTabRequested")
}
