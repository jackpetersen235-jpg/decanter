import SwiftUI

/// First-run experience. Goal: a person who has never heard of Wine can press one button
/// and end up with Steam running. Every step self-checks, self-installs, and explains itself
/// in plain language — no jargon, no file paths, no terminal.
struct SetupWizard: View {
    /// Non-nil when shown on demand (menu) rather than as the first-run screen.
    var dismiss: (() -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @StateObject private var installer = WineInstaller()
    @State private var running = false
    @State private var bottleName = "Games"
    @State private var failureMessage: String? = nil
    /// Setup finished, but something optional did not — currently the msync overlay. Distinct from
    /// `failureMessage`: the run succeeded, the result is just worse than it should be.
    @State private var warningMessage: String? = nil
    @State private var steamInstalling = false

    private enum Step: Int, CaseIterable {
        case rosetta, engine, bottle, steam

        var title: String {
            switch self {
            case .rosetta: return "Apple's translation layer"
            case .engine:  return "The Windows engine"
            case .bottle:  return "A place for your games"
            case .steam:   return "Steam"
            }
        }
        var blurb: String {
            switch self {
            case .rosetta: return "Lets your Mac understand software written for Intel chips. Made by Apple, already on most Macs."
            case .engine:  return "Translates Windows games so they run on macOS. About 500 MB in two parts — Decanter downloads and sets it up for you, including the fast-sync build that avoids stutter."
            case .bottle:  return "A private Windows environment for your games. Nothing leaks into the rest of your Mac."
            case .steam:   return "The Steam app itself, installed inside that environment."
            }
        }
        var icon: String {
            switch self {
            case .rosetta: return "cpu"
            case .engine:  return "gearshape.2"
            case .bottle:  return "cube.box"
            case .steam:   return "gamecontroller"
            }
        }
    }

    // MARK: State of each step

    private func isDone(_ step: Step) -> Bool {
        switch step {
        case .rosetta: return model.isRosettaInstalled
        // NOT `defaultInstallation != nil` / `!bottles.isEmpty`. Any wine satisfied those, so on a
        // Mac with Whisky wine-7.7 every step self-reported DONE, `allDone` became true, and the
        // wizard rendered "Start using Decanter" INSTEAD of the setup button — leaving the user
        // with no way to run setup at all. See AppModel.hasUsableEngine.
        case .engine:  return model.hasUsableEngine
        case .bottle:  return model.bottles.contains { model.installation(for: $0)?.isSteamCapable == true }
        case .steam:   return model.bottles.contains {
            $0.isSteamInstalled && model.installation(for: $0)?.isSteamCapable == true
        }
        }
    }

    private var firstUnfinished: Step? { Step.allCases.first { !isDone($0) } }
    private var allDone: Bool { firstUnfinished == nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                VStack(spacing: 10) {
                    ForEach(Step.allCases, id: \.rawValue) { row($0) }
                }
                .frame(maxWidth: 620)
                actionArea
                    .frame(maxWidth: 620)
            }
            .padding(30)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "wineglass.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)      // decorative
            Text("Let's get you playing").font(.largeTitle.bold())
            Text(allDone
                 ? "Everything's ready."
                 : "Decanter needs four things. It can set up all of them for you — just press the button.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func row(_ step: Step) -> some View {
        let done = isDone(step)
        let active = running && firstUnfinished == step
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.15)
                               : (active ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
                    .frame(width: 34, height: 34)
                if done {
                    Image(systemName: "checkmark").foregroundStyle(.green).font(.system(size: 15, weight: .bold))
                } else if active, step == .engine, case .downloading = installer.phase {
                    // The download bar below is this step's indicator; a spinner here as well
                    // would stack two for one task. The tinted badge still marks the active step.
                    Image(systemName: step.icon).foregroundStyle(Color.accentColor)
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: step.icon).foregroundStyle(.secondary)
                }
            }
            // The badge shows the step's state only visually (green tick, spinner, icon). VoiceOver
            // gets it as the row's value instead, and the badge's glyph names are hidden.
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.body.weight(.semibold))
                Text(step.blurb).font(.caption).foregroundStyle(.secondary)
                if step == .engine, case .downloading(let p) = installer.phase, active {
                    ProgressView(value: p) {
                        Text("Downloading… \(Int(p * 100))%").font(.caption2)
                    }
                    .padding(.top, 2)
                }
                if step == .engine, active, installer.phase == .extracting {
                    Text("Unpacking…").font(.caption2).foregroundStyle(.secondary)
                }
                if step == .steam, active, steamInstalling {
                    Text("Downloading and installing Steam…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : (active ? "In progress" : "Not started"))
    }

    @ViewBuilder
    private var actionArea: some View {
        if allDone {
            VStack(spacing: 10) {
                Button {
                    if let b = model.bottles.first(where: {
                        $0.isSteamInstalled && model.installation(for: $0)?.isSteamCapable == true
                    }) ?? model.bottles.first(where: { $0.isSteamInstalled }) {
                        model.selectedBottleID = b.id
                    }
                    dismiss?()
                } label: {
                    Label("Start using Decanter", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        } else {
            VStack(spacing: 10) {
                Button {
                    Task { await runAll() }
                } label: {
                    Label(running ? "Setting things up…" : "Set everything up for me",
                          systemImage: running ? "hourglass" : "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(running || !SystemChecks.isAppleSilicon)

                // Said before the button is pressed, not after a Rosetta step that can't succeed.
                if !SystemChecks.isAppleSilicon {
                    StatusNote.failure(FailureCode.unsupportedMac.tag(SystemChecks.unsupportedMacMessage))
                }

                // The two engine parts measure 332 MB + 166 MB; this used to say 317, the first
                // part alone, while the row above (and the READ ME) said 480.
                Text(running
                     ? "This can take several minutes. You can leave it running."
                     : "Downloads about 500 MB. Nothing else on your Mac is touched.")
                    .font(.caption).foregroundStyle(.secondary)

                // Opened from View ▸ Setup Assistant… with a step unfinished, the wizard REPLACES
                // the main window, and its only exit was finishing setup — a trap (HIG Modality:
                // always give people an obvious way to dismiss). `dismiss` is nil on first run,
                // where there's nothing behind the wizard yet, and while setup runs, so this only
                // appears when leaving is safe.
                if let dismiss, !running {
                    Button("Not Now", action: dismiss)
                        .keyboardShortcut(.cancelAction)
                }

                if let failureMessage {
                    StatusNote.failure(failureMessage)
                        .padding(.top, 2)
                }
                // Setup SUCCEEDED but produced a worse result than intended — currently an engine
                // without the msync overlay. Shown separately from a failure because the run did
                // finish; staying silent is what let someone end up on the frame-spike engine
                // believing everything was fine.
                // Was yellow text — 1.51:1 on the light background, nearly invisible. Now an orange
                // warning triangle, told apart from the red failure octagon by shape as well.
                if let warningMessage {
                    StatusNote(warningMessage)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: The automation

    private func runAll() async {
        running = true
        model.isSettingUp = true            // keep the wizard mounted through every step
        failureMessage = nil
        defer { running = false; model.isSettingUp = false }

        // 1. Rosetta — awaited to completion (no fixed-time guess). Stop clearly if it fails.
        if !model.isRosettaInstalled {
            let ok = await model.ensureRosetta()
            if !ok {
                failureMessage = FailureCode.rosetta.tag(
                    "Couldn't install Apple's Rosetta translation layer. "
                    + "Open Terminal and run:  softwareupdate --install-rosetta --agree-to-license  "
                    + "then press the button again.")
                return
            }
        }

        // 2. Engine — download + unpack + verify (progress shown in the row).
        if !model.hasUsableEngine {
            await installer.install()
            model.adoptDecanterEngine()          // rescan alone leaves a stale saved default
            if case .failed(let message) = installer.phase {
                failureMessage = FailureCode.engineInstall.tag("Couldn't set up the Windows engine: \(message)")
                return
            }
        }
        // Non-fatal, but SAY IT: the engine can install without the msync overlay, in which case
        // setup "succeeds" and the user quietly has the frame-spike engine.
        if let w = installer.warning { warningMessage = w }

        guard model.hasUsableEngine else {
            failureMessage = FailureCode.engineMissing.tag(
                "No Windows engine is available. Please check your internet connection and try again.")
            return
        }

        // 3. Bottle — created quietly (no scary wineboot log for a first-timer).
        if !isDone(.bottle) {
            if await model.createBottleForSetup(name: bottleName) == nil {
                failureMessage = FailureCode.bottleCreate.tag("Couldn't create the game environment. Please try again.")
                return
            }
        }

        // 4. Steam — installed quietly; progress shown in the row.
        if let bottle = model.bottles.first(where: { model.installation(for: $0)?.isSteamCapable == true }),
           !bottle.isSteamInstalled {
            steamInstalling = true
            // CHECK IT. Steps 1–3 all report their failures; this one discarded its result, so a
            // failed Steam install ended the wizard with the step simply unchecked and no reason
            // given anywhere — the user is left looking at a tick that never appeared.
            let steamOK = await model.performSteamInstall(in: bottle, console: nil)
            steamInstalling = false
            if !steamOK {
                failureMessage = FailureCode.steamInstall.tag(
                    "Couldn't install Steam into the game environment. "
                    + "Check your internet connection and press the button again — "
                    + "anything already finished is skipped.")
                return
            }
        }

        // 5. Patched graphics driver for anything already installed. Harmless when the library is
        // empty (a fresh Steam install has no games yet) - the Configuration tab has a button to
        // run it again after the user installs one.
        if let bottle = model.bottles.first(where: { model.installation(for: $0)?.isSteamCapable == true }) {
            await model.installGraphicsDriver(in: bottle)
        }
    }
}
