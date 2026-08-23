import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
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
    }

    /// Two columns laid out by hand rather than by `NavigationSplitView`.
    ///
    /// The split view's sidebar column is an `NSSplitViewItem` with sidebar behaviour, and that
    /// installs a vibrancy backdrop BELOW anything SwiftUI can reach — it kept the left column grey
    /// while the detail pane was clear. Neither
    /// `.containerBackground(.clear, for: .navigationSplitView)` (iOS only) nor hiding the
    /// `NSVisualEffectView` from either direction touched it.
    ///
    /// An `HStack` has no such backdrop, so the clear window shows through. The cost is the system
    /// sidebar behaviour: the collapse animation and its toggle button. The width is handled here
    /// instead.
    private var splitView: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 264)
                // Lifted slightly and given a real edge. Laid out by hand, the two columns had no
                // boundary at all, and one continuous sky behind both turned the join into an
                // accidental-looking seam.
                .sidebarLift()

            ColumnSeparator()

            // Wizard wallpaper removed. In Aero the atmosphere is the backdrop, and two competing
            // background images read as clutter; in Liquid Glass the detail pane is cleaner
            // without it. `Wallpaper` itself is kept — the app icon still uses the artwork.
            //
            // Hiding the title bar removes the STRIP but SwiftUI still reserves its height as a
            // top safe-area inset, which left an empty band above the header panel. Ignoring that
            // inset is what actually reclaims the space. Only the detail column does this — the
            // sidebar keeps its inset, because the traffic lights float there.
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
                .aeroInk()
                .tonedText()
                // Its own surface. The window is genuinely clear in Liquid Glass, so a pane with
                // no background would sit its text straight on the desktop wallpaper.
                .themedPaneSurface()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // These two used to live in the window toolbar. The toolbar is gone — it drew an
            // unthemed white strip across the top of the window that duplicated the header panel's
            // title — so they move into the sidebar itself. The leading gap is clearance for the
            // traffic lights, which now float over the content; they are deliberately left alone
            // rather than restyled.
            HStack(spacing: 6) {
                Spacer(minLength: 74)
                Button { showingCreate = true } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Create a new bottle")
                .disabled(model.defaultInstallation == nil)

                Button { showingSetup = true } label: {
                    Image(systemName: "gearshape").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Wine installations & system checks")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)

            // .plain, not .sidebar: the sidebar list style reintroduces its own vibrancy, which
            // is the exact thing this layout exists to get rid of.
            List(selection: $model.selectedBottleID) {
                Section("Bottles") {
                    ForEach(model.bottles) { bottle in
                        BottleRow(bottle: bottle)
                            .tag(bottle.id)
                            .contextMenu { bottleContextMenu(bottle) }
                    }
                }
            }
            Divider()
            wineStatusFooter
        }
        .listStyle(.plain)
        // The sidebar needs the Aero treatment too, and did not have it: `aeroInk()` was applied
        // only to the detail column and the wizard. Without it the sidebar stayed in the DARK
        // colour scheme and its List kept painting an opaque dark backdrop — because
        // `scrollContentBackground(.hidden)` lives inside `GlassPane`, which is a no-op in Aero.
        // That is what made the left side very dark while the right showed the sky.
        .aeroInk()
        .tonedText()
        // Floated and inset so the material has four visible edges to refract along. Full-bleed,
        // the rim — where the whole effect lives — is clipped off and only a flat tint remains.
        // Was an unconditional `.glassPane`, which meant Standard still got a floating glass
        // sidebar — the whole reason "Standard" still looked like Liquid Glass.
        .themedPaneSurface(cornerRadius: 18, inset: 10,
                           plainFill: Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func bottleContextMenu(_ bottle: Bottle) -> some View {
        Button("Open C: Drive") { model.openCDrive(bottle) }
        Button("Apply Settings to Prefix") { model.applySettings(bottle) }
        Divider()
        Button("Delete Bottle (keep files)") { model.deleteBottle(bottle, removeFiles: false) }
        // Destructive + irreversible: a prefix holds the game install AND its saves (10-100 GB,
        // and saves exist nowhere else). This is a context-menu item one slip away from the
        // harmless "keep files" entry, so it MUST confirm first.
        Button("Delete Bottle & Files…", role: .destructive) {
            pendingDeletion = bottle
        }
    }

    /// Bottle awaiting delete-with-files confirmation.
    @State private var pendingDeletion: Bottle?

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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: bottle.isSteamInstalled ? "gamecontroller.fill" : "cube.box")
                .foregroundStyle(bottle.isSteamInstalled ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(bottle.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if !bottle.isInitialized { return "Initializing…" }
        if bottle.isSteamInstalled { return "Steam ready" }
        return bottle.settings.windowsVersion.label
    }
}
