import SwiftUI

struct BottleDetailView: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle

    /// Not private: View ▸ Overview/Configuration/Programs (`DetailTabCommands`) is built from it.
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case configuration = "Configuration"
        case programs = "Programs"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .overview
    @State private var installingGFX = false
    @State private var gfxResult: String?
    @State private var confirmQuit = false
    @State private var quitting = false
    @State private var quitResult: String?
    @State private var showQuitBlocked = false
    @State private var quitBlockReason: String?

    /// The two buttons that use a CUSTOM style in Aero, and so lose the focus ring macOS draws for
    /// system styles. Everything else in the app is on `.glass`/`.glassProminent`/`.bordered` and
    /// gets its ring for free.
    private enum CustomStyledControl: Hashable { case play, launchSteam }
    @FocusState private var focusedControl: CustomStyledControl?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The one piece of state the old header panel carried that the window title can't.
            if model.setupState(of: bottle) != .ready {
                HStack(spacing: 8) { setupStatus }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            ScrollView {
                switch tab {
                case .overview:      overview
                case .configuration: ConfigurationView(bottle: model.binding(for: bottle))
                case .programs:      ProgramsView(bottle: bottle)
                }
            }
        }
        // The bottle's name and engine are the window's title and subtitle, and the section picker is
        // the toolbar's centre item, on the traffic lights' line as in every Apple app
        // (docs/APPLE-GEOMETRY.md). Every theme: they used to draw a raised header panel instead,
        // and the themes now differ only in surfaces, not layout.
        .navigationTitle(bottle.name)
        .navigationSubtitle(model.installation(for: bottle)?.name ?? "No Wine build")
        .toolbar {
            ToolbarItem(placement: .principal) { sectionPicker }
        }
        // View ▸ Overview / Configuration / Programs (⌘1–⌘3).
        .onReceive(NotificationCenter.default.publisher(for: .detailTabRequested)) { note in
            if let requested = note.object as? Tab { tab = requested }
        }
        // Bottle ▸ Quit Steam… — the same path as the button, refusal and confirmation included.
        .onReceive(NotificationCenter.default.publisher(for: .quitSteamRequested)) { note in
            if note.object as? Bottle.ID == bottle.id, !quitting { requestQuit() }
        }
        // Confirmed, not immediate: this is `wineserver -k` on the whole prefix, so a game that is
        // still running dies with it and unsaved progress goes with it.
        //
        // The message used to say "any game running in THIS BOTTLE" — wrong when bottles share a
        // prefix (Steam, Sekiro, JJBA and Peggle all share Steam-Wine11 here): `wineserver -k` is
        // scoped to the PREFIX, so it can kill a sibling bottle's game. Now names the real blast
        // radius when there is one, via `PrefixSharing`. See `quitBlockAlert` for the refusal this
        // pairs with — checked BEFORE this dialog even opens.
        .confirmationDialog("Quit Steam in “\(bottle.name)”?",
                            isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Quit Steam", role: .destructive) {
                quitting = true
                quitResult = nil
                Task {
                    let ok = await model.quitSteam(in: bottle)
                    quitResult = ok
                        ? "Steam has been shut down."
                        : (model.lastQuitSteamFailure
                           ?? "Steam did not shut down — try again, or restart your Mac.")
                    quitting = false
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            let others = model.otherBottlesSharingPrefix(with: bottle)
            if others.isEmpty {
                Text("This also closes any game running in this bottle. Unsaved progress will be lost.")
            } else {
                Text("This prefix is shared with \(others.map(\.name).joined(separator: ", ")). "
                     + "Quitting Steam closes any game running in ANY of them. Unsaved progress "
                     + "will be lost.")
            }
        }
        // Refusal, shown INSTEAD of the confirmation above — see `quitSteamBlockReason` for why
        // this can only be conservative rather than precise (no per-prefix process attribution
        // exists on macOS without real new work). Fires before `confirmQuit` is ever set.
        .alert("Can't quit Steam right now", isPresented: $showQuitBlocked) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(quitBlockReason ?? "")
        }
    }

    /// Overview / Configuration / Programs. Labelled for VoiceOver even though `.labelsHidden()`
    /// keeps it off screen — an empty title left the control unnamed.
    private var sectionPicker: some View {
        Picker("Bottle section", selection: $tab) {
            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// A spinner only while setup is really running. A bottle whose setup was cut short (Decanter
    /// quit mid-setup) used to show this spinner forever, with nothing behind it.
    @ViewBuilder
    private var setupStatus: some View {
        switch model.setupState(of: bottle) {
        case .inProgress:
            ProgressView().controlSize(.small)
            Text("Setting up…").font(.caption).foregroundStyle(.secondary)
        case .interrupted:
            StatusNote("Setup didn't finish. Delete this bottle and create it again.")
        case .ready:
            EmptyView()
        }
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Primary gaming actions.
            GroupBox("Steam") {
                VStack(alignment: .leading, spacing: 12) {
                    // An engine older than wine 8 will start Steam and then kill it with
                    // "Failed to load steamui.dll" — a fatal error that names a DLL instead of the
                    // real cause. Say so BEFORE the user clicks Launch.
                    if let inst = model.installation(for: bottle), !inst.isSteamCapable {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("This bottle's engine is too old for Steam")
                                    .font(.callout.weight(.semibold))
                                Text("\(inst.name) \(inst.version ?? "") cannot load modern Steam "
                                     + "(it fails with \"Failed to load steamui.dll\"). "
                                     + "Run View ▸ Setup Assistant to install the Decanter engine, "
                                     + "then make a new bottle.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .padding(.bottom, 4)
                    }

                    if bottle.isSteamInstalled {
                        let launching = model.launchingBottleIDs.contains(bottle.id)
                        // Distinguish "steam.exe exists" from "Steam can actually run". Until the
                        // first launch downloads the client, Steam dies with "Failed to load
                        // steamui.dll", and saying only "Steam is installed" makes that look like
                        // a broken install rather than an unfinished one.
                        // Nothing to say when Steam is ready — the buttons below say it. (This used
                        // to print "Steam is installed in this bottle." above every Launch button.)
                        if !bottle.isSteamBootstrapped {
                            Text("Steam is installed but hasn't finished setting itself up yet.")
                                .foregroundStyle(.secondary)
                            Text("The first launch downloads the Steam client (a few hundred MB). "
                                 + "Leave it running until the login window appears — it can take "
                                 + "several minutes.")
                                .font(.caption).foregroundStyle(.secondary)
                            // Real progress while it downloads, so it never looks frozen. Steam
                            // shows no window and no percentage of its own; this reads its log and
                            // package folder every 2 s (SteamBootstrapProgress).
                            if launching {
                                TimelineView(.periodic(from: .now, by: 2)) { _ in
                                    if let p = model.steamBootstrapProgress(for: bottle) {
                                        ProgressView(value: Double(p.done), total: Double(p.total)) {
                                            Text("Steam is downloading itself — \(p.done / 1_000_000) of "
                                                 + "\(p.total / 1_000_000) MB")
                                                .font(.caption)
                                        }
                                    } else {
                                        Text("Steam is getting ready…").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        HStack {
                            // PLAY COMES FIRST. On a game bottle this is what the user came here
                            // to do — Steam is only the delivery mechanism — so it leads, and the
                            // Steam button steps down to secondary styling beside it. Absent on a
                            // plain launcher bottle, where "Launch Steam" is the primary action
                            // and keeps its prominence.
                            let game = model.resolvedGame(for: bottle)
                            if game != nil {
                                Button {
                                    // Launch the game DIRECTLY. Decanter used to open a generated
                                    // .app that then started Steam and the game — an extra hop that
                                    // bought nothing: `launchSteam` already waits for Steam, honours
                                    // direct-exe bottles and installs the graphics driver first.
                                    model.launchSteam(in: bottle)
                                } label: {
                                    // Reflect the REAL launching state. This said "Play" forever and
                                    // was `.disabled(buildingApp)` — a flag that died with the
                                    // launcher generator and is never set true, so Play never
                                    // disabled and never acknowledged a click. Only Launch Steam
                                    // did, which is why one button felt responsive and the other
                                    // felt broken.
                                    Label(launching ? "Opening…" : "Play",
                                          systemImage: "gamecontroller.fill")
                                }
                                // Lime in Aero — the theme's signature accent — and its shadow
                                // takes that hue rather than neutral gray. Liquid glass ignores
                                // the accent and refracts instead.
                                .themedButton(prominent: true, accent: AeroTokens.lime)
                                .focused($focusedControl, equals: .play)
                                .aeroFocusRing(focusedControl == .play)
                                .disabled(launching)
                            }

                            // Two spellings of the same button because SwiftUI's ButtonStyle is not
                            // type-erasable without a wrapper, and one small duplication reads
                            // better here than a custom AnyButtonStyle would.
                            if game == nil {
                                Button { model.launchSteam(in: bottle) } label: { steamLabel(launching) }
                                    .themedButton(prominent: true)
                                    .focused($focusedControl, equals: .launchSteam)
                                    .aeroFocusRing(focusedControl == .launchSteam)
                                    .disabled(launching)
                            } else {
                                Button { model.launchSteam(in: bottle) } label: { steamLabel(launching) }
                                    .themedButton()
                                    .focused($focusedControl, equals: .launchSteam)
                                    .aeroFocusRing(focusedControl == .launchSteam)
                                    .disabled(launching)
                            }

                            // Decanter starts Steam; it must also be able to stop it. Without this
                            // a `-silent` Steam sits in the tray with no window and survives every
                            // attempt to quit it from Steam's own UI (closing the window just
                            // re-hides it), with no control anywhere in the app to end it.
                            Button(quitting ? "Quitting…" : "Quit Steam") { requestQuit() }
                                .glassButton()
                                .disabled(quitting)

                            // The two maintenance actions, behind one pull-down. As full buttons they
                            // made a row of four equal-weight controls, so nothing on the screen read
                            // as the thing to press. Both stay one click away: Install Graphics Driver
                            // is re-runnable on purpose (the wizard installs it after Steam, but a
                            // fresh library has no games yet, so it must be reachable afterwards).
                            Menu("More") {
                                Button("Reinstall Steam") { model.installSteam(in: bottle) }
                                Button(installingGFX ? "Installing Graphics Driver…"
                                                     : "Install Graphics Driver") {
                                    installGraphicsDriver()
                                }
                                .disabled(installingGFX)
                            }
                            .menuStyle(.button)
                            .glassButton()
                            .fixedSize()
                            .help("Reinstall Steam or install the graphics driver")
                            .accessibilityLabel("More Steam actions")
                        }
                        // One shared sampling region for the whole row. Without it each glass
                        // button samples independently and they render as flat capsules.
                        .glassGroup()
                        // Warm-start (selection-triggered background Steam boot, see
                        // `userSelectedBottle`): says what's happening rather than looking idle
                        // while a ~30s cold boot runs unseen — showing "ready" before logon
                        // actually completes is the F27 complaint in a new costume. Play itself
                        // stays enabled throughout; pressing it joins the warm-up rather than
                        // waiting on this text to clear.
                        if model.warmingPrefixKeys.contains(PrefixSharing.key(for: bottle.url)) {
                            Label("Preparing Steam…", systemImage: "hourglass")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        // A plain Steam bottle: say how a newly installed game gets into Decanter.
                        // Nothing else did, and the graphics driver is put in place only when
                        // Decanter starts Steam — so a game installed and then started from Steam's
                        // own window ran on the slow fallback renderer, which is how "it's slow"
                        // reports start.
                        if model.resolvedGame(for: bottle) == nil, bottle.isSteamBootstrapped {
                            Text("Games you install in Steam appear in the sidebar by themselves "
                                 + "once they finish installing. Click one, then press Play. "
                                 + "Decanter sets up a game's graphics when it starts Steam, so a "
                                 + "game started from Steam's own window can run slowly the first "
                                 + "time.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let gfxResult {
                            Text(gfxResult).font(.caption).foregroundStyle(.secondary)
                        }
                        if let quitResult {
                            Text(quitResult).font(.caption).foregroundStyle(.secondary)
                        }
                        // The generated launcher bakes in the bottle's settings at build time, so
                        // it goes stale when those change. Rebuilding is explicit rather than
                        // automatic — silently rewriting a bundle the user may have moved or
                        // renamed in Finder would be worse than an out-of-date one.
                        if let game = model.resolvedGame(for: bottle) {
                            // Name what Play will actually start. The resolver picks the biggest
                            // executable, and on UE titles that is a deep Shipping.exe rather than
                            // the obvious top-level one — worth showing so a wrong pick is visible
                            // rather than mysterious.
                            Text("Play starts \(game.executable.lastPathComponent)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.launchesWaitingForSteam.contains(bottle.id) {
                            Label(LaunchWait.caption(gameName: bottle.name), systemImage: "hourglass")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if launching {
                            Text(LaunchWait.openingCaption)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Install the Steam client to start downloading and playing games.")
                            .foregroundStyle(.secondary)
                        Button {
                            model.installSteam(in: bottle)
                        } label: {
                            Label("Install Steam", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!bottle.isInitialized)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Bottle") {
                VStack(alignment: .leading, spacing: 10) {
                    infoRow("Windows version", bottle.settings.windowsVersion.label)
                    infoRow("Graphics", bottle.settings.graphics.label)
                    infoRow("Sync", bottle.settings.syncMode.label)
                    // The folder's name, not its path. The full path wrapped across two lines of
                    // monospaced type and was the widest thing on the screen; it is one hover away.
                    infoRow("Prefix", bottle.url.lastPathComponent, help: bottle.url.path)
                    // Names the real blast radius (F1/F2). A bottle's own settings and actions can
                    // read as isolated when three others share this exact directory. Neutral, not
                    // orange: on this screen it is a fact about the bottle, not a warning — the
                    // warnings live beside the settings they affect, in Configuration.
                    if !model.otherBottlesSharingPrefix(with: bottle).isEmpty {
                        let names = model.otherBottlesSharingPrefix(with: bottle)
                            .map(\.name).joined(separator: ", ")
                        StatusNote("Shared with \(names)", systemImage: "person.2", tint: .secondary)
                    }
                    HStack {
                        // Glass, like every secondary control. Only Play and Launch Steam keep the
                        // active theme's own treatment, so the eye still lands on them first.
                        Button("Open C: Drive") { model.openCDrive(bottle) }.glassButton()
                        // Same name as the context menu and Bottle menu item for the same action.
                        Button("Apply Settings to Prefix") { model.applySettings(bottle) }.glassButton()
                        // (Wine Config lived here too — a duplicate of Programs ▸ Wine Configuration.)
                    }
                    .padding(.top, 4)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 20pt — the content margin Apple's apps use from the sidebar and the window edge
        // (docs/APPLE-GEOMETRY.md). Was 16.
        .padding(20)
    }

    /// Quit Steam's one entry point, shared by the button and Bottle ▸ Quit Steam…: refuse with a
    /// reason if quitting would kill something that matters, otherwise ask to confirm.
    private func requestQuit() {
        Task {
            if let reason = await model.quitSteamBlockReason(for: bottle) {
                quitBlockReason = reason
                showQuitBlocked = true
            } else {
                confirmQuit = true
            }
        }
    }

    @ViewBuilder
    private func steamLabel(_ launching: Bool) -> some View {
        if launching {
            Label("Opening…", systemImage: "hourglass")
        } else {
            Label("Launch Steam", systemImage: "arrow.up.forward.app.fill")
        }
    }

    /// Install Graphics Driver, from the More menu: runs it and reports how many games it patched.
    private func installGraphicsDriver() {
        installingGFX = true
        Task {
            let n = await model.installGraphicsDriver(in: bottle)
            gfxResult = n == 0
                ? "No games found in this bottle yet — install one in Steam, then run this again."
                : "Patched graphics driver installed for \(n) game\(n == 1 ? "" : "s")."
            installingGFX = false
        }
    }

    /// One label/value line. `help` is a hover tooltip for a value shortened to fit.
    private func infoRow(_ label: String, _ value: String, help: String? = nil) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(help ?? value)
            Spacer()
        }
    }
}
