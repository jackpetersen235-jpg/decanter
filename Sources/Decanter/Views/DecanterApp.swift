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
                .frame(minWidth: 940, minHeight: 580)
                // Clear a Steam menu-bar icon left behind by a previous session. Wine's
                // explorer.exe is not a child of steam.exe, so quitting Steam leaves its
                // NSStatusItem in the menu bar indefinitely. This only fires when nothing is
                // running in any bottle, so a live game's virtual desktop is never touched.
                .task { model.reapOrphanedSystray() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bottle…") {
                    NotificationCenter.default.post(name: .newBottleRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Rescan Wine Installations") { model.rescanInstallations() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Import CrossOver Bottles") { model.importCrossOverBottles() }
                Button("Setup Assistant…") {
                    NotificationCenter.default.post(name: .setupAssistantRequested, object: nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(themeController)
                .environment(\.appTheme, themeController.theme)
                .frame(width: 520, height: 460)
        }
    }
}

extension Notification.Name {
    static let newBottleRequested = Notification.Name("DecanterNewBottleRequested")
    static let setupAssistantRequested = Notification.Name("DecanterSetupAssistantRequested")
}
