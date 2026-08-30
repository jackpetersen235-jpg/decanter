import SwiftUI

@main
struct DecanterApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var themeController = ThemeController()

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
            CommandGroup(replacing: .newItem) {
                Button("New Bottle…") {
                    NotificationCenter.default.post(name: .newBottleRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                // A MENU ITEM HAS NOWHERE TO PUT A RESULT, so these report through the console
                // sheet. Both used to run and return in silence: ⇧⌘R looked identical whether it
                // found five engines or none, and Import CrossOver on a Mac without CrossOver was
                // a complete no-op with its Int result thrown away.
                Button("Rescan Wine Installations") {
                    model.rescanInstallations()
                    let console = model.openConsole(title: "Rescan")
                    console.append(model.lastRescanMessage ?? "Rescan finished.")
                    console.finish()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Import CrossOver Bottles") {
                    let n = model.importCrossOverBottles()
                    let console = model.openConsole(title: "Import CrossOver Bottles")
                    console.append(n > 0
                        ? "Imported \(n) bottle\(n == 1 ? "" : "s") from CrossOver."
                        : "No CrossOver bottles found. CrossOver keeps them in "
                          + "~/Library/Application Support/CrossOver/Bottles.")
                    console.finish()
                }
                Button("Setup Assistant…") {
                    NotificationCenter.default.post(name: .setupAssistantRequested, object: nil)
                }
                Divider()
                // Phase 4 of the pre-release debug plan: after release, a bug happens on a
                // machine nobody here will ever touch, reported by someone who cannot describe
                // it. This is what makes --diagnose/--verify's questions reachable without a
                // terminal — one click, one zip, ready to attach to an email.
                Button("Export Diagnostics…") {
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

extension Notification.Name {
    static let newBottleRequested = Notification.Name("DecanterNewBottleRequested")
    static let setupAssistantRequested = Notification.Name("DecanterSetupAssistantRequested")
}
