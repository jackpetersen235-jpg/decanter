import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.undoManager) private var undoManager
    @State private var showingCreate = false
    @State private var showingSetup = false
    @State private var showingWizard = false

    var body: some View {
        Group {
            if model.bottles.isEmpty || showingWizard || model.isSettingUp {
                // First run: fully automated setup. No Wine knowledge required.
                // Keyed on *bottles*, not on engines: a newcomer who happens to have some other
                // Wine installed (Mythic, Whisky…) must still get the guided path, or they land
                // in a UI they have no way to understand. `isSettingUp` keeps the wizard on screen
                // through the whole run — creating the first bottle makes `bottles` non-empty, and
                // without this the wizard would vanish mid-automation. The wizard skips finished steps.
                // The wizard is a single full-window pane with no sidebar, so it still takes the
                // backdrop directly.
                SetupWizard(dismiss: (showingWizard && !model.isSettingUp) ? { showingWizard = false } : nil)
                    .aeroInk()
            } else {
                splitView
            }
        }
        // The BACKDROP spans the whole window, deliberately — the floating glass panes need
        // something behind them to refract, and a flat window fill gives them nothing. Only the
        // backdrop is applied here; the ink/light-chrome treatment stays on the detail column,
        // which is the surface it was chosen against.
        .themedAtmosphere()
        // Underneath everything: makes the window itself sample the desktop, so the glass panes and
        // buttons have real content to refract instead of an opaque window fill.
        .themedWindowBacking()
        .sheet(isPresented: $showingCreate) { CreateBottleSheet() }
        .sheet(isPresented: $showingSetup) { SetupSheet() }
        .sheet(item: $model.activeConsole) { console in
            ConsoleView(console: console)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBottleRequested)) { _ in
            showingCreate = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .setupAssistantRequested)) { _ in
            showingWizard = true
        }
        // Bottle ▸ Delete… — handled here because this view owns the window's undo manager and
        // the with-files confirmation.
        .onReceive(NotificationCenter.default.publisher(for: .deleteBottleRequested)) { note in
            guard let id = note.object as? Bottle.ID,
                  let bottle = model.bottles.first(where: { $0.id == id }) else { return }
            if note.userInfo?["removeFiles"] as? Bool == true {
                pendingDeletion = bottle
            } else {
                model.removeBottleKeepingFiles(bottle, undoManager: undoManager)
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")” and all its files?",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Bottle & Files", role: .destructive) {
                if let bottle = pendingDeletion { model.deleteBottle(bottle, removeFiles: true) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This permanently erases the Windows drive for this bottle — installed games and "
               + "their save files. This cannot be undone.")
        }
        // F3 (bug-sweep): the salvage path in `loadBottles` worked but was invisible — reported
        // only via NSLog, which nobody but Console.app ever sees. Same binding idiom as
        // `pendingDeletion` above: driven by the model clearing to nil, not by local state.
        .alert("Some bottles couldn't be loaded",
              isPresented: Binding(get: { model.bottleSalvageWarning != nil },
                                   set: { if !$0 { model.bottleSalvageWarning = nil } })) {
            Button("OK") { model.bottleSalvageWarning = nil }
        } message: {
            Text(model.bottleSalvageWarning ?? "")
        }
        // F6 (bug-sweep): Play used to stay disabled for a flat 30s no matter what happened, then
        // quietly re-enable — a launch that never produced anything looked identical to one that
        // worked. Same binding idiom as the two alerts above.
        .alert("Couldn't launch",
              isPresented: Binding(get: { model.lastLaunchFailure != nil },
                                   set: { if !$0 { model.lastLaunchFailure = nil } })) {
            Button("OK") { model.lastLaunchFailure = nil }
        } message: {
            Text(model.lastLaunchFailure ?? "")
        }
        // F13 (bug-sweep): a failed save was NSLog-only, contradicting saveBottles's own doc
        // comment. Same binding idiom as the three alerts above.
        .alert("Couldn't save",
              isPresented: Binding(get: { model.lastSaveFailure != nil },
                                   set: { if !$0 { model.lastSaveFailure = nil } })) {
            Button("OK") { model.lastSaveFailure = nil }
        } message: {
            Text(model.lastSaveFailure ?? "")
        }
    }

    /// The window's layout, in every theme: the system's own split view, toolbar and window title.
    ///
    /// Measured against System Settings and Notes (docs/APPLE-GEOMETRY.md), every way the old
    /// hand-laid-out columns looked "not quite Apple" came from building the chrome by hand: no
    /// toolbar (so the traffic lights sat 10pt higher than in any toolbar window), a full-height
    /// square sidebar instead of Tahoe's floating one (8pt inset, corners concentric with the
    /// window), a custom header band instead of the window title, 28pt rows instead of 32. These
    /// containers produce all of those numbers themselves.
    ///
    /// The themed looks used an `HStack` instead, because the split view's sidebar brought a vibrancy
    /// backdrop that kept a Liquid Glass sidebar grey over the clear window. On macOS 26 that sidebar
    /// IS a floating Liquid Glass pane, so the reason is gone — and the themes now differ only in their
    /// surfaces (sky, clear window, ink), never in layout.
    private var splitView: some View {
        NavigationSplitView {
            bottleList
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
                // Pinned under the list, inside the floating sidebar, the way Mail and Notes pin
                // their footers. The gear lives here, beside the engine status it manages: the
                // sidebar's share of the toolbar holds the traffic lights, + and the sidebar toggle,
                // and a third button there overflowed into a ">>" menu.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack(spacing: 0) {
                        wineStatusFooter
                        // F9 (bug-sweep): icon-only buttons need a real accessibility label;
                        // `.help()` is only the hover tooltip/VoiceOver hint.
                        Button { showingSetup = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .buttonStyle(.borderless)
                        .help("Wine installations & system checks")
                        .accessibilityLabel("Wine installations and system checks")
                        .padding(.trailing, 12)
                    }
                }
                .toolbar {
                    ToolbarItem {
                        Button { showingCreate = true } label: {
                            Label("New Bottle", systemImage: "plus")
                        }
                        .help("Create a new bottle")
                        .disabled(model.defaultInstallation == nil)
                    }
                }
                // Aero's light chrome and ink reach the sidebar too — without it the sidebar stays
                // in the dark colour scheme against a light sky. No-op in the other themes.
                .aeroInk()
                .tonedText()
        } detail: {
            detail
                .aeroInk()
                .tonedText()
                // Its own surface. The window is genuinely clear in Liquid Glass, so a pane with no
                // background would sit its text straight on the desktop wallpaper. No-op elsewhere.
                .themedPaneSurface()
        }
    }

    @ViewBuilder
    private func bottleContextMenu(_ bottle: Bottle) -> some View {
        Button("Open C: Drive") { model.openCDrive(bottle) }
        Button("Apply Settings to Prefix") { model.applySettings(bottle) }
        Divider()
        // Undoable (Edit ▸ Undo), since it only removes the entry — no confirmation needed.
        Button("Delete Bottle (keep files)") {
            model.removeBottleKeepingFiles(bottle, undoManager: undoManager)
        }
        // Destructive + irreversible: a prefix holds the game install AND its saves (10-100 GB,
        // and saves exist nowhere else). This is a context-menu item one slip away from the
        // harmless "keep files" entry, so it MUST confirm first.
        Button("Delete Bottle & Files…", role: .destructive) {
            pendingDeletion = bottle
        }
    }

    /// Bottle awaiting delete-with-files confirmation.
    @State private var pendingDeletion: Bottle?

    /// The bottle list in the sidebar.
    ///
    /// Routed through `userSelectedBottle`, not a direct binding to `selectedBottleID` — this is
    /// the ONE place a selection change means the user actually chose a bottle. `selectedBottleID`
    /// itself is reassigned programmatically in several other places (after a delete, a create, a
    /// CrossOver import); a plain `$model.selectedBottleID` binding here couldn't tell those apart
    /// from a real click, and warm-starting Steam after a delete reassigns selection is exactly the
    /// trap that ruled that out.
    private var bottleList: some View {
        List(selection: Binding(get: { model.selectedBottleID },
                                set: { model.userSelectedBottle($0) })) {
            Section("Bottles") {
                ForEach(model.bottles) { bottle in
                    BottleRow(bottle: bottle, setupState: model.setupState(of: bottle))
                        .tag(bottle.id)
                        .contextMenu { bottleContextMenu(bottle) }
                        // A sidebar separates rows with spacing, not rules. The plain list drew a
                        // line under every bottle, which made six rows look like a table.
                        .listRowSeparator(.hidden)
                }
            }
        }
        // The Delete key (and Edit ▸ Delete) on a selected bottle: removes the entry and keeps the
        // files, undoable with ⌘Z — what Delete does to a selected item in Mail or Notes. Only
        // fires while the list has focus, so typing in a field never deletes a bottle.
        .onDeleteCommand {
            guard let bottle = model.bottles.first(where: { $0.id == model.selectedBottleID })
            else { return }
            model.removeBottleKeepingFiles(bottle, undoManager: undoManager)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selectedBottleID,
           let bottle = model.bottles.first(where: { $0.id == id }) {
            BottleDetailView(bottle: bottle)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "wineglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)      // decorative
                Text("Select a bottle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if model.defaultInstallation != nil {
                    Button("Create a Bottle") { showingCreate = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var wineStatusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.defaultInstallation != nil ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                if let installation = model.defaultInstallation {
                    Text(installation.name).font(.caption).lineLimit(1)
                    Text(installation.version ?? "Wine build detected")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("No Wine build found").font(.caption)
                    Text("Open Setup to add one").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One row in the bottle sidebar.
private struct BottleRow: View {
    let bottle: Bottle
    let setupState: BottleSetupState
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        // A `Label`, so the Standard sidebar treats the symbol as the row's icon.
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(bottle.name).lineLimit(1)
                // One line for a healthy bottle; a second only when it needs attention.
                if let caption = setupState.sidebarCaption(isSteamInstalled: bottle.isSteamInstalled) {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } icon: {
            icon
                // Decorative: the caption says so in words whenever Steam is missing.
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        // The 264pt sidebar cuts long game names ("JoJo's Bizarre Adventure: All-Star…"), and a
        // SwiftUI Text gets no automatic expansion tooltip the way an AppKit table cell does.
        .help(bottle.name)
    }

    /// Uncoloured in Standard: the sidebar list tints a Label's icon with the accent colour and
    /// turns it white on the selected row. Colouring it by hand (accent, as the themed looks do)
    /// made it vanish into the accent-filled selection. The themed looks use a plain list, which
    /// tints nothing, so they keep the explicit colour.
    @ViewBuilder
    private var icon: some View {
        let image = Image(systemName: bottle.isSteamInstalled ? "gamecontroller.fill" : "cube.box")
        if appTheme == .system {
            image
        } else {
            image.foregroundStyle(bottle.isSteamInstalled ? Color.accentColor : .secondary)
        }
    }
}
