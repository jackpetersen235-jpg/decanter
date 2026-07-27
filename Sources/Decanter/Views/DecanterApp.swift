import SwiftUI

@main
struct DecanterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
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
                .frame(width: 520, height: 420)
        }
    }
}

extension Notification.Name {
    static let newBottleRequested = Notification.Name("DecanterNewBottleRequested")
    static let setupAssistantRequested = Notification.Name("DecanterSetupAssistantRequested")
}
