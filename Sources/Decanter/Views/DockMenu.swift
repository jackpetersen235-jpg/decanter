import AppKit

/// Decanter's Dock menu: launch any bottle straight from the Dock icon, without bringing the window
/// forward first (HIG Dock menus: short, and focused on what people do most while the app runs).
/// Which bottles appear is `DockMenuEntries`; this only turns those entries into an `NSMenu`.
@MainActor
enum DockMenu {
    static func make(for model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false       // honour each entry's isEnabled
        let entries = DockMenuEntries.make(for: model.bottles, hasSteam: { $0.isSteamInstalled },
                                           launching: model.launchingBottleIDs)
        for entry in entries {
            let item = ClosureMenuItem(title: entry.title) { [weak model] in
                guard let model,
                      let bottle = model.bottles.first(where: { $0.id == entry.bottleID }) else { return }
                model.launchSteam(in: bottle)
            }
            item.isEnabled = entry.isEnabled
            menu.addItem(item)
        }
        return menu
    }
}

/// An `NSMenuItem` that runs a closure, so the Dock menu needs no responder-chain selectors.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("ClosureMenuItem is never decoded") }

    @objc private func run() { handler() }
}
