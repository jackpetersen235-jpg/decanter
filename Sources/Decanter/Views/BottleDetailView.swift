import SwiftUI

struct BottleDetailView: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle

    private enum Tab: String, CaseIterable, Identifiable {
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
    @State private var buildingApp = false
    @State private var appResult: String?
    @Environment(\.appTheme) private var appTheme

    /// Header type is coloured for the Aero panel it sits on. In Liquid Glass there is no panel and
    /// the system chrome is dark, so the ink must not be forced there.
    private var isAero: Bool { appTheme == .frutigerAero }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            ScrollView {
                switch tab {
                case .overview:      overview
                case .configuration: ConfigurationView(bottle: model.binding(for: bottle))
                case .programs:      ProgramsView(bottle: bottle)
                }
            }
        }
        // No navigation title: the raised header panel directly below already names the bottle, and
        // the toolbar strip repeated it in unthemed white chrome across the top of the window.
        .navigationTitle("")
        // Confirmed, not immediate: this is `wineserver -k` on the whole prefix, so a game that is
        // still running dies with it and unsaved progress goes with it.
        .confirmationDialog("Quit Steam in “\(bottle.name)”?",
                            isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Quit Steam", role: .destructive) {
                quitting = true
                quitResult = nil
                Task {
                    let ok = await model.quitSteam(in: bottle)
                    quitResult = ok
                        ? "Steam has been shut down."
                        : "Steam did not shut down — try again, or restart your Mac."
                    quitting = false
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This also closes any game running in this bottle. Unsaved progress will be lost.")
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "cube.box.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                // Dark ink on the light chrome panel, with the 1pt white shadow below — the
                // period treatment, and the pairing that measures 14.76:1. White type was tried
                // first and cannot work here: the gloss lightens the top of the panel far too much
                // for it to hold.
                Text(bottle.name).font(.title2.bold())
                    .foregroundStyle(isAero ? AnyShapeStyle(AeroTokens.ink)
                                            : AnyShapeStyle(.primary))
                    .aeroTextShadow(isAero)
                Text(model.installation(for: bottle)?.name ?? "No Wine build")
                    .font(.caption)
                    .foregroundStyle(isAero ? AnyShapeStyle(AeroTokens.inkSecondary)
                                            : AnyShapeStyle(.secondary))
            }
            Spacer()
            if !bottle.isInitialized {
                ProgressView().controlSize(.small)
                Text("Setting up…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        // A raised rounded panel rather than a full-width band of colour. The band met the content
        // below in a straight square edge, which read as a seam next to a UI that is rounded and
        // has depth everywhere else. Inset so the panel visibly floats instead of butting into the
        // window edges. No-op in Liquid Glass.
        .aeroPanel(cornerRadius: 14)
        .padding(.horizontal, 12)
        .padding(.top, 8)
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
                        if bottle.isSteamBootstrapped {
                            Text("Steam is installed in this bottle.").foregroundStyle(.secondary)
                        } else {
                            Text("Steam is installed but hasn't finished setting itself up yet.")
                                .foregroundStyle(.secondary)
                            Text("The first launch downloads the Steam client (a few hundred MB). "
                                 + "Leave it running until the login window appears — it can take "
                                 + "several minutes and may look stuck.")
                                .font(.caption).foregroundStyle(.secondary)
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
                                    model.launchGameApp(in: bottle)
                                } label: {
                                    Label(buildingApp ? "Building…" : "Play",
                                          systemImage: "gamecontroller.fill")
                                }
                                // Lime in Aero — the theme's signature accent — and its shadow
                                // takes that hue rather than neutral gray. Liquid glass ignores
                                // the accent and refracts instead.
                                .themedButton(prominent: true, accent: AeroTokens.lime)
                                .disabled(buildingApp)
                            }

                            // Two spellings of the same button because SwiftUI's ButtonStyle is not
                            // type-erasable without a wrapper, and one small duplication reads
                            // better here than a custom AnyButtonStyle would.
                            if game == nil {
                                Button { model.launchSteam(in: bottle) } label: { steamLabel(launching) }
                                    .themedButton(prominent: true)
                                    .disabled(launching)
                            } else {
                                Button { model.launchSteam(in: bottle) } label: { steamLabel(launching) }
                                    .themedButton()
                                    .disabled(launching)
                            }

                            // Decanter starts Steam; it must also be able to stop it. Without this
                            // a `-silent` Steam sits in the tray with no window and survives every
                            // attempt to quit it from Steam's own UI (closing the window just
                            // re-hides it), with no control anywhere in the app to end it.
                            Button(quitting ? "Quitting…" : "Quit Steam") { confirmQuit = true }
                                .disabled(quitting)

                            Button("Reinstall") { model.installSteam(in: bottle) }

                            // Re-runnable on purpose: the wizard installs this after Steam, but a
                            // fresh library has no games yet, so it must be reachable afterwards.
                            Button(installingGFX ? "Installing…" : "Install Graphics Driver") {
                                installingGFX = true
                                Task {
                                    let n = await model.installGraphicsDriver(in: bottle)
                                    gfxResult = n == 0
                                        ? "No games found in this bottle yet — install one in Steam, then run this again."
                                        : "Patched graphics driver installed for \(n) game\(n == 1 ? "" : "s")."
                                    installingGFX = false
                                }
                            }
                            .disabled(installingGFX)
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
                            HStack(spacing: 8) {
                                Button(buildingApp ? "Rebuilding…" : "Rebuild Launcher") {
                                    buildingApp = true
                                    appResult = nil
                                    Task {
                                        switch await model.buildGameApp(for: bottle) {
                                        case .success(let url):
                                            appResult = "Built \(url.lastPathComponent) in ~/Applications."
                                        case .failure(let e):
                                            appResult = e.localizedDescription
                                        }
                                        buildingApp = false
                                    }
                                }
                                .disabled(buildingApp)
                                // Shown unconditionally, and builds first if the bundle is not
                                // there yet. Gating on `hasGameApp` looked right but was a
                                // filesystem check with nothing observable behind it: after
                                // creating a bottle the launcher is written asynchronously, and
                                // SwiftUI had no reason to re-render when it appeared — so the
                                // button stayed hidden for a launcher that existed.
                                Button("Show in Finder") {
                                    Task {
                                        if !model.hasGameApp(for: bottle) {
                                            _ = await model.buildGameApp(for: bottle)
                                        }
                                        NSWorkspace.shared.activateFileViewerSelecting(
                                            [GameAppBuilder.destination(for: bottle)])
                                    }
                                }
                            }
                            // Name what Play will actually start. The resolver picks the biggest
                            // executable, and on UE titles that is a deep Shipping.exe rather than
                            // the obvious top-level one — worth showing so a wrong pick is visible
                            // rather than mysterious.
                            Text("Play starts \(game.executable.lastPathComponent)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let appResult {
                            Text(appResult).font(.caption).foregroundStyle(.secondary)
                        }
                        if launching {
                            Text("Steam is opening — this can take a few seconds the first time.")
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
                    infoRow("Prefix", bottle.url.path, mono: true)
                    HStack {
                        Button("Open C: Drive") { model.openCDrive(bottle) }
                        Button("Apply Settings") { model.applySettings(bottle) }
                        Button("Wine Config") { model.runTool(.winecfg, in: bottle) }
                    }
                    .padding(.top, 4)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func steamLabel(_ launching: Bool) -> some View {
        if launching {
            Label("Opening…", systemImage: "hourglass")
        } else {
            Label("Launch Steam", systemImage: "arrow.up.forward.app.fill")
        }
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .body)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
