import SwiftUI

/// The Bottle menu: the selected bottle's actions in the menu bar, so they can be reached without
/// a pointer and found by searching Help ▸ (HIG Keyboards: support Full Keyboard Access, and give
/// the most frequent app-specific command a shortcut). Play/Launch Steam gets ⌘↩ — not ⌘R, which
/// would make Launch and Rescan (⇧⌘R) the same key differing only by Shift.
///
/// Delete has no menu shortcut on purpose: menu shortcuts fire even while typing, so ⌘⌫ in the
/// Steam-arguments field would delete the bottle. The sidebar list takes the Delete key instead
/// (`onDeleteCommand` in `ContentView`), which only fires when the list has focus.
///
/// Anything that needs a confirmation or the window's undo manager is posted to the window, which
/// owns that state — the same route New Bottle… takes.
struct BottleCommands: View {
    @ObservedObject var model: AppModel

    private var bottle: Bottle? {
        model.bottles.first { $0.id == model.selectedBottleID }
    }

    var body: some View {
        let isLaunching = bottle.map { model.launchingBottleIDs.contains($0.id) } ?? false
        let hasSteam = bottle?.isSteamInstalled == true

        // Named after the bottle: "Launch Steam" on the Steam bottle, "Launch Peggle Deluxe" on a
        // game. Telling the two apart the way the detail pane does (`resolvedGame`) walks the game
        // folder, which is too much work for a menu that re-renders on every model change.
        Button(bottle.map { "Launch \($0.name)" } ?? "Launch") {
            if let bottle { model.launchSteam(in: bottle) }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!hasSteam || isLaunching)

        Button("Quit Steam…") { post(.quitSteamRequested) }
            .disabled(!hasSteam)

        Divider()

        Button("Open C: Drive") { if let bottle { model.openCDrive(bottle) } }
            .disabled(bottle == nil)
        // Also in the context menu and on the Overview tab; the menu bar should hold every command.
        Button("Apply Settings to Prefix") { if let bottle { model.applySettings(bottle) } }
            .disabled(bottle == nil)

        Divider()

        Button("Delete Bottle (keep files)") { post(.deleteBottleRequested, removeFiles: false) }
            .disabled(bottle == nil)
        Button("Delete Bottle & Files…") { post(.deleteBottleRequested, removeFiles: true) }
            .disabled(bottle == nil)
    }

    private func post(_ name: Notification.Name, removeFiles: Bool = false) {
        guard let bottle else { return }
        NotificationCenter.default.post(name: name, object: bottle.id,
                                        userInfo: ["removeFiles": removeFiles])
    }
}

/// View ▸ Overview / Configuration / Programs (⌘1–⌘3): the detail pane's tabs as menu items, as
/// the HIG suggests for tab-style navigation. Built from `BottleDetailView.Tab` so the menu can
/// never list a tab the pane doesn't have.
struct DetailTabCommands: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ForEach(Array(BottleDetailView.Tab.allCases.enumerated()), id: \.element) { index, tab in
            Button(tab.rawValue) {
                NotificationCenter.default.post(name: .detailTabRequested, object: tab)
            }
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            .disabled(model.selectedBottleID == nil)
        }
    }
}
