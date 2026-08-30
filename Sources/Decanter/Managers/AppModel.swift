import Foundation
import SwiftUI
import AppKit

/// Central observable state + all user-facing actions. Views read from and call into this.
@MainActor
final class AppModel: ObservableObject {

    // MARK: Published state
    @Published var bottles: [Bottle] = []

    /// What the last `rescanInstallations()` found. Set by the model itself so that no button
    /// which triggers a rescan can silently do nothing visible.
    @Published var lastRescanMessage: String?

    @Published var installations: [WineInstallation] = []
    @Published var selectedBottleID: Bottle.ID?
    @Published var activeConsole: TaskConsole?
    @Published var isRosettaInstalled: Bool = SystemChecks.isRosettaInstalled

    /// Bottles whose game/Steam is starting up. Drives the button state and prevents a second
    /// click from spawning a duplicate before the first launch has fully come up.
    @Published private(set) var launchingBottleIDs: Set<Bottle.ID> = []

    /// True while the first-run setup wizard is actively running its steps. Keeps the wizard
    /// mounted (see ContentView) so creating the first bottle — which makes `bottles` non-empty —
    /// doesn't yank the wizard out from under the automation mid-way.
    @Published var isSettingUp = false

    /// User-added Wine `bin` directories, persisted across launches.
    @Published var extraWineDirectories: [URL] = [] {
        didSet { persistExtraDirectories() }
    }

    /// Identifier of the preferred Wine build for new bottles.
    @Published var defaultInstallationID: String? {
        didSet { UserDefaults.standard.set(defaultInstallationID, forKey: Keys.defaultInstallation) }
    }

    private enum Keys {
        static let defaultInstallation = "defaultInstallationID"
        static let extraDirectories = "extraWineDirectories"
    }

    // MARK: Lifecycle

    init() {
        Paths.ensureDirectories()
        loadExtraDirectories()
        defaultInstallationID = UserDefaults.standard.string(forKey: Keys.defaultInstallation)
        loadBottles()
        rescanInstallations()

        // Allow a headless one-shot import: `open Decanter.app --args --import-crossover`.
        if CommandLine.arguments.contains("--import-crossover") {
            importCrossOverBottles()
        }
        // Headless engine install (used for testing the first-run path, and handy for support):
        //   Decanter.app/Contents/MacOS/Decanter --install-engine
        if CommandLine.arguments.contains("--install-engine") {
            Task { await installEngine() }
        }
        // Headless full guided setup — the same steps the wizard runs, for end-to-end testing:
        //   Decanter.app/Contents/MacOS/Decanter --run-setup
        if CommandLine.arguments.contains("--run-setup") {
            Task { await runGuidedSetup() }
        }
        // Headless engine-toggle check, so the offline/online switch can be verified without the
        // GUI:  Decanter.app/Contents/MacOS/Decanter --engine offline|online
        // Headless reset, to verify the restore path without the GUI:
        //   Decanter.app/Contents/MacOS/Decanter --reset-online
        // Headless bottle creation, for testing that a FAILED create cleans up after itself:
        //   Decanter.app/Contents/MacOS/Decanter --create-bottle "name"
        if let i = CommandLine.arguments.firstIndex(of: "--create-bottle"),
           i + 1 < CommandLine.arguments.count {
            let wanted = CommandLine.arguments[i + 1]
            Task {
                let before = bottles.count
                let id = await createBottleForSetup(name: wanted)
                FileHandle.standardError.write("""
                    created: \(id != nil ? "yes" : "NO")
                    bottles: \(before) -> \(bottles.count)\(id == nil && bottles.count == before ? "  (cleaned up correctly)" : "")

                    """.data(using: .utf8)!)
                exit(id == nil ? 1 : 0)
            }
        }
        // Create or restore a non-default engine:  --reset-engine legacy | online
        if let i = CommandLine.arguments.firstIndex(of: "--reset-engine"),
           i + 1 < CommandLine.arguments.count,
           let profile = EngineProfile(rawValue: CommandLine.arguments[i + 1]) {
            Task {
                let console = TaskConsole(title: "engine")
                let ok = await resetEngine(for: profile, console: console)
                FileHandle.standardError.write(
                    "\(profile.rawValue) engine: \(ok ? "ready" : "FAILED")\n".data(using: .utf8)!)
                exit(ok ? 0 : 1)
            }
        }
        // Apply each bottle's settings to its prefix (registry writes) without the GUI.
        if CommandLine.arguments.contains("--apply-settings") {
            Task {
                let console = TaskConsole(title: "apply")
                for bottle in bottles {
                    await applyRegistry(bottleID: bottle.id, console: console, finish: false)
                }
                FileHandle.standardError.write("applied settings to \(bottles.count) bottle(s)\n".data(using: .utf8)!)
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--reset-online") {
            Task {
                let console = TaskConsole(title: "reset")
                let ok = await resetOnlineEngine(console: console)
                FileHandle.standardError.write("reset online engine: \(ok ? "OK" : "FAILED")\n".data(using: .utf8)!)
                exit(ok ? 0 : 1)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--engine"),
           i + 1 < CommandLine.arguments.count,
           let profile = EngineProfile(rawValue: CommandLine.arguments[i + 1]) {
            Task {
                var out = ""
                for bottle in bottles {
                    let err = await setEngineProfile(profile, for: bottle)
                    let now = bottles.first { $0.id == bottle.id }
                    let engine = installation(for: now ?? bottle)?.binDirectory
                        .deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().lastPathComponent ?? "?"
                    out += "  \(bottle.name.prefix(34)) -> \(now?.settings.engineProfile?.rawValue ?? "offline")"
                        + "  engine=\(engine)\(err.map { "  ERROR: \($0)" } ?? "")\n"
                }
                FileHandle.standardError.write(out.data(using: .utf8)!)
                exit(0)
            }
        }
        // Headless per-game graphics install, so the payload path can be verified without the GUI:
        //   Decanter.app/Contents/MacOS/Decanter --install-gfx
        if CommandLine.arguments.contains("--install-gfx") {
            Task {
                for bottle in bottles {
                    let games = detectedSteamGames(in: bottle)
                    FileHandle.standardError.write(
                        "bottle \(bottle.name): \(games.count) game(s) detected\n".data(using: .utf8)!)
                    for g in games {
                        FileHandle.standardError.write(
                            "  \(g.folder.lastPathComponent) -> \(g.exe)\n".data(using: .utf8)!)
                    }
                    let n = await installGraphicsDriver(in: bottle)
                    FileHandle.standardError.write("  installed into \(n)\n".data(using: .utf8)!)
                }
                exit(0)
            }
        }
        // Headless exercise of the exact SAME entry point the sidebar calls on a real click, so
        // warm-start Steam (userSelectedBottle) can be verified end-to-end without driving the GUI
        // and without handing anyone a manual step to run:
        //   Decanter.app/Contents/MacOS/Decanter --warm-start-test "<bottle name>"
        if let i = CommandLine.arguments.firstIndex(of: "--warm-start-test"),
           i + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments[i + 1]
            Task {
                guard let bottle = bottles.first(where: { $0.name == name }) else {
                    FileHandle.standardError.write("no such bottle: \(name)\n".data(using: .utf8)!)
                    exit(1)
                }
                let prefixKey = PrefixSharing.key(for: bottle.url)
                userSelectedBottle(bottle.id)
                // Poll rather than sleep a fixed guess: the debounce is 400ms, the logon wait can
                // run up to 150s. Bail out once neither the warming set nor the task map still
                // reference this prefix — i.e. the warm-start (if any) has actually finished.
                for _ in 0..<80 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !warmingPrefixKeys.contains(prefixKey) && warmStartTasks[prefixKey] == nil {
                        break
                    }
                }
                let steamRunning = await isSteamRunning()
                let report = "warmed=\(warmStartedPrefixKeys.contains(prefixKey)) "
                    + "steamRunning=\(steamRunning)\n"
                FileHandle.standardError.write(report.data(using: .utf8)!)
                exit(0)
            }
        }
        // The `--trace-steam-launch` diagnostic used for the 2026-08-26 cold-login-stall
        // investigation (WINEDEBUG=+winsock, then +ntdll, against the real Steam-Wine11 prefix)
        // was intentionally temporary and has been removed. Findings are recorded in CLAUDE.md.
        // F5 (bug-sweep): list what's reclaimable in Bottles/ and ShaderCache/. LIST ONLY —
        // prints candidates with sizes and a reason each; deletes nothing. The user runs any `rm`
        // themselves. Two hard exclusions, both because "unreferenced by bottles.json" is not a
        // safe definition of orphan on this machine:
        //   - `ShaderCache/Sekiro` and `/ASBR` are live via hand-made launchers
        //     (~/Applications/Sekiro.app, /JJBA All-Star Battle.app) that set
        //     DXMT_SHADER_CACHE_PATH directly and are structurally invisible to Decanter's own
        //     model — this is why the launcher scan below exists at all.
        //   - `Backups/` (~17 GB on this machine) holds the rollback material
        //     RESTORE-*.sh depends on (see F21) — reclaiming it is how that script's failure mode
        //     becomes self-inflicted. Never scanned, not merely filtered: it's not in scope for
        //     this flag to look at, the same way OrphanReclaim never walks the filesystem itself.
        //   Decanter.app/Contents/MacOS/Decanter --reclaim
        if CommandLine.arguments.contains("--reclaim") {
            let out = reclaimReport()
            FileHandle.standardError.write(out.data(using: .utf8)!)
            exit(0)
        }
        // Full health check: is the RIGHT engine installed, and is everything loaded?
        //
        // Deeper than `doctor.sh` can go from the shell, because it uses the app's own probes —
        // notably `supportsFastSync`, which reads the ntdll for `WINEMSYNC`/`WINEESYNC` rather than
        // trusting a version number. A wine 10 without msync looks identical from outside and is
        // the difference between smooth play and frame spikes.
        //   Decanter.app/Contents/MacOS/Decanter --verify
        if CommandLine.arguments.contains("--verify") {
          Task {
            var out = "\n=== Decanter verification ===\n\n"
            var problems: [String] = []
            func line(_ ok: Bool, _ label: String, _ detail: String = "") {
                out += "  \(ok ? "OK  " : "FAIL") \(label)\(detail.isEmpty ? "" : "  —  \(detail)")\n"
                if !ok { problems.append(label) }
            }

            out += "SYSTEM\n"
            line(isRosettaInstalled, "Rosetta 2 installed",
                 isRosettaInstalled ? "" : "run: softwareupdate --install-rosetta")

            out += "\nENGINE\n"
            if let engine = defaultInstallation {
                // Ask the engine directly rather than reading `engine.version`. That field is
                // filled in ASYNCHRONOUSLY after discovery, so a synchronous check sees nil and
                // reports a perfectly good engine as incomplete — which this hook did on its first
                // run. A health check that invents problems is worse than no health check.
                let reportedVersion = await Wine.version(of: engine)
                line(true, "Engine found", "\(engine.name) \(reportedVersion ?? "version unknown")")
                line(reportedVersion != nil, "Engine version readable",
                     reportedVersion ?? "wine --version returned nothing; the engine may be incomplete")
                line(engine.isSteamCapable, "New enough for Steam",
                     engine.isSteamCapable ? "" : "too old — Steam will fail to start")
                // The check that matters most and is invisible from outside.
                line(engine.supportsFastSync, "Fast sync (msync) present",
                     engine.supportsFastSync
                        ? "this is the tuned build"
                        : "WRONG BUILD — plays with frame spikes; reinstall via Setup Assistant")
                line(FileManager.default.isExecutableFile(atPath: engine.loader.path),
                     "wine binary is executable", engine.loader.path)
            } else {
                line(false, "Engine found", "none — run the Setup Assistant")
            }
            line(Paths.bundledDXMT != nil, "DXMT graphics payload bundled",
                 Paths.bundledDXMT == nil ? "games will fall back to the slow renderer" : "")

            out += "\nBOTTLES (\(bottles.count))\n"
            if bottles.isEmpty { line(false, "At least one bottle", "none yet — press the setup button") }
            for bottle in bottles {
                out += "\n  [\(bottle.name)]\n"
                line(bottle.isInitialized, "  prefix initialised")
                line(bottle.isSteamInstalled, "  Steam installed")
                line(bottle.isSteamBootstrapped, "  Steam client downloaded",
                     bottle.isSteamBootstrapped ? "" : "launch Steam once and WAIT — it downloads itself")
                if let game = resolvedGame(for: bottle) {
                    line(FileManager.default.fileExists(atPath: game.executable.path),
                         "  game executable present", game.executable.lastPathComponent)
                } else {
                    out += "       --  no game (this is a launcher bottle)\n"
                }
            }

            out += problems.isEmpty
                ? "\nEverything checks out.\n"
                : "\n\(problems.count) problem(s): \(problems.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))\n"
            FileHandle.standardError.write(out.data(using: .utf8)!)
            exit(problems.isEmpty ? 0 : 1)
          }
        }
        // What the New Bottle picker will offer.
        //   Decanter.app/Contents/MacOS/Decanter --scan-games
        if CommandLine.arguments.contains("--scan-games") {
            let started = Date()
            let games = AppModel.scanForGames(in: scannablePrefixes)
            var out = "\nfound \(games.count) game(s) in \(String(format: "%.1f", -started.timeIntervalSinceNow))s\n"
            for g in games {
                out += "  \(g.name)\n"
                out += "      exe   \(g.executable.lastPathComponent)  (\(g.displaySize))\n"
                out += "      appid \(g.appID ?? "-")   prefix \(g.prefix.lastPathComponent)\n"
            }
            FileHandle.standardError.write(out.data(using: .utf8)!)
            exit(0)
        }
        // Install Steam into ONE named bottle. `--run-setup` only ever targets the setup bottle,
        // so there was no way to provision a second one without the GUI.
        //   Decanter.app/Contents/MacOS/Decanter --install-steam "Half Sword"
        if let i = CommandLine.arguments.firstIndex(of: "--install-steam"),
           i + 1 < CommandLine.arguments.count {
            let wanted = CommandLine.arguments[i + 1]
            Task {
                guard let bottle = bottles.first(where: { $0.name == wanted }) else {
                    FileHandle.standardError.write(
                        "no bottle named \"\(wanted)\"\n".data(using: .utf8)!)
                    exit(1)
                }
                let ok = await performSteamInstall(in: bottle, console: nil)
                let now = bottles.first { $0.id == bottle.id } ?? bottle
                FileHandle.standardError.write("""
                    install: \(ok ? "OK" : "FAILED")
                    steam.exe present: \(now.isSteamInstalled)
                    bootstrapped:      \(now.isSteamBootstrapped)

                    """.data(using: .utf8)!)
                exit(ok ? 0 : 1)
            }
        }
        // Escape hatch for a Steam that will not stay quit, and the headless test for quitSteam.
        //   Decanter.app/Contents/MacOS/Decanter --quit-steam
        if CommandLine.arguments.contains("--quit-steam") {
            Task {
                var any = false
                for bottle in bottles where bottle.isSteamInstalled {
                    let ok = await quitSteam(in: bottle)
                    FileHandle.standardError.write(
                        "  \(bottle.name.prefix(40)): \(ok ? "stopped" : "STILL RUNNING")\n"
                            .data(using: .utf8)!)
                    any = true
                }
                if !any { FileHandle.standardError.write("no Steam bottles\n".data(using: .utf8)!) }
                exit(0)
            }
        }
        // Support hook. "Failed to load steamui.dll" has two completely different causes — an
        // engine too old to run Steam, and a Steam that never finished downloading itself — and
        // the error text is identical for both. This prints which one a machine is actually in,
        // so a remote user can paste one block instead of describing symptoms.
        //   Decanter.app/Contents/MacOS/Decanter --diagnose
        if CommandLine.arguments.contains("--diagnose") {
            Task {
            var out = "\n=== Decanter diagnosis ===\n"
            out += "engine usable: \(hasUsableEngine)\n"
            out += "steam running: \(await isSteamRunning())\n"
            out += "game running (any bottle): \(await isAnyGameRunning())\n"
            for bottle in bottles {
                let inst = installation(for: bottle)
                out += "\nbottle: \(bottle.name)\n"
                out += "  engine:       \(inst?.name ?? "NONE") \(inst?.version ?? "?")\n"
                out += "  steam-capable engine: \(inst?.isSteamCapable.description ?? "n/a")\n"
                out += "  initialized:  \(bottle.isInitialized)\n"
                out += "  steam.exe:    \(bottle.isSteamInstalled)\n"
                out += "  bootstrapped: \(bottle.isSteamBootstrapped)\n"
                if bottle.isSteamInstalled && !bottle.isSteamBootstrapped {
                    out += "  >> Steam has not downloaded its client yet. Launch Steam and LEAVE IT\n"
                    out += "     RUNNING until the login window appears (several minutes).\n"
                }
                if let inst, !inst.isSteamCapable {
                    out += "  >> This engine cannot run Steam. Run the Setup Assistant.\n"
                }
            }
            FileHandle.standardError.write(out.data(using: .utf8)!)
            exit(0)
            }
        }
    }

    /// The complete first-run automation, factored out of the wizard view so it (a) survives any
    /// view lifecycle and (b) is testable headlessly via `--run-setup`. Steps self-skip if done.
    func runGuidedSetup() async {
        isSettingUp = true
        defer { isSettingUp = false }

        guard await ensureRosetta() else { return }              // 1. Rosetta

        if !hasUsableEngine {                                    // 2. Engine
            await installEngine()
            adoptDecanterEngine()
        }
        guard hasUsableEngine else { return }

        // A bottle built on an engine that can't run Steam does not count as done — see
        // `hasUsableEngine`. Such a user needs a NEW bottle, not a skipped step.
        if !bottles.contains(where: { installation(for: $0)?.isSteamCapable == true }) {  // 3. Bottle
            _ = await createBottleForSetup(name: "Games")
        }

        if let bottle = bottles.first(where: { installation(for: $0)?.isSteamCapable == true }),
           !bottle.isSteamInstalled {                            // 4. Steam
            _ = await performSteamInstall(in: bottle, console: nil)
        }
    }

    // MARK: Derived

    /// The Wine build to use when creating new bottles.
    var defaultInstallation: WineInstallation? {
        if let id = defaultInstallationID, let match = installations.first(where: { $0.id == id }) {
            return match
        }
        return installations.first
    }

    /// Decanter's own downloaded engine, if it is actually on disk.
    var decanterEngine: WineInstallation? {
        installations.first {
            $0.binDirectory.standardizedFileURL == Paths.wineEngineBin.standardizedFileURL
        }
    }

    /// Does the build that new bottles would use actually run modern Steam?
    ///
    /// THE SETUP WIZARD MUST GATE ON THIS, NOT ON `defaultInstallation != nil`. Discovery finds
    /// ANY wine, including Whisky's wine-7.7, which cannot load modern Steam ("Failed to load
    /// steamui.dll"). Gating on non-nil made every step of the wizard report DONE on such a Mac:
    /// engine "done" because some wine existed, bottle "done" because one existed, Steam "done"
    /// because Steam was installed in it. The wizard then showed "Start using Decanter" with NO
    /// setup button at all — the user could not run setup even though nothing worked. Reported
    /// by a first-time user on 2026-07-27.
    ///
    /// Deliberately CONSERVATIVE where `WineInstallation.isSteamCapable` is lenient: an unknown
    /// version counts as unusable here. Version labels are filled in asynchronously, so treating
    /// "not known yet" as "fine" would let the same skip happen as a race. The cost of being
    /// wrong in this direction is one download of an engine that works; in the other direction
    /// it is a user with no path forward.
    var hasUsableEngine: Bool {
        guard let inst = defaultInstallation else { return false }
        if inst.binDirectory.standardizedFileURL == Paths.wineEngineBin.standardizedFileURL { return true }
        guard inst.version != nil else { return false }
        return inst.isSteamCapable
    }

    /// Rescan, then make Decanter's own engine the default if it is now present.
    ///
    /// Rescanning alone is NOT enough: `defaultInstallationID` is persisted in UserDefaults and is
    /// set to whatever was found first on the very first launch. On a Mac with Whisky that is
    /// wine-7.7, so `defaultInstallation` keeps returning 7.7 even after the good engine downloads,
    /// and the bottle we then create is built on the broken build again.
    func adoptDecanterEngine() {
        rescanInstallations()
        if let engine = decanterEngine { defaultInstallationID = engine.id }
    }

    /// The Wine build associated with a specific bottle (falls back to the default).
    ///
    /// `engineProfile` wins when set, because it is the user's explicit offline/online choice and
    /// must override the `wineBinDirectory` recorded when the bottle was first created — otherwise
    /// flipping the toggle would change the label and nothing else.
    func installation(for bottle: Bottle) -> WineInstallation? {
        if let profile = bottle.settings.engineProfile,
           let match = installations.first(where: {
               $0.binDirectory.standardizedFileURL == profile.binDirectory.standardizedFileURL
           }) {
            return match
        }
        if let dir = bottle.wineBinDirectory,
           let match = installations.first(where: { $0.binDirectory == dir }) {
            return match
        }
        return defaultInstallation
    }

    /// Switch a bottle between the offline and online engines.
    ///
    /// Safe with the game running? No — Wine holds the engine open, so this refuses while anything
    /// is up. Both engines are clones of the same Wine version, so the prefix, saves, Steam install
    /// and games are unaffected by the switch itself.
    @discardableResult
    func setEngineProfile(_ profile: EngineProfile, for bottle: Bottle) async -> String? {
        if (bottle.settings.engineProfile ?? .offline) == profile { return nil }   // nothing to do
        // Wine holds the engine tree open; swapping underneath a live process is asking for a
        // half-loaded DLL set. Refuse rather than produce a confusing crash later.
        // Both are async, so evaluate them separately — `||` takes an autoclosure and cannot await.
        let steamUp = await isSteamRunning()
        let gameUp = await isAnyGameRunning()
        if steamUp || gameUp {
            return "Quit Steam and any running game first, then switch."
        }
        // Create the engine on demand for ANY non-offline profile, not just online.
        //
        // This was hardcoded to `.online`, so `.legacy` was only ever usable on a machine where
        // someone had cloned it by hand. Everywhere else, selecting Legacy fell through to the
        // installations check and failed with "That engine isn't available" — and Rescan could not
        // help, because there was no engine on disk to find. Adding a profile must not mean
        // remembering to add a second special case here; that is how the third one would break too.
        if profile != .offline, !isEngineInstalled(profile) {
            guard await cloneEngine(for: profile) else {
                return "Could not create the \(profile.shortName) engine."
            }
            rescanInstallations()   // the clone is new on disk; discovery has not seen it yet
        }
        guard installations.contains(where: {
            $0.binDirectory.standardizedFileURL == profile.binDirectory.standardizedFileURL
        }) else {
            rescanInstallations()
            guard installations.contains(where: {
                $0.binDirectory.standardizedFileURL == profile.binDirectory.standardizedFileURL
            }) else { return "That engine isn't available." }
            return applyProfile(profile, to: bottle)
        }
        return applyProfile(profile, to: bottle)
    }

    private func applyProfile(_ profile: EngineProfile, to bottle: Bottle) -> String? {
        guard var updated = bottles.first(where: { $0.id == bottle.id }) else { return "Bottle not found." }
        updated.settings.engineProfile = profile
        // Keep wineBinDirectory in step so anything reading it directly agrees with the profile.
        updated.wineBinDirectory = profile.binDirectory
        update(updated)
        return nil
    }

    /// A two-way binding into the stored bottle so config views can edit it live.
    func binding(for bottle: Bottle) -> Binding<Bottle> {
        Binding(
            get: { self.bottles.first(where: { $0.id == bottle.id }) ?? bottle },
            set: { self.update($0) }
        )
    }

    // MARK: Installation discovery

    func rescanInstallations() {
        installations = Wine.discover(extraDirectories: extraWineDirectories)
        // Report from HERE, not from each call site. `rescanSummary()` had exactly one caller
        // (Settings), so the sidebar's Rescan and View ▸ Rescan stayed completely silent — the
        // "users conclude the button is dead" bug, fixed in one place out of three. A published
        // message means every present and future caller reports by default.
        defer { lastRescanMessage = rescanSummary() }

        // SELF-HEAL A STALE DEFAULT.
        //
        // `defaultInstallationID` is persisted in UserDefaults, so it survives the engine it names
        // being moved, renamed or deleted. The old test was `== nil`, which a stale id is not — so
        // the default kept pointing at nothing, `defaultInstallation` stayed nil, the UI kept
        // saying "No Wine build", and pressing Rescan changed nothing. That is precisely the state
        // the button exists to get you out of.
        let resolves = defaultInstallationID.map { id in
            installations.contains { $0.id == id }
        } ?? false
        if !resolves {
            // Prefer Decanter's own engine over whatever happens to be discovered first: on a Mac
            // with Whisky installed, "first" is wine-7.7, which cannot run modern Steam.
            defaultInstallationID = decanterEngine?.id ?? installations.first?.id
        }
        isRosettaInstalled = SystemChecks.isRosettaInstalled
        // Best-effort version labels in the background.
        Task { await enrichVersions() }
    }

    /// Fill in version labels in the background.
    ///
    /// Must re-find each installation by id after every `await` instead of writing back a snapshot:
    /// each `wine --version` shells out, and a `rescanInstallations()` (or an added directory) can
    /// land in that window. Assigning a stale snapshot back over `installations` silently discarded
    /// those changes.
    private func enrichVersions() async {
        for installation in installations where installation.version == nil {
            let version = await Wine.version(of: installation)
            guard let index = installations.firstIndex(where: { $0.id == installation.id }),
                  installations[index].version == nil else { continue }
            installations[index].version = version
        }
    }

    func addWineDirectory(_ url: URL) {
        // Accept any of the three things a user plausibly picks:
        //   1. the `bin` directory itself
        //   2. the `wine` binary inside it
        //   3. an engine ROOT that contains `bin/wine` (e.g. …/Wine10-msync, …/wswine.bundle)
        // Case 3 used to silently resolve to the engine's PARENT directory, which never validates.
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let dir: URL
        if exists, isDirectory.boolValue {
            if url.lastPathComponent == "bin" {
                dir = url
            } else if fm.isExecutableFile(atPath: url.appendingPathComponent("bin/wine").path) {
                dir = url.appendingPathComponent("bin")
            } else {
                dir = url            // let WineInstallation.isValid reject it
            }
        } else {
            dir = url.deletingLastPathComponent()   // a binary was picked
        }
        guard !extraWineDirectories.contains(dir) else { return }
        extraWineDirectories.append(dir)
        rescanInstallations()
    }

    // MARK: Bottle CRUD

    func createBottle(name: String) {
        guard let installation = defaultInstallation else { return }
        let (bottle, _) = makeBottle(name: name, installation: installation)
        bottles.append(bottle)
        selectedBottleID = bottle.id
        saveBottles()

        let console = openConsole(title: "Creating “\(bottle.name)”")
        console.handle = Wine.bootPrefix(bottle, using: installation, console: console) { [weak self] code in
            guard let self else { return }
            if code == 0 {
                self.markInitialized(bottle.id)
                Task { await self.applyRegistry(bottleID: bottle.id, console: console, finish: true) }
            } else {
                // Remove the failed bottle rather than leaving it in the sidebar. It was appended
                // and saved before wineboot ran, so a failure otherwise leaves an entry that looks
                // real, can never launch anything, and gives the user no clue why — the state the
                // missing-wine.inf bug produced, which had to be cleaned up by editing
                // bottles.json by hand.
                console.append("")
                console.append("Setup failed, so this bottle was removed. Nothing else was changed.")
                console.append("If this keeps happening, run Scripts/doctor.sh — a missing engine "
                               + "file is the usual cause.")
                self.deleteBottle(bottle, removeFiles: true)
                console.finish(code)
            }
        }
    }

    /// Build a bottle value with a collision-free prefix folder. Does not persist.
    private func makeBottle(name: String, installation: WineInstallation) -> (Bottle, URL) {
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safeName.isEmpty ? "Bottle-\(UUID().uuidString.prefix(6))" : diskSafe(safeName)
        let folderName = uniqueBottleFolder(from: base)
        let prefixURL = Paths.bottlesRoot.appendingPathComponent(folderName, isDirectory: true)
        var bottle = Bottle(name: safeName.isEmpty ? folderName : safeName, url: prefixURL)
        bottle.wineBinDirectory = installation.binDirectory
        // Store a sync mode the engine can actually honour, so the config UI isn't misleading.
        // (Wine.environment also strips these vars for builds without fast sync, so it's belt-and-braces.)
        bottle.settings.syncMode = installation.supportsFastSync ? .msync : .none
        return (bottle, prefixURL)
    }

    /// A prefix folder name not already taken on disk or by another bottle — so two bottles named
    /// the same never share a WINEPREFIX (which would corrupt both).
    private func uniqueBottleFolder(from base: String) -> String {
        let fm = FileManager.default
        var candidate = base
        var n = 2
        while fm.fileExists(atPath: Paths.bottlesRoot.appendingPathComponent(candidate).path)
                || bottles.contains(where: { $0.url.lastPathComponent == candidate }) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    /// Create a bottle and wait for it to finish initializing, WITHOUT popping a console sheet.
    /// Used by the setup wizard so a first-timer never sees raw wineboot logs. Returns the id
    /// once the prefix is ready, or nil on failure.
    @discardableResult
    func createBottleForSetup(name: String) async -> Bottle.ID? {
        guard let installation = defaultInstallation else { return nil }
        let (bottle, _) = makeBottle(name: name, installation: installation)
        bottles.append(bottle)
        selectedBottleID = bottle.id
        saveBottles()

        let hidden = TaskConsole(title: "setup")   // deliberately not shown as activeConsole
        let code: Int32 = await withCheckedContinuation { continuation in
            let handle = Wine.bootPrefix(bottle, using: installation, console: hidden) { code in
                continuation.resume(returning: code)
            }
            if handle == nil { continuation.resume(returning: -1) }   // never started
        }
        guard code == 0 else {
            // CLEAN UP THE CORPSE. The bottle was appended and saved before booting, so a failed
            // wineboot used to leave a permanently broken entry in the list: it appears in the
            // sidebar, can never launch anything, and the user has no way to tell why. That is
            // exactly what the missing-wine.inf bug produced on 2026-07-30 — the dead bottle had
            // to be removed by hand-editing bottles.json.
            //
            // Remove the entry and the half-made prefix. `deleteBottle` already refuses to touch
            // anything outside Decanter's own bottles root or still referenced by another bottle.
            deleteBottle(bottle, removeFiles: true)
            return nil
        }
        markInitialized(bottle.id)
        await applyRegistry(bottleID: bottle.id, console: hidden, finish: false)
        return bottle.id
    }

    // MARK: Online play (isolated from the single-player setup)

    /// True once the separate online engine exists on disk.
    var isOnlineEngineInstalled: Bool {
        FileManager.default.fileExists(atPath: Paths.onlineEngineBin.appendingPathComponent("wine").path)
    }

    /// Clone the installed engine into an independent copy for online bottles.
    ///
    /// `cp -Rc` is an APFS clone: blocks are shared until a file is written, so this is effectively
    /// free (measured: 1.0 s, 2 MB consumed for a 719 MB tree) while still giving the online setup
    /// its own engine files, DLL overrides and `winemetal`. A plain `cp -R` would cost 719 MB and a
    /// symlink would defeat the entire point by re-sharing the tree.
    /// Root directory backing a profile. `offline` is the source everything else is cloned from.
    static func engineRoot(for profile: EngineProfile) -> URL {
        switch profile {
        case .offline: return Paths.wineEngineRoot
        case .online:  return Paths.onlineEngineRoot
        case .legacy:  return Paths.legacyEngineRoot
        }
    }

    /// One line describing what a Rescan found — and what it deliberately did NOT find.
    ///
    /// A bare count is worse than it looks. Rescan only *discovers* engines that already exist, but
    /// Online and Legacy are created on demand when a bottle selects them, so a machine that has
    /// never used them truthfully reports "Found 2" forever. Reported as "even when I click rescan
    /// it doesn't show anything new" — the button was doing its job and saying nothing about the
    /// one thing the person was actually waiting for.
    func rescanSummary() -> String {
        if installations.isEmpty {
            return "No Wine builds found. Use View ▸ Setup Assistant to install one."
        }
        let n = installations.count
        let found = "Found \(n) Wine build\(n == 1 ? "" : "s")."
        let missing = [EngineProfile.online, .legacy].filter { !isEngineInstalled($0) }
        guard !missing.isEmpty else { return found }
        let names = missing.map(\.shortName).joined(separator: " and ")
        return found + " The \(names) engine\(missing.count == 1 ? "" : "s") "
            + "build\(missing.count == 1 ? "s" : "") automatically when you pick "
            + "\(missing.count == 1 ? "it" : "one") in a bottle's Configuration ▸ Engine — "
            + "Rescan can't create \(missing.count == 1 ? "it" : "them")."
    }

    /// Is this profile's engine present?
    func isEngineInstalled(_ profile: EngineProfile) -> Bool {
        FileManager.default.fileExists(
            atPath: profile.binDirectory.appendingPathComponent("wine").path)
    }

    /// Clone the tuned engine into an independent copy for `profile`.
    ///
    /// Written once and parameterised rather than copied per profile. Three near-identical
    /// functions is how the picker and the launcher resolver drifted apart earlier in this project,
    /// and a third engine makes that risk concrete rather than theoretical.
    @discardableResult
    func cloneEngine(for profile: EngineProfile, console: TaskConsole? = nil) async -> Bool {
        guard profile != .offline else { return true }        // offline IS the source
        if isEngineInstalled(profile) {
            console?.append("\(profile.label) engine already present."); return true
        }
        guard isEngineInstalled(.offline) else {
            console?.append("The main engine is not installed yet — run Setup Assistant first.")
            return false
        }
        let dest = Self.engineRoot(for: profile)
        console?.append("Cloning the engine (APFS clone — instant, uses almost no disk)…")
        try? FileManager.default.removeItem(at: dest)
        let result = try? await Shell.run(
            URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-Rc", Paths.wineEngineRoot.path, dest.path],
            environment: ProcessInfo.processInfo.environment)
        guard result?.exitCode == 0, isEngineInstalled(profile) else {
            console?.append("Clone failed: \(result?.stderr ?? "unknown error")")
            return false
        }
        rescanInstallations()
        console?.append("\(profile.label) engine ready at \(dest.lastPathComponent).")
        return true
    }

    @discardableResult
    func cloneEngineForOnline(console: TaskConsole? = nil) async -> Bool {
        await cloneEngine(for: .online, console: console)
    }

    /// Throw away the online engine and re-clone it from the offline one.
    ///
    /// This is what makes the isolation worth having: experiment freely on the online engine, and
    /// if it ends up broken, restore a known-good copy in about a second instead of re-downloading
    /// 480 MB. The offline engine is only ever read from, never written to.
    /// Throw a profile's engine away and re-clone it from the tuned one.
    ///
    /// This is what makes the isolation worth having: break the legacy or online engine freely, and
    /// restore a known-good copy in about a second rather than re-downloading 480 MB. The offline
    /// engine is only ever read from.
    @discardableResult
    func resetEngine(for profile: EngineProfile, console: TaskConsole? = nil) async -> Bool {
        guard profile != .offline else {
            console?.append("The tuned engine is the source — reinstall it via Setup Assistant instead.")
            return false
        }
        // Awaited separately: `||` short-circuits through an autoclosure, which cannot carry an
        // async call. Both checks are wanted anyway.
        let steamUp = await isSteamRunning()
        let gameUp = await isAnyGameRunning()
        if steamUp || gameUp {
            console?.append("Quit Steam and any running game first.")
            return false
        }
        console?.append("Removing the \(profile.label) engine…")
        try? FileManager.default.removeItem(at: Self.engineRoot(for: profile))
        rescanInstallations()
        return await cloneEngine(for: profile, console: console)
    }

    @discardableResult
    func resetOnlineEngine(console: TaskConsole? = nil) async -> Bool {
        await resetEngine(for: .online, console: console)
    }

    /// The discovered installation backing the online engine, if it exists.
    var onlineInstallation: WineInstallation? {
        installations.first {
            $0.binDirectory.standardizedFileURL == Paths.onlineEngineBin.standardizedFileURL
        }
    }

    // MARK: Per-game graphics driver (DXMT)

    /// Games found under this bottle's Steam library, as (folder, main .exe name).
    ///
    /// Steam lays every title out as `steamapps/common/<Title>/`. The main executable is picked as
    /// the largest top-level `.exe`, which beats guessing from the folder name: launchers and
    /// crash handlers ship alongside the game and are invariably much smaller.
    func detectedSteamGames(in bottle: Bottle) -> [(folder: URL, exe: String)] {
        let common = bottle.driveC
            .appendingPathComponent("Program Files (x86)/Steam/steamapps/common", isDirectory: true)
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: common, includingPropertiesForKeys: nil) else { return [] }
        var found: [(folder: URL, exe: String)] = []
        let dirKey: Set<URLResourceKey> = [.isDirectoryKey]
        for dir in dirs where (try? dir.resourceValues(forKeys: dirKey))?.isDirectory == true {
            let sizeKeys: Set<URLResourceKey> = [.fileSizeKey]
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(sizeKeys))
            else { continue }
            func bytes(_ u: URL) -> Int { (try? u.resourceValues(forKeys: sizeKeys).fileSize) ?? 0 }
            let exes = files.filter { $0.pathExtension.lowercased() == "exe" }
            guard let biggest = exes.max(by: { bytes($0) < bytes($1) }) else { continue }
            found.append((dir, biggest.lastPathComponent))
        }
        return found
    }

    // MARK: Generated game launchers

    /// Non-game Steam app ids. Defined once in `GameScanner` because the picker and the launcher
    /// resolver must agree: the same id (228980, Steamworks Common Redistributables) both made a
    /// one-game prefix look ambiguous here and listed itself as a game there.
    private static var nonGameAppIDs: Set<String> { GameScanner.nonGameAppIDs }

    /// Which single game does this bottle represent?
    ///
    /// Resolution order matters. `directExecutable` is an explicit choice by the user (it exists
    /// because some titles' Steam entry point is an anti-cheat shim that cannot work under Wine),
    /// so it wins outright. Otherwise the Steam app id is resolved through the appmanifest, which
    /// names the install folder exactly — far better than guessing at the biggest folder, because
    /// one prefix here holds Sekiro, JJBA and Half Sword at once.
    ///
    /// Returns nil for a plain Steam launcher bottle, which correctly has no game app.
    func resolvedGame(for bottle: Bottle) -> GameAppBuilder.Game? {
        let fm = FileManager.default
        let steamRoot = bottle.driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
        let appID = steamAppID(for: bottle)

        let direct = (bottle.settings.directExecutable ?? "").trimmingCharacters(in: .whitespaces)
        if !direct.isEmpty {
            if let exe = Self.resolveStoredExecutable(direct, driveC: bottle.driveC),
               fm.fileExists(atPath: exe.path) {
                return GameAppBuilder.Game(name: bottle.name,
                                           folder: exe.deletingLastPathComponent(),
                                           executable: exe,
                                           appID: appID,
                                           prefersDirectLaunch: true)
            }
        }

        // No app id configured? Fall back to what is actually installed in the prefix.
        //
        // A bottle created straight from "New Bottle" has no `-applaunch` and no steamAppID, so
        // requiring one meant a prefix containing exactly one game produced no launcher at all —
        // which is precisely the case a user expects to just work (hit on the Half Sword bottle).
        //
        // Only when there is EXACTLY ONE manifest. A prefix holding several games (this project's
        // Steam-Wine11 holds three) is a launcher bottle, and guessing which of them it "means"
        // would produce a launcher for the wrong title.
        let resolvedID: String
        if let appID, !appID.isEmpty {
            resolvedID = appID
        } else {
            let steamapps = steamRoot.appendingPathComponent("steamapps", isDirectory: true)
            let ids = ((try? fm.contentsOfDirectory(atPath: steamapps.path)) ?? [])
                .filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }
                .map { $0.replacingOccurrences(of: "appmanifest_", with: "")
                         .replacingOccurrences(of: ".acf", with: "") }
                .filter { !Self.nonGameAppIDs.contains($0) }
            guard ids.count == 1, let only = ids.first else { return nil }
            resolvedID = only
        }

        let manifest = steamRoot.appendingPathComponent("steamapps/appmanifest_\(resolvedID).acf")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8),
              let installDir = acfValue("installdir", in: text)
        else { return nil }

        let folder = steamRoot.appendingPathComponent("steamapps/common/\(installDir)", isDirectory: true)
        guard let exe = GameScanner.largestExecutable(in: folder) else { return nil }
        return GameAppBuilder.Game(name: acfValue("name", in: text) ?? bottle.name,
                                   folder: folder, executable: exe, appID: appID)
    }

    /// Turn a stored executable path into a real macOS URL.
    ///
    /// `directExecutable` is written by whatever produced it, and in practice that is a **quoted
    /// Windows path**: `"C:\Program Files (x86)\Steam\steamapps\common\…\ASBR.exe"`. The
    /// original code only handled macOS paths — anything not starting with `/` was appended to
    /// `drive_c` verbatim, quotes and backslashes and all, producing a path that can never exist.
    ///
    /// So `directExecutable` never resolved for ANY bottle. JJBA appeared to work only because it
    /// fell through to the app-id branch; the setting that exists precisely to bypass Steam was
    /// silently doing nothing.
    ///
    /// Handles, in order: surrounding quotes, absolute macOS paths, `X:\…` drive letters, and
    /// backslash-separated relative paths.
    static func resolveStoredExecutable(_ raw: String, driveC: URL) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty else { return nil }

        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }

        // Drive letter: "C:\rest" or "C:/rest". Everything after the colon-separator is relative
        // to drive_c — Decanter only ever maps one drive.
        let chars = Array(s)
        if chars.count > 2, chars[1] == ":" {
            var rest = String(chars.dropFirst(2))
            while rest.hasPrefix("\\") || rest.hasPrefix("/") { rest = String(rest.dropFirst()) }
            return driveC.appendingPathComponent(rest.replacingOccurrences(of: "\\", with: "/"))
        }
        return driveC.appendingPathComponent(s.replacingOccurrences(of: "\\", with: "/"))
    }

    /// The bottle's Steam app id, from the explicit setting or parsed out of `-applaunch <id>`.
    private func steamAppID(for bottle: Bottle) -> String? {
        let explicit = (bottle.settings.steamAppID ?? "").trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty { return explicit }
        guard let r = bottle.settings.steamArguments.range(of: "-applaunch ") else { return nil }
        let id = bottle.settings.steamArguments[r.upperBound...].prefix(while: { $0.isNumber })
        return id.isEmpty ? nil : String(id)
    }

    // Executable selection lives in `GameScanner.largestExecutable`, shared with the new-bottle
    // picker so the list a user chooses from and the binary the launcher runs can never disagree.

    /// The distinct prefixes to scan.
    ///
    /// Distinct, not per-bottle: three of this project's bottles share `Steam-Wine11`, so scanning
    /// per bottle listed every game three times.
    var scannablePrefixes: [URL] {
        var seen = Set<String>()
        return bottles.compactMap { bottle in
            let prefix = bottle.url.standardizedFileURL
            return seen.insert(prefix.path).inserted ? prefix : nil
        }
    }

    /// Every game found across the prefixes Decanter knows about.
    ///
    /// `nonisolated` and taking the prefixes as a parameter ON PURPOSE. `AppModel` is `@MainActor`,
    /// so a main-actor method called from `Task.detached` simply hops back and does the work on the
    /// main actor anyway — the first version of this claimed to scan off the main thread and did
    /// not. Keeping the file walk out of the actor is what actually stops the sheet freezing.
    nonisolated static func scanForGames(in prefixes: [URL]) -> [GameScanner.FoundGame] {
        prefixes.flatMap { GameScanner.scan(prefix: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A bottle name not already taken.
    ///
    /// Originally required because the generated launcher's path was derived from the name, so two
    /// bottles sharing one silently overwrote each other's `.app`. That generator is gone, but
    /// duplicate names are still worth avoiding: the sidebar becomes ambiguous and every message
    /// naming a bottle stops identifying which. Numbering keeps it readable.
    func uniqueBottleName(_ wanted: String) -> String {
        let base = wanted.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return uniqueBottleName("Bottle") }
        let taken = Set(bottles.map { $0.name })
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Does a bottle already exist for this game? Used to mark it in the picker rather than
    /// silently creating a near-duplicate.
    ///
    /// Delegates to `resolvedGame` rather than re-deriving the answer from `steamAppID` /
    /// `directExecutable`. The first version did re-derive it and was wrong: a bottle created
    /// straight from "New Bottle" has NEITHER field set and resolves its game through the
    /// single-manifest fallback, so the Half Sword bottle went unmarked while genuinely owning
    /// that game. Comparing resolved executables makes the badge mean exactly what the Play button
    /// will do, and keeps the two from drifting apart again.
    func existingBottle(for game: GameScanner.FoundGame) -> Bottle? {
        bottles.first { bottle in
            guard bottle.url.standardizedFileURL.path == game.prefix.path else { return false }
            return resolvedGame(for: bottle)?.executable.path == game.executable.path
        }
    }

    /// Create a bottle already configured to play `game`.
    ///
    /// Reuses the game's EXISTING prefix rather than booting a fresh one. A new prefix would mean
    /// reinstalling Steam and re-downloading the game for no benefit — the same reasoning the
    /// hand-written JJBA launcher records for sharing Sekiro's prefix.
    @discardableResult
    func createBottle(named name: String, for game: GameScanner.FoundGame) -> Bottle.ID? {
        guard let installation = defaultInstallation else { return nil }
        var bottle = Bottle(name: uniqueBottleName(name.isEmpty ? game.name : name), url: game.prefix)
        bottle.wineBinDirectory = installation.binDirectory
        bottle.isInitialized = true          // the prefix already exists and is booted
        if let id = game.appID {
            bottle.settings.steamAppID = id
            bottle.settings.steamArguments = "-silent -no-cef-sandbox -skipinitialbootstrap -applaunch \(id)"
        } else {
            // No Steam id: point straight at the binary, which is the only way to start a
            // non-Steam title.
            bottle.settings.directExecutable = game.executable.path
        }
        bottles.append(bottle)
        selectedBottleID = bottle.id
        saveBottles()

        // No launcher bundle is generated. Decanter used to write a `.app` per game into
        // ~/Applications and route Play through it; removed as "a useless extra step that just
        // gets in the way". Play now launches the game directly via `launchSteam`, which already
        // waits for Steam, honours direct-exe bottles and installs the graphics driver first —
        // everything the generated script was doing.
        return bottle.id
    }

    /// Make the prefix's registry match `software2D` before launching.
    ///
    /// F5 (bug-sweep): build the printable report for `--reclaim`. Gathers what's actually on
    /// disk, what bottles.json references, and what `~/Applications/*.app` launchers reference,
    /// then hands the classification to `OrphanReclaim` — this function does I/O, `OrphanReclaim`
    /// does none, so the "is this actually orphaned" logic stays unit-testable.
    private func reclaimReport() -> String {
        let fm = FileManager.default
        func names(in dir: URL) -> [String] {
            (try? fm.contentsOfDirectory(atPath: dir.path))?
                .filter { !$0.hasPrefix(".") } ?? []
        }
        func size(_ url: URL) -> Int {
            guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                        options: [.skipsHiddenFiles]) else { return 0 }
            var total = 0
            for case let u as URL in e {
                total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            return total
        }
        func human(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }

        // Every hand-made launcher's shader-cache path, so a directory unreferenced by
        // bottles.json but referenced HERE is correctly kept, not reported reclaimable.
        var referencedByLaunchers = Set<String>()
        let appsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        if let apps = try? fm.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil) {
            for app in apps where app.pathExtension == "app" {
                let macOSDir = app.appendingPathComponent("Contents/MacOS")
                guard let bins = try? fm.contentsOfDirectory(at: macOSDir, includingPropertiesForKeys: nil) else { continue }
                for bin in bins {
                    guard let text = try? String(contentsOf: bin, encoding: .utf8) else { continue }
                    for line in text.split(separator: "\n") where line.contains("ShaderCache/") {
                        if let range = line.range(of: "ShaderCache/") {
                            let rest = line[range.upperBound...]
                            let name = rest.prefix { $0 != "\"" && $0 != "/" && $0 != "'" }
                            if !name.isEmpty { referencedByLaunchers.insert(String(name)) }
                        }
                    }
                }
            }
        }

        let referencedByBottles = Set(bottles.map { $0.url.lastPathComponent })
        let bottleOrphans = OrphanReclaim.orphanedBottleDirs(
            present: names(in: Paths.bottlesRoot), referencedByBottles: referencedByBottles)
        let cacheOrphans = OrphanReclaim.orphanedShaderCacheDirs(
            present: names(in: Paths.shaderCacheRoot), referencedByBottles: referencedByBottles,
            referencedByLaunchers: referencedByLaunchers)

        var out = "\n=== Decanter reclaim report — LIST ONLY, nothing deleted ===\n\n"
        out += "Backups/ was not scanned — it holds RESTORE-*.sh's rollback material and is "
             + "never in scope for this report.\n"
        if referencedByLaunchers.isEmpty {
            out += "No ~/Applications launcher shader-cache references found.\n"
        } else {
            out += "Launcher-referenced shader caches (excluded): \(referencedByLaunchers.sorted().joined(separator: ", "))\n"
        }

        out += "\nBOTTLES/ (\(bottleOrphans.count) reclaimable)\n"
        for item in bottleOrphans {
            let bytes = size(Paths.bottlesRoot.appendingPathComponent(item.name))
            out += "  \(item.name)  —  \(human(bytes))  —  \(item.reason)\n"
        }

        out += "\nSHADERCACHE/ (\(cacheOrphans.count) reclaimable)\n"
        for item in cacheOrphans {
            let bytes = size(Paths.shaderCacheRoot.appendingPathComponent(item.name))
            out += "  \(item.name)  —  \(human(bytes))  —  \(item.reason)\n"
        }
        out += "\nNothing was deleted. Review the list above and remove anything yourself if you "
             + "want the space back.\n"
        return out
    }

    /// ⚠️ THE SETTING USED TO DO NOTHING UNLESS YOU PRESSED "Apply to Prefix". `applySoftware2D`
    /// was reachable only from `applyRegistry`, so toggling it on and pressing Play changed
    /// nothing at all — reported as "I turned the 2D game thing on and it's still slow", and it
    /// was a design fault, not user error. A per-game override that the game must be launched
    /// with has to be written ON LAUNCH, not on a button the user has no reason to press.
    func ensureSoftware2D(for bottle: Bottle) async {
        guard let installation = installation(for: bottle) else { return }
        let console = TaskConsole(title: "2D")
        await applySoftware2D(bottle, installation: installation,
                              env: Wine.environment(for: bottle, using: installation),
                              console: console)
    }

    /// Copy the bundled DXMT DLLs into each detected game and register the per-game DLL overrides.
    ///
    /// PER-GAME, NEVER PREFIX-WIDE. A prefix-wide d3d11/dxgi override routes Steam's own CEF UI
    /// through DXMT and black-screens the client (GAMING-STACK.md section 6), so the override is
    /// scoped to `AppDefaults\<exe>` and the DLLs are dropped beside the game rather than into
    /// system32.
    @discardableResult
    func installGraphicsDriver(in bottle: Bottle, console: TaskConsole? = nil) async -> Int {
        guard let installation = installation(for: bottle) else {
            console?.append("No Wine installation available for this bottle.")
            return 0
        }

        // SCOPE TO THIS BOTTLE'S OWN GAME.
        //
        // `detectedSteamGames` lists every game in the PREFIX, and three bottles here share
        // `Steam-Wine11`. Applying a per-bottle graphics choice to all of them means the Peggle
        // bottle set to WineD3D strips Sekiro's DXMT overrides — and then the Sekiro bottle puts
        // them back on the next pass, so the setting appears to do nothing while quietly fighting
        // its neighbours. Observed exactly that: WineD3D cleared 4 games, DXMT bottles re-added 4.
        //
        // A bottle that resolves a game touches ONLY that game. A launcher bottle (plain Steam,
        // resolves nothing) keeps the prefix-wide behaviour, which is what patches a whole fresh
        // Steam library in one go.
        let scoped: [(folder: URL, exe: String)]
        if let mine = resolvedGame(for: bottle) {
            let name = mine.executable.lastPathComponent.lowercased()
            scoped = detectedSteamGames(in: bottle).filter { $0.exe.lowercased() == name }
        } else {
            scoped = detectedSteamGames(in: bottle)
        }

        // HONOUR THE BACKEND THE USER PICKED.
        //
        // This used to install DXMT unconditionally, so 3 of the 4 options in Configuration ▸
        // Graphics ▸ Backend did nothing at all: `settings.graphics` was read only by the picker
        // that set it and by the label that displayed it back. Picking DXVK installed DXMT.
        switch bottle.settings.graphics {
        case .dxmt:
            break                                   // handled below

        case .wined3d:
            // Wine's own implementation — the point is the ABSENCE of an override. Remove any this
            // bottle previously installed, or "WineD3D" would just mean "whatever was left behind".
            var cleared = 0
            let env = Wine.environment(for: bottle, using: installation)
            for game in scoped {
                // NOTE THE TRAILING BACKSLASH. Written without it this concatenates to
                // `…\AppDefaultsPeggle.exe\DllOverrides` — a key that does not exist, so every
                // `reg delete` "succeeds" against nothing and the overrides stay put. That exact
                // typo shipped once already in the software-2D writer; both were introduced by a
                // heredoc eating the final backslash, and both looked correct in review.
                let key = #"HKCU\Software\Wine\AppDefaults\"# + game.exe + #"\DllOverrides"#
                var removedAll = true
                for dll in ["d3d11", "dxgi", "d3d10core"] {
                    // Check the result. `reg delete` on an absent value returns non-zero, which is
                    // fine, but a failure that means something else must not pass as success — the
                    // whole reason this bug survived is that nobody looked.
                    let r = try? await Shell.run(installation.loader,
                                                 arguments: ["reg", "delete", key, "/v", dll, "/f"],
                                                 environment: env)
                    if r == nil { removedAll = false }
                }
                if !removedAll {
                    console?.append("Could not clear overrides for \(game.exe).")
                }
                cleared += 1
            }
            console?.append("WineD3D selected — removed per-game graphics overrides for \(cleared) game(s).")
            return cleared

        case .dxvk:
            // NOT SHIPPED COMPLETE. The engine carries `DXVK/x64/{d3d11,d3d10core}.dll` and **no
            // `dxgi.dll`**. DXVK 1.10.3 needs its own dxgi: pairing it with Wine's builtin fails at
            // device creation with "D3D11CoreCreateDevice: Adapter is not a DXVK adapter", observed
            // directly on this machine. Installing the incomplete pair would swap one silent
            // failure for another, so say so instead.
            console?.append("DXVK isn't available in this build — the engine ships d3d11 and "
                            + "d3d10core but no matching dxgi.dll, and DXVK refuses to create a "
                            + "device without it. Use DXMT, or WineD3D for older games.")
            return 0

        case .d3dmetal:
            // Comes from CrossOver / Game Porting Toolkit, not from Decanter. Bottles imported from
            // CrossOver are set to this because THEIR engine provides it; Decanter's does not.
            console?.append("D3DMetal comes with CrossOver or the Game Porting Toolkit and isn't "
                            + "part of Decanter's engine. Use DXMT unless this bottle runs on a "
                            + "CrossOver engine that provides it.")
            return 0
        }

        guard let src = Paths.bundledDXMT else {
            console?.append("This build of Decanter ships no DXMT payload.")
            return 0
        }
        let games = scoped
        if games.isEmpty { console?.append("No games found for this bottle yet.") }

        let fm = FileManager.default
        let env = Wine.environment(for: bottle, using: installation)
        var done = 0
        for game in games {
            // Skip COPYING the DLLs when they already match — this is what makes the call cheap
            // enough to run on every Steam launch. Size comparison is sufficient: the patched DLLs
            // are a different size from both stock DXMT and whatever the game itself shipped.
            //
            // ⚠️ F4 (bug-sweep, 2026-08-22): this used to be `if already { continue }` — skipping
            // the DLL copy ALSO skipped the registry-override write below, unconditionally. A game
            // whose DLLs matched but whose override had been cleared by something else (this
            // project has one concrete way that happens: switching a bottle to WineD3D and back —
            // WineD3D's branch clears the override but never touches the DLL files, so the very
            // next DXMT install call sees `already == true` and walks straight past restoring it)
            // silently stayed on WineD3D forever, while Configuration kept reporting DXMT as
            // active. REPRODUCED LIVE before this fix: cleared Peggle's DllOverrides key by hand,
            // re-ran `installGraphicsDriver` with DLLs already matching, and the key stayed absent.
            //
            // The fix is to make DLL-copying and override-writing two independent steps: skipping
            // one must never skip the other.
            let already = Paths.dxmtDLLs.allSatisfy { dll in
                let a = (try? game.folder.appendingPathComponent(dll)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let b = (try? src.appendingPathComponent(dll)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
                return a == b
            }

            var copied = true
            if !already {
                for dll in Paths.dxmtDLLs {
                    let dst = game.folder.appendingPathComponent(dll)
                    // Keep one backup of whatever was there first, so this is reversible by hand.
                    let backup = game.folder.appendingPathComponent(dll + ".decanter-orig")
                    if fm.fileExists(atPath: dst.path), !fm.fileExists(atPath: backup.path) {
                        try? fm.copyItem(at: dst, to: backup)
                    }
                    try? fm.removeItem(at: dst)
                    do { try fm.copyItem(at: src.appendingPathComponent(dll), to: dst) }
                    catch { console?.append("Could not write \(dll) into \(game.folder.lastPathComponent): \(error.localizedDescription)"); copied = false }
                }
            }
            guard copied else { continue }

            // ALWAYS check/re-assert the registry writes, even when the DLL copy above was
            // skipped. Copying the DLLs is only half the job — without the override Wine ignores
            // them entirely and the game falls back to WineD3D, which is precisely the slow path
            // this feature exists to avoid. Discarding the result meant a silent failure would
            // still be reported as "installed", and the user would be left wondering why a game
            // that Decanter said was patched still ran badly.
            let key = #"HKCU\Software\Wine\AppDefaults\"# + game.exe + #"\DllOverrides"#
            var overridesOK = true
            for dll in ["d3d11", "dxgi", "d3d10core"] {
                let args = ["reg", "add", key, "/v", dll, "/t", "REG_SZ", "/d", "native,builtin", "/f"]
                let result = try? await Shell.run(installation.loader, arguments: args, environment: env)
                if result?.succeeded != true { overridesOK = false }
            }
            guard overridesOK else {
                console?.append("Copied the graphics DLLs for \(game.folder.lastPathComponent), "
                                + "but could not set the Wine override — the game will still use "
                                + "the slow renderer. Try again once nothing is running.")
                continue
            }
            console?.append("Graphics driver installed for \(game.folder.lastPathComponent) (\(game.exe)).")
            done += 1
        }
        return done
    }

    func deleteBottle(_ bottle: Bottle, removeFiles: Bool) {
        bottles.removeAll { $0.id == bottle.id }
        if selectedBottleID == bottle.id { selectedBottleID = bottles.first?.id }
        saveBottles()
        guard removeFiles else { return }

        // Only ever delete a prefix Decanter itself created, and only when no remaining bottle
        // still points at it. Both guards matter:
        //  * Imported CrossOver bottles live OUTSIDE Decanter (~/Library/Application Support/
        //    CrossOver/Bottles). Deleting there would destroy the user's CrossOver install.
        //  * `importCrossOverBottles` registers SEVERAL bottles against the SAME prefix (a base
        //    one plus one per installed game), so removing a single game bottle must not take the
        //    shared prefix — and its siblings — with it.
        let ourRoot = Paths.bottlesRoot.standardizedFileURL.path
        let target = bottle.url.standardizedFileURL.path
        let isOurs = target.hasPrefix(ourRoot + "/")
        // F18 (bug-sweep): this used to compare `.standardizedFileURL ==`, which is case-SENSITIVE
        // — APFS is case-insensitive by default, so two bottles whose stored `url` differed only in
        // case (e.g. an imported CrossOver bottle) would both point at the SAME real directory while
        // comparing as different, and this guard would delete a prefix a sibling bottle still used.
        // `PrefixSharing` exists precisely to be the one place that answers "which bottles share
        // this prefix" — this was a second, less correct opinion. `bottle` was already removed from
        // `bottles` above, so `group` (not `others`) is right here: anything it finds IS a different
        // bottle on the same prefix.
        let stillReferenced = !PrefixSharing.group(of: bottle, in: bottles).isEmpty
        guard isOurs, !stillReferenced else { return }
        try? FileManager.default.removeItem(at: bottle.url)
    }

    func update(_ bottle: Bottle) {
        guard let index = bottles.firstIndex(where: { $0.id == bottle.id }) else { return }
        bottles[index] = bottle
        saveBottles()
    }

    private func markInitialized(_ id: Bottle.ID) {
        guard let index = bottles.firstIndex(where: { $0.id == id }) else { return }
        bottles[index].isInitialized = true
        saveBottles()
    }

    /// Turn a user-supplied bottle name into something safe to use as a folder name.
    ///
    /// Replaces anything outside `[A-Za-z0-9-_ ]`, which also neutralises path traversal:
    /// `../../etc/passwd` becomes `------etc-passwd`, and `.`/`..` become `-`/`--`.
    ///
    /// TRUNCATED to 120 characters. macOS caps a filename at 255 bytes, and without a limit a long
    /// name produced a folder name the filesystem refused outright — `mkdir` failed with "File name
    /// too long", wineboot then failed, and the user was left with a bottle that could never work.
    /// 120 leaves room for the " 2", " 3" suffixes `uniqueBottleFolder` appends, and for multi-byte
    /// characters that occupy more than one byte each.
    private func diskSafe(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let mapped = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return String(mapped.prefix(120))
    }

    // MARK: CrossOver import

    struct DetectedSteamGame { let appid: String; let name: String }

    /// Adopt existing CrossOver bottles (and their installed Steam games) as Decanter
    /// bottles. Non-destructive: it only *registers* the prefixes — it never re-runs
    /// wineboot or touches the CrossOver prefix, so nothing already installed breaks.
    @discardableResult
    func importCrossOverBottles() -> Int {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let coBinCandidates = [
            home.appendingPathComponent("Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"),
            URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"),
        ]
        let coBin = coBinCandidates.first {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("wine").path)
        }

        let bottlesDir = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: bottlesDir, includingPropertiesForKeys: nil) else { return 0 }

        var added = 0
        var firstNew: Bottle.ID?

        for prefix in entries {
            // Only real Wine prefixes.
            guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c").path),
                  FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path)
            else { continue }

            // The prefix itself → a "Steam"/base bottle.
            if let id = addImportedBottle(name: prefix.lastPathComponent, prefix: prefix, wineBin: coBin) {
                added += 1; firstNew = firstNew ?? id
            }
            // Each installed Steam game → its own bottle that boots straight into the game.
            // `-silent` belongs ONLY here: Steam is just a DRM host for a game bottle, so its
            // window is unwanted. Never put -silent on a launcher bottle — Steam then starts
            // with no window and the user has to click Launch twice to see it.
            for game in installedSteamGames(in: prefix) {
                let args = "-silent -no-cef-sandbox -skipinitialbootstrap -applaunch \(game.appid)"
                if let id = addImportedBottle(name: game.name, prefix: prefix, wineBin: coBin, steamArgs: args) {
                    added += 1; firstNew = firstNew ?? id
                }
            }
        }

        if added > 0 {
            saveBottles()
            rescanInstallations()
            if let firstNew { selectedBottleID = firstNew }
        }
        return added
    }

    /// Register one existing prefix as a bottle. Returns its id if newly added, else nil.
    @discardableResult
    private func addImportedBottle(name: String, prefix: URL, wineBin: URL?, steamArgs: String? = nil) -> Bottle.ID? {
        // Idempotent: same name + same prefix means we already imported it.
        //
        // F18 (bug-sweep): raw `URL ==`, not even standardized, is case-sensitive — the same
        // comparator gap as the delete guard above, lower stakes here (a spurious duplicate bottle
        // registered, not data loss) but the same missing PrefixSharing comparator.
        if bottles.contains(where: { $0.name == name && PrefixSharing.key(for: $0.url) == PrefixSharing.key(for: prefix) }) {
            return nil
        }
        var bottle = Bottle(name: name, url: prefix)
        bottle.wineBinDirectory = wineBin
        bottle.isInitialized = true                 // already set up by CrossOver
        bottle.settings.graphics = .d3dmetal        // CrossOver runs these with D3DMetal
        bottle.settings.syncMode = .msync
        if let steamArgs { bottle.settings.steamArguments = steamArgs }
        bottles.append(bottle)
        return bottle.id
    }

    /// Parse `steamapps/appmanifest_*.acf` to list installed games (skips redistributables).
    private func installedSteamGames(in prefix: URL) -> [DetectedSteamGame] {
        let steamapps = prefix
            .appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: steamapps, includingPropertiesForKeys: nil) else { return [] }

        var games: [DetectedSteamGame] = []
        for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let appid = acfValue("appid", in: text),
                  let name = acfValue("name", in: text) else { continue }
            if name.range(of: "Redistributable", options: .caseInsensitive) != nil { continue }
            games.append(DetectedSteamGame(appid: appid, name: name))
        }
        return games
    }

    private func acfValue(_ key: String, in text: String) -> String? {
        let pattern = "\"\(key)\"\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: Actions

    /// Write the bottle's settings into its prefix registry.
    func applySettings(_ bottle: Bottle) {
        let console = openConsole(title: "Applying settings — \(bottle.name)")
        Task { await applyRegistry(bottleID: bottle.id, console: console, finish: true) }
    }

    private func applyRegistry(bottleID: Bottle.ID, console: TaskConsole, finish: Bool) async {
        guard let bottle = bottles.first(where: { $0.id == bottleID }),
              let installation = installation(for: bottle) else {
            console.append("No Wine installation available.")
            console.finish()
            return
        }
        let env = Wine.environment(for: bottle, using: installation)
        for (exe, args) in Wine.registrySteps(for: bottle, using: installation) {
            console.append("$ wine \(args.joined(separator: " "))")
            do {
                let result = try await Shell.run(exe, arguments: args, environment: env)
                if !result.stdout.isEmpty { console.append(result.stdout) }
                if !result.succeeded { console.append(result.stderr) }
            } catch {
                console.append("error: \(error.localizedDescription)")
            }
        }
        await applySoftware2D(bottle, installation: installation, env: env, console: console)
        if finish { console.finish() }
    }

    /// Write (or clear) the per-executable "no 3D" override that forces an old 2D game to use its
    /// software renderer. See `BottleSettings.software2D` for why this is a speed-up.
    ///
    /// Per-EXECUTABLE deliberately: `HKCU\Software\Wine\AppDefaults\<exe>\Direct3D`. A
    /// prefix-wide `renderer=no3d` would hit every game sharing the prefix — Sekiro and JJBA share
    /// this one — and strip 3D from titles that need it.
    private func applySoftware2D(_ bottle: Bottle, installation: WineInstallation,
                                 env: [String: String], console: TaskConsole) async {
        // NOT gated on resolving a game: a plain Steam bottle plays everything and resolves
        // nothing, yet it is exactly where an old 2D title gets launched from. The PopCap sweep
        // below still finds the unpacked binary, so the setting works there too.
        let exe = resolvedGame(for: bottle)?.executable.lastPathComponent
        // The resolved exe is often a DRM WRAPPER that unpacks and runs the real binary somewhere
        // else — Peggle's `Peggle.exe` extracts `C:\ProgramData\PopCap Games\Peggle\popcapgame1.exe`
        // and it is the UNPACKED process that renders. An override on the wrapper alone does
        // nothing at all. Cover both. (Same trap as aiming DLL overrides at `Peggle.exe`.)
        var targets: Set<String> = exe.map { [$0] } ?? []

        // ⚠️ ONLY widen the target list when TURNING THIS ON. Bottles share prefixes here — Steam,
        // Sekiro and JJBA all live in `Steam-Wine11` — so if a bottle with the setting OFF also
        // swept for extra executables, it would DELETE the override a different bottle just wrote
        // for the same prefix. That happened: `popcapgame1.exe` was cleared moments after being
        // set, by a bottle that has nothing to do with Peggle. Turning it off touches only the
        // executable this bottle itself resolves to.
        guard bottle.settings.software2D else {
            // Don't clear an override a SIBLING bottle still wants ON for this same executable.
            //
            // Two bottles can independently resolve to one exe — the New Bottle picker explicitly
            // allows a second "Peggle Deluxe" bottle, flagging it "Added" rather than refusing it —
            // and this bottle turning off must not silently undo what the other one asked for.
            // Bug-sweep F8: proven with `PrefixSharingTests.testSoftware2DIsWantedIfAnyBottle…`.
            let group = bottlesSharingPrefix(with: bottle)
            for target in targets.sorted() {
                if PrefixSharing.software2DWanted(forExe: target, in: group,
                                                  resolve: { self.resolvedGame(for: $0)?.executable.lastPathComponent }) {
                    console.append("Software 2D left ON for \(target) — another bottle sharing "
                                   + "this prefix still wants it.")
                    continue
                }
                let key = #"HKCU\Software\Wine\AppDefaults\"# + target + #"\Direct3D"#
                console.append("Software 2D off for \(target)")
                _ = try? await Shell.run(installation.loader,
                                         arguments: ["reg", "delete", key, "/v", "renderer", "/f"],
                                         environment: env)
            }
            return
        }

        // PopCap/SexyAppFramework Steam releases all unpack to this one name, and the wrapper
        // DELETES it on exit — so a filesystem sweep only finds it while the game is running,
        // which is never when settings are applied. Include it by name: an override on an
        // executable that does not exist costs nothing, and this is the binary that renders.
        targets.insert("popcapgame1.exe")
        let popcap = bottle.driveC.appendingPathComponent("ProgramData/PopCap Games", isDirectory: true)
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: popcap, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension.lowercased() == "exe" {
                targets.insert(file.lastPathComponent)
            }
        }

        if targets.isEmpty {
            if bottle.settings.software2D { console.append("Software 2D: no target executable found.") }
            return
        }
        for target in targets.sorted() {
            let key = #"HKCU\Software\Wine\AppDefaults\"# + target + #"\Direct3D"#
            let args = ["reg", "add", key, "/v", "renderer", "/t", "REG_SZ", "/d", "no3d", "/f"]
            console.append("Software 2D ON for \(target)")
            _ = try? await Shell.run(installation.loader, arguments: args, environment: env)
        }
    }

    /// Launch one of Wine's built-in tools (winecfg, regedit, …).
    func runTool(_ tool: Wine.Tool, in bottle: Bottle) {
        launch(title: "\(tool.title) — \(bottle.name)", bottle: bottle, arguments: tool.arguments)
    }

    /// Run an arbitrary Windows executable inside a bottle.
    func runExecutable(_ exe: URL, in bottle: Bottle, extraArguments: [String] = []) {
        launch(title: "\(exe.lastPathComponent) — \(bottle.name)", bottle: bottle,
               arguments: [exe.path] + extraArguments)
    }

    /// Reveal the bottle's C: drive in Finder.
    func openCDrive(_ bottle: Bottle) {
        NSWorkspace.shared.open(bottle.driveC)
    }

    /// Download + install Decanter's own Wine engine, streaming progress into a console.
    /// Used by the setup wizard and by `--install-engine`.
    func installEngine() async {
        let console = openConsole(title: "Installing the Windows engine")
        console.append("Downloading the Windows engine (~317 MB)…")
        console.append("Then upgrading it to the msync build (faster; removes frame spikes)…")
        let installer = WineInstaller()
        var lastReported = -1
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                if case .downloading(let p) = installer.phase {
                    let pct = Int(p * 100)
                    if pct >= lastReported + 10 { lastReported = pct; console.append("… \(pct)%") }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        await installer.install()
        ticker.cancel()
        switch installer.phase {
        case .done(let version):
            console.append("Installed: \(version)")
            console.append("Location: \(Paths.wineEngineBin.path)")
            rescanInstallations()
            console.finish(0)
        case .failed(let message):
            console.append("Failed: \(message)")
            console.finish(1)
        default:
            console.finish()
        }
    }

    /// Kick off the Rosetta 2 installer (prompts for admin rights on its own).
    func installRosetta() {
        let console = openConsole(title: "Installing Rosetta 2")
        console.append("$ \(SystemChecks.rosettaInstallCommand)")
        console.handle = try? Shell.stream(
            URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
            arguments: ["--install-rosetta", "--agree-to-license"],
            environment: ProcessInfo.processInfo.environment,
            onOutput: { console.append($0) },
            onExit: { [weak self] code in
                self?.isRosettaInstalled = SystemChecks.isRosettaInstalled
                console.finish(code)
            }
        )
    }

    /// Download (if needed) and silently install Steam into the bottle, showing a console.
    func installSteam(in bottle: Bottle) {
        let console = openConsole(title: "Installing Steam — \(bottle.name)")
        Task { await performSteamInstall(in: bottle, console: console) }
    }

    /// Core Steam install. Pass a console to show a log (manual "Install Steam"), or nil to run
    /// quietly (setup wizard). Returns whether Steam ended up installed.
    @discardableResult
    func performSteamInstall(in bottle: Bottle, console: TaskConsole?) async -> Bool {
        guard let installation = installation(for: bottle) else {
            console?.append("No Wine build available."); console?.finish(); return false
        }
        do {
            console?.append("Downloading Steam…")
            let installer = try await Steam.downloadInstaller { _ in }
            console?.append("Installing Steam into the bottle…")
            let env = Wine.environment(for: bottle, using: installation)
            // Explicit longer timeout: a real installer run, not a quick reg query. See Shell.run's
            // F16 doc comment.
            let result = try await Shell.run(installation.loader,
                                             arguments: Steam.installArguments(installerPath: installer),
                                             environment: env, timeout: 180)
            if let console, !result.stderr.isEmpty { console.append(result.stderr) }
            let installed = bottle.isSteamInstalled
            console?.append(installed ? "Steam installed." : "Installer finished.")
            console?.finish(result.exitCode)
            objectWillChange.send()   // isSteamInstalled is filesystem-derived; refresh the UI
            return installed
        } catch {
            console?.append("error: \(error.localizedDescription)"); console?.finish(); return false
        }
    }

    /// Install Rosetta 2 and wait for it to actually finish. Returns whether it's present after.
    /// On macOS 26 `softwareupdate --install-rosetta --agree-to-license` runs without admin
    /// (verified); a future OS that needs elevation will simply return false and the wizard shows
    /// clear guidance rather than silently continuing into a broken state.
    func ensureRosetta() async -> Bool {
        if SystemChecks.isRosettaInstalled { isRosettaInstalled = true; return true }
        // F22 (bug-sweep): missing explicit timeout, so this inherited F16's 30s default — a
        // several-hundred-MB download-plus-install that does not finish in 30s. On a machine that
        // ALREADY has Rosetta (every dev machine this was built on) the guard above short-circuits
        // and this call never even runs, which is exactly why it shipped unnoticed: it only fires
        // on a clean Mac, on someone's actual first run.
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
                                 arguments: ["--install-rosetta", "--agree-to-license"], timeout: 600)
        isRosettaInstalled = SystemChecks.isRosettaInstalled
        return isRosettaInstalled
    }

    // MARK: Warm-start — bring Steam up while the user is still choosing a game

    /// Prefix keys (via `PrefixSharing.key`) with a warm-start currently in flight. Published so
    /// the UI can show "Preparing Steam…" — never used to gate Play, which must stay pressable and
    /// simply join the in-flight warm-up (see `launchSteam`) rather than wait on this.
    @Published var warmingPrefixKeys: Set<String> = []

    /// The actual in-flight task per prefix, so `launchSteam` can AWAIT it instead of racing it.
    /// Keyed separately from `warmingPrefixKeys` because the dictionary must survive exactly as
    /// long as the task itself; the published Set exists only for the UI to read.
    private var warmStartTasks: [String: Task<Void, Never>] = [:]

    /// Prefixes whose Steam THIS warm-start brought up, and which no game has claimed for reaping
    /// yet. Consumed (removed) the moment a real `launchSteam` call picks it up, so a warm start
    /// hands off reaping responsibility to the first real game session and no other bottle
    /// mistakenly inherits it later.
    private var warmStartedPrefixKeys: Set<String> = []

    /// The pending debounce timer between a selection change and actually committing to a Steam
    /// boot. Arrow-keying through the sidebar must not spawn a warm-start per row.
    private var pendingWarmStartTask: Task<Void, Never>?

    /// Call this from the sidebar's OWN selection binding — never assign `selectedBottleID`
    /// directly and expect this to fire. `selectedBottleID` is `@Published` and reassigned
    /// programmatically in several places (after a delete, after a create, after CrossOver import)
    /// that are not user intent; a plain `.onChange(of: selectedBottleID)` would warm-start Steam
    /// after every one of those, including right after the bottle it just warmed was deleted. This
    /// is the one place "the user actually chose this" is asserted.
    func userSelectedBottle(_ id: Bottle.ID?) {
        selectedBottleID = id
        pendingWarmStartTask?.cancel()
        guard let id, let bottle = bottles.first(where: { $0.id == id }),
              bottle.settings.steamArguments.contains("-applaunch") else { return }
        let prefixKey = PrefixSharing.key(for: bottle.url)
        pendingWarmStartTask = Task {
            // Debounce: give arrow-key browsing a moment to settle before committing to a boot
            // that can run 30+ seconds. Cancelled outright by the next call to this function, so
            // moving off this row before the debounce elapses starts nothing.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await warmStartSteam(for: bottle, prefixKey: prefixKey)
        }
    }

    /// Start Steam for `bottle`'s prefix in the background and wait for it to log on, so it's
    /// ready before the user presses Play. Never starts a SECOND client — the exact F27 regression
    /// ("missing its steam interface") came from a launch landing on top of one already in flight.
    private func warmStartSteam(for bottle: Bottle, prefixKey: String) async {
        guard warmStartTasks[prefixKey] == nil else { return }   // already warming this prefix
        let task = Task {
            guard await !isSteamRunning() else { return }   // already up — nothing to warm
            warmingPrefixKeys.insert(prefixKey)
            defer { warmingPrefixKeys.remove(prefixKey); warmStartTasks[prefixKey] = nil }

            let flags = bottle.isSteamBootstrapped
                ? "-silent -no-cef-sandbox -skipinitialbootstrap"
                : "-no-cef-sandbox"
            let steamArgs = [bottle.steamExecutable.path] + Steam.launchArguments(from: flags)
            launchQuietly(bottle: bottle, arguments: steamArgs)
            if await waitForSteamLogon(in: bottle, timeout: 150) {
                // Only claim ownership if logon actually landed. A timed-out warm-start still left
                // a Steam process running, but we can't vouch for its state — better to let the
                // eventual `launchSteam` call re-derive `startedSteamForGame` fresh than to claim
                // reaping responsibility for something that never proved it came up correctly.
                warmStartedPrefixKeys.insert(prefixKey)
            }
        }
        warmStartTasks[prefixKey] = task
        await task.value
    }

    /// Launch the Steam client already installed in the bottle.
    func launchSteam(in bottle: Bottle) {
        // A bottle with `-applaunch` launches a *game*: if Steam is already up, running
        // `steam.exe -applaunch <id>` just tells the running client to start the game, which is
        // exactly right — so we must NOT skip it. Only a plain Steam launcher should short-circuit.
        let isGameLauncher = bottle.settings.steamArguments.contains("-applaunch")
        Task {
            // GUARD FIRST — nothing may `await` before the check-and-claim below.
            //
            // `ensureSoftware2D` used to run here, and it spawns a Wine subprocess against the
            // prefix: an await of roughly a second sitting between the click and the guard. Two
            // clicks inside that window both saw an empty `launchingBottleIDs` and both launched.
            // The check and the `insert` that claims it must be reached with no suspension point
            // between them, which on @MainActor makes them atomic with respect to other clicks.
            if launchingBottleIDs.contains(bottle.id) {
                activateRunningGame()
                return
            }
            // For a plain Steam launcher, a second click while Steam runs should just focus it —
            // this is what fixes "every click reopens Steam".
            if !isGameLauncher, await isSteamRunning() {
                // Steam's PROCESS existing is not the same as Steam being usable. After a crash or
                // a hard kill, steam.exe can linger for hours with no window — and focusing
                // nothing made Decanter look broken ("Steam won't launch") while it was in fact
                // behaving as designed. If there is nothing to focus, treat the prefix as wedged,
                // shut it down cleanly and fall through to a fresh launch.
                if activateRunningGame() { return }
                await shutdownPrefix(for: bottle)
            }
            launchingBottleIDs.insert(bottle.id)

            // Safe here: the launch is claimed, so a second click short-circuits above.
            await ensureSoftware2D(for: bottle)

            // Make sure anything newly installed has the patched graphics driver BEFORE it runs.
            // Doing it here rather than only in the wizard is what removes the last manual step: a
            // fresh Steam library has no games at setup time, so a game installed later would
            // otherwise fall back to the slow WineD3D renderer until someone pressed a button. The
            // call returns immediately for games already carrying these DLLs.
            await installGraphicsDriver(in: bottle)

            // DIRECT-EXE bottles: run the game binary itself rather than `steam.exe -applaunch`.
            // Needed for titles whose Steam entry point is an anti-cheat shim (EAC does not work
            // under Wine on macOS). Steam must still be up first for steam_api64 to connect.
            let direct = (bottle.settings.directExecutable ?? "").trimmingCharacters(in: .whitespaces)
            if !direct.isEmpty {
                // Did WE start Steam for this session? Only then may we shut it down afterwards —
                // a Steam the user already had open is theirs, not ours to close.
                var weStartedSteam = false
                if await !isSteamRunning() {
                    weStartedSteam = true
                    // Same bootstrap rule as the plain-Steam path below: skipping the initial
                    // bootstrap on a Steam that has never downloaded its client leaves it unable
                    // to start at all. `-silent` is also dropped in that case — the first-run
                    // download takes minutes and a hidden window looks like nothing happening.
                    let flags = bottle.isSteamBootstrapped
                        ? "-silent -no-cef-sandbox -skipinitialbootstrap"
                        : "-no-cef-sandbox"
                    let steamArgs = [bottle.steamExecutable.path] + Steam.launchArguments(from: flags)
                    launchQuietly(bottle: bottle, arguments: steamArgs)
                    // WAIT FOR THE ACTUAL LOGON, don't guess at a duration.
                    //
                    // This used to sleep a flat 25 s. A cold Steam login regularly takes longer,
                    // and when it does the game starts before steam_api64 can talk to the client
                    // and simply dies — presenting as "the game won't launch" with nothing in any
                    // log. The bundled Sekiro launcher already polls connection_log.txt for this
                    // reason; this brings the app in line with it.
                    await waitForSteamLogon(in: bottle, timeout: 150)
                }
                launchQuietly(bottle: bottle, arguments: [direct], extraEnvironment: steamAppEnvironment(for: bottle))
                suppressWineSystray(isGameLauncher: true)
                reapSteamAfterGame(in: bottle, weStartedSteam: weStartedSteam)
                let exeName = URL(fileURLWithPath: direct).lastPathComponent
                clearLaunchGuard(for: bottle) { await self.isProcessRunning(named: exeName) }
                return
            }

            // DROP -skipinitialbootstrap UNTIL STEAM HAS ACTUALLY BOOTSTRAPPED.
            //
            // That flag exists to stop Steam re-exec'ing itself and leaving two Dock tiles, and it
            // is harmless on an installation whose client files are already present. On a FRESH
            // install it is fatal: the "initial bootstrap" it skips is the first-launch download
            // that fetches steamui.dll, so Steam starts, cannot find its own UI, and dies with
            // "Failed to load steamui.dll" — indistinguishable from the too-old-engine failure and
            // reported by the first person to install this from scratch (2026-07-31).
            //
            // The original note recorded it as "verified: still logs in, still self-updates" — but
            // that verification only ever ran against an already-bootstrapped Steam, which is the
            // one state where the flag cannot hurt.
            var steamArgs = Steam.launchArguments(from: bottle.settings.steamArguments)
            if !bottle.isSteamBootstrapped {
                steamArgs.removeAll { $0 == "-skipinitialbootstrap" }
            }
            let args = [bottle.steamExecutable.path] + steamArgs

            // Join, don't race, a warm-start for this same prefix (see `userSelectedBottle`).
            // Without this, `startedSteamForGame` below could sample Steam mid-launch — the
            // process may not exist yet, briefly, right as the warm-start's own `launchQuietly`
            // call is executing — and Play would start a SECOND Steam client on top of it. That
            // collision is exactly the F27 regression ("missing its steam interface").
            let prefixKey = PrefixSharing.key(for: bottle.url)
            if let warmTask = warmStartTasks[prefixKey] {
                await warmTask.value
            }
            // Did WE bring Steam up? Only then may we shut it down when the game exits — a Steam
            // the user already had open is theirs. Checked BEFORE launching, or the answer is
            // always "yes" a moment later.
            //
            // A warm-start that successfully logged this prefix on counts as "we brought it up"
            // too, even though a different code path did it — Decanter still owns the lifecycle,
            // and reaping must not silently stop happening just because Steam was already running
            // by the time Play was pressed. Consumed (removed), not just read: only the game
            // session that actually claims it inherits reaping, so a later Play on a sibling
            // bottle sharing this prefix doesn't ALSO try to reap the same Steam a second time.
            //
            // Kept SEPARATE from the cold-boot logon wait below on purpose: `steamWasAlreadyUp` is
            // what that wait must gate on. A warm-started Steam is already logged on by the time
            // Play is pressed, so `waitForSteamLogon` would find no NEW "Logged On," line to see —
            // it would wait out the full 150s timeout for an event that already happened, instead
            // of returning immediately. `startedSteamForGame` folds the warm-start flag in for
            // reaping; the wait condition below deliberately does not.
            let steamWasAlreadyUp = await isSteamRunning()
            let weWarmStartedThisPrefix = warmStartedPrefixKeys.remove(prefixKey) != nil
            let startedSteamForGame = !steamWasAlreadyUp || weWarmStartedThisPrefix
            // Quiet: no console sheet pops over Decanter (which made the first click look like a
            // no-op). Steam just opens on its own.
            launchQuietly(bottle: bottle, arguments: args)
            suppressWineSystray(isGameLauncher: isGameLauncher)
            // Reap after the game exits — this path (`steam.exe -applaunch <id>`) is how nearly
            // every game starts, and it had no cleanup at all: only the direct-exe branch above
            // called this, so Steam was left running after Peggle, Sekiro or Half Sword quit.
            if isGameLauncher {
                reapSteamAfterGame(in: bottle, weStartedSteam: startedSteamForGame)
            }

            // F27 (bug-sweep, reported directly by Jack: "I'll click play and it won't work and
            // then when the button turns blue again when I click it peggle loads").
            //
            // ⚠️ CORRECTED 2026-08-25, after a live regression Jack hit on the first version of
            // this fix. The original diagnosis here claimed the cold-boot `-applaunch` gets
            // DROPPED, and "fixed" it by re-issuing the same launch command after
            // `waitForSteamLogon` succeeded. Steam's own `console_log.txt` proves that diagnosis
            // wrong: the `-applaunch` is NOT dropped — Steam processes its own command line ~2s
            // after logon and drives the FULL `GameAction` sequence through `CreatingProcess` on
            // its own. The real bug was only ever `clearLaunchGuard` below, which checked
            // `isSteamRunning()` — true the instant the process exists, not once logged in — so
            // Play re-enabled after ~2s and told Jack the launch had finished when Steam was still
            // ~35s into a cold boot. Jack clicking again mid-boot is what looked like "the launch
            // needed two clicks"; the launch itself was already going to work on its own.
            //
            // The re-issue made this WORSE: a `launchQuietly` call while the first Steam client is
            // still initializing does not forward-and-exit against the running client the way a
            // click against an IDLE client does — the log shows a SECOND FULL Steam client
            // (`Client version` / `Loaded SDL` / `ComputeStartupMode`) starting during
            // `CreatingProcess`, colliding with the in-flight `GameAction`, and the sequence never
            // reaching `Completed`. Peggle opened "missing its steam interface." The 17
            // historical successful re-deliveries this section used to cite as evidence of safety
            // were ALL against an idle, already-started Steam — a fundamentally different
            // situation from landing mid-launch, and citing them as proof this was safe was wrong.
            //
            // Fix, corrected: WAIT for logon, and do nothing else. Steam takes it from there.
            //
            // Gated on `steamWasAlreadyUp`, NOT `startedSteamForGame` — see the comment where
            // `startedSteamForGame` is computed above. A warm-started prefix is already logged on
            // by now, so there is nothing new to wait for; only a genuinely fresh cold boot (Steam
            // not running at the moment this call checked, warm-start or no) needs this wait.
            if isGameLauncher, !steamWasAlreadyUp {
                _ = await waitForSteamLogon(in: bottle, timeout: 150)
            }

            // Hold the guard until Steam is confirmed up. If Steam was already running before this
            // call, `isSteamRunning()` is true on the very first check, so the guard clears almost
            // immediately — correct, since -applaunch on an already-running Steam is near-instant
            // and there's nothing more we can wait for (see clearLaunchGuard). On a cold boot, the
            // logon wait above already ran to completion first, so this only ever adds the usual
            // fast confirmation on top, not a second long wait.
            //
            // F11 (bug-sweep): the practical effect is that `lastLaunchFailure` structurally CANNOT
            // fire on this path when Steam is already running — which is the common case, since
            // this is "how nearly every game starts" per the comment above. A game that silently
            // fails to start (not installed, or the steam_api64 race the direct-exe branch's
            // comment above documents) reports nothing here.
            //
            // DO NOT fix this by polling for the launched game's own exe instead of Steam. The
            // resolved exe can be a DRM WRAPPER that unpacks a different process and exits — Peggle
            // launches as `Peggle.exe`, which unpacks `popcapgame1.exe` and quits (see "Peggle
            // SOLVED" in CLAUDE.md). Polling for `Peggle.exe` would report "didn't start" WHILE
            // PEGGLE IS RUNNING. A false failure on a working launch is worse than this silence.
            // There is no cheap, safe success signal for this path; documenting the gap is the fix.
            clearLaunchGuard(for: bottle) { await self.isSteamRunning() }
        }
    }

    /// True if a Steam *client* process is running in any bottle.
    ///
    /// The pattern must be `/steam\.exe` (leading FORWARD slash), not bare `steam\.exe`.
    /// Steam's webhelper processes carry `-steampath=C:\Program Files (x86)\Steam\steam.exe`
    /// in their argv, so a bare match also hits them — and those orphans survive for hours
    /// after Steam exits (see GAMING-STACK.md §10). That made `launchSteam` believe Steam was
    /// already up and short-circuit to `activateRunningGame()`, so the Launch button silently
    /// did nothing. The real client's argv[0] is a unix path (`…/winetemp-…/steam.exe`) which
    /// contains `/steam.exe`; the webhelper only ever has the Windows form `\steam.exe`.
    private func isSteamRunning() async -> Bool {
        guard let result = try? await Shell.run(
            URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", #"/steam\.exe"#]) else { return false }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Bring the already-running game/Steam window to the front (best effort).
    /// Focus an already-running Steam/game window. Returns FALSE if there was no such window to
    /// focus — which is the signal that a `steam.exe` process exists but has no GUI presence, i.e.
    /// a wedged prefix. See `launchSteam`.
    @discardableResult
    private func activateRunningGame() -> Bool {
        var activated = false
        for app in NSWorkspace.shared.runningApplications
        where app.localizedName == "wine" || app.localizedName == "Steam" {
            app.activate()
            activated = true
        }
        return activated
    }

    /// Shut a bottle's prefix down cleanly with `wineserver -k`, then sweep the stragglers.
    ///
    /// `wineserver -k` FIRST is not optional. Killing wineserver directly orphans its children —
    /// `services.exe`, `winedevice.exe`, `explorer.exe` survive for hours, accumulate across
    /// launches, and eventually wedge the prefix so no new Steam can start. That is exactly the
    /// failure this function exists to recover from, so it must not cause it.
    private func shutdownPrefix(for bottle: Bottle) async {
        guard let installation = installation(for: bottle) else { return }
        let env = Wine.environment(for: bottle, using: installation)
        let server = installation.loader.deletingLastPathComponent()
            .appendingPathComponent("wineserver")
        if FileManager.default.isExecutableFile(atPath: server.path) {
            _ = try? await Shell.run(server, arguments: ["-k"], environment: env)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        // SCOPED to this prefix. This used to be `pkill -f steam\.exe` (plus six more patterns),
        // which had two problems:
        //   1. NOT per-bottle. It killed Steam and Wine helpers in EVERY prefix, so shutting one
        //      bottle down would take out a game running in another — or in the separate online
        //      engine — despite the function being named `shutdownPrefix(for:)`.
        //   2. It matched COMMAND LINES, so any shell or script whose arguments merely mentioned
        //      one of those names was a kill target. Same class as the pgrep self-matches, but
        //      destructive instead of merely wrong.
        // `wineserver -k` above is the real mechanism and handles Wine's own services; this only
        // needs to catch stragglers, and now only ones demonstrably belonging to THIS prefix.
        let prefixPath = bottle.url.standardizedFileURL.path
        if let ps = try? await Shell.run(URL(fileURLWithPath: "/bin/ps"),
                                         arguments: ["-Ao", "pid=,command="]) {
            let pids = ps.stdout.split(separator: "\n").compactMap { line -> String? in
                guard line.contains(prefixPath) else { return nil }
                return line.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", maxSplits: 1).first.map(String.init)
            }
            if !pids.isEmpty {
                _ = try? await Shell.run(URL(fileURLWithPath: "/bin/kill"), arguments: ["-9"] + pids)
            }
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    /// Bottles whose post-game Steam reaper is already running, so a second Launch can't start two.
    private var reapingBottleIDs: Set<UUID> = []

    /// Shut down the Steam we started for a direct-exe game once that game exits.
    ///
    /// The direct-exe path starts Steam only as a DRM host for `steam_api64.dll`, with `-silent`
    /// so its window never steals focus from the game. Nothing then stopped it: after the game
    /// quit, a windowless Steam stayed resident indefinitely (measured 7h37m), and because
    /// `-silent` means "in the tray", the user could not quit it from Steam's own UI either.
    ///
    /// Deliberately does NOT trust a process-exit callback. Under Wine the loader can return while
    /// the title is still up, so this watches for the game to actually appear and actually go away.
    /// If the game never appears at all, Steam is still reaped — a headless Steam left over from a
    /// game that failed to start is the exact problem being fixed.
    /// Seconds Steam is left alive after the game exits, so Steam Cloud can upload saves.
    /// Generous on purpose: the cost of waiting is a background process for a few more seconds;
    /// the cost of being too quick is someone's lost progress.
    private var cloudSyncGrace: Int { 25 }

    private func reapSteamAfterGame(in bottle: Bottle, weStartedSteam: Bool) {
        guard weStartedSteam, !reapingBottleIDs.contains(bottle.id) else { return }
        reapingBottleIDs.insert(bottle.id)
        Task {
            defer { reapingBottleIDs.remove(bottle.id) }

            // Phase 1 — wait for the game to show up (cold starts behind a shader cache are slow).
            var appeared = false
            for _ in 0..<60 {                                  // up to 5 min
                if await isAnyGameRunning() { appeared = true; break }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            // Phase 2 — wait for it to be gone, and stay gone. `isAnyGameRunning` is global, not
            // per-prefix, so a game launched in ANY bottle keeps this waiting: conservative on
            // purpose, since the failure mode of reaping too early is killing someone's session.
            //
            // F7 (bug-sweep): this loop had no ceiling. A game running indefinitely in an unrelated
            // bottle held it open forever, and because the whole Task never returned, the `defer`
            // above never ran either — `reapingBottleIDs` for THIS bottle stayed set for the rest of
            // the session, silently. Capped generously (an hour) so a genuinely long session
            // elsewhere isn't cut short, but the task now always finishes one way or another.
            if appeared {
                var clearStreak = 0
                var elapsed = 0
                let giveUpAfter = 3600                          // 1h — see comment above
                while clearStreak < 3 && elapsed < giveUpAfter { // ~15 s of quiet before believing it
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    elapsed += 5
                    clearStreak = await isAnyGameRunning() ? 0 : clearStreak + 1
                }
                guard clearStreak >= 3 else {
                    NSLog("Decanter: gave up reaping Steam for \(bottle.name) after "
                          + "\(giveUpAfter / 60) min — another game was still reported running "
                          + "elsewhere. Steam was left open rather than risk killing it.")
                    return
                }
            }

            // Phase 3 — LET STEAM SAVE YOUR PROGRESS BEFORE KILLING IT.
            //
            // Steam Cloud uploads a game's saves when the game exits, and `quitSteam` ends with
            // `wineserver -k`, which is not a polite request — it takes the whole prefix down. Kill
            // Steam too early and the sync is simply lost, silently, which is far worse than
            // leaving Steam running. Steam is still up throughout this wait, which is what makes
            // the sync possible at all.
            if appeared {
                try? await Task.sleep(nanoseconds: UInt64(cloudSyncGrace) * 1_000_000_000)
            }

            // Phase 4 — if the user has meanwhile started using Steam directly, leave it alone.
            guard launchingBottleIDs.isEmpty else { return }
            await quitSteam(in: bottle)
        }
    }

    /// Remove Steam's auto-start entry from the prefix's `Run` key.
    ///
    /// Steam writes itself into `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` — as
    /// `steam.exe -silent`, its "run Steam when my computer starts" setting, which is on by
    /// default. In a Wine prefix that setting is actively harmful: there is no boot, so it fires
    /// whenever *anything* brings the prefix up, and it brings Steam back **windowless**. Found by
    /// accident here — a bare `wine wineboot` started Steam with no other prompting.
    ///
    /// Without this, quitting Steam is temporary: the next launch of any program in the bottle
    /// silently resurrects it, which is the other half of "Steam reopens every time I quit it".
    /// Run BEFORE the shutdown, while the prefix is already up, so this doesn't have to start one.
    /// Steam rewrites the value whenever it runs, so this is re-applied on every quit by design.
    private func disableSteamAutoStart(in bottle: Bottle) async {
        guard let installation = installation(for: bottle) else { return }
        _ = try? await Shell.run(
            installation.loader,
            arguments: ["reg", "delete", #"HKCU\Software\Microsoft\Windows\CurrentVersion\Run"#,
                        "/v", "Steam", "/f"],
            environment: Wine.environment(for: bottle, using: installation))
    }

    /// Stop Steam and everything else running in this bottle.
    ///
    /// Decanter could start Steam but never stop it, and on a direct-exe bottle it starts Steam
    /// with `-silent` — straight to the tray, no window — then leaves it running after the game
    /// exits. Measured on 2026-08-02: one such steam.exe had been resident for 7h37m across four
    /// attempts to quit it. From tray mode, closing Steam's window returns it to the tray instead
    /// of exiting, so the client stays up and respawns its webhelper UI; the user sees "Steam
    /// reopens every time I quit it" and has no way to win, because the app's only shutdown path
    /// was a side effect of pressing Launch on a *plain* Steam bottle — which a game bottle never
    /// reaches (`isGameLauncher` skips that branch).
    ///
    /// Retries once: `wineserver -k` is asynchronous and the straggler sweep can run before every
    // MARK: Shared-prefix awareness (bug-sweep F1/F2/F8)
    //
    // Several bottles can point at the SAME WINEPREFIX (Steam, Sekiro, JJBA and Peggle all share
    // `Steam-Wine11` here), which several parts of the app used to treat as though each bottle were
    // isolated. `PrefixSharing` is the one place that answers "which bottles share this prefix";
    // these are thin wrappers so views never re-derive the answer themselves — the same discipline
    // as `resolvedGame`, and for the same reason: a second opinion about shared state is how the
    // picker and the launcher resolver drifted apart earlier in this project.

    /// Every bottle sharing `bottle`'s prefix, `bottle` itself included.
    func bottlesSharingPrefix(with bottle: Bottle) -> [Bottle] { PrefixSharing.group(of: bottle, in: bottles) }

    /// The OTHER bottles sharing `bottle`'s prefix — what a confirmation dialog names.
    func otherBottlesSharingPrefix(with bottle: Bottle) -> [Bottle] { PrefixSharing.others(of: bottle, in: bottles) }

    /// Why "Quit Steam" must not proceed right now, or nil if it's safe to ask for confirmation.
    ///
    /// ⚠️ IMPRECISE BY NECESSITY — documented rather than hidden. This can only ask "is ANY game
    /// running anywhere" (`isAnyGameRunning`, itself flagged separately as inheriting a global,
    /// unscoped check) because nothing here — and no cheap macOS API — attributes a running process
    /// to the specific bottle/prefix that launched it. macOS has no `/proc`-equivalent for reading
    /// another process's environment (verified: `ps -Eww` does not expose it the way Linux's
    /// `/proc/PID/environ` does), so telling "a game in THIS prefix" from "a game in some other
    /// prefix entirely" would need new process-to-prefix attribution — real work belonging to that
    /// other fix, not this one.
    ///
    /// So this only engages when `bottle` actually shares its prefix with others: an isolated
    /// bottle (Half Sword, today) is unaffected, because `wineserver -k` there can only ever hit its
    /// OWN game, which the existing confirmation dialog already discloses. For a SHARED bottle it
    /// takes the safe direction — OVER-refuse (may block even when the live game belongs to some
    /// unrelated prefix) rather than under-refuse (silently kill a sibling bottle's game). The
    /// escape hatch is quitting Steam from the bottle that actually owns the running game, not a
    /// bypass added here.
    func quitSteamBlockReason(for bottle: Bottle) async -> String? {
        let siblings = otherBottlesSharingPrefix(with: bottle)
        guard !siblings.isEmpty else { return nil }
        // ⚠️ PREFIX-UNAWARE CHECK, READ THIS BEFORE TRUSTING THE RESULT. `isAnyGameRunning()` is
        // `ps -Ao comm=` over the WHOLE MACHINE — it cannot tell "something is running in a
        // sibling bottle sharing THIS prefix" from "something is running in a totally unrelated
        // bottle, or a different prefix entirely". Concrete failure case: Half Sword (its own
        // separate prefix) is playing, Steam-Wine11 is completely idle — Quit Steam on the Peggle
        // bottle will still refuse here, citing Sekiro/JJBA/Steam as at risk when none of them are
        // doing anything. That is a known, accepted over-block, not a bug to silently rely on being
        // absent: see "quitSteamBlockReason over-blocks on unrelated-prefix activity" in
        // CLAUDE.md's spotted-not-fixed list. Real per-prefix attribution would mean mapping a
        // running PID to its WINEPREFIX — nothing in this codebase does that, and `ps` alone
        // cannot give it without walking each process's environment, which is exactly the kind of
        // attribution this project has been burned by guessing at before (comm-path splitting, the
        // systray sweep, the helper allowlist). Not attempted here; over-blocking is the safe
        // direction, so the imprecision is left in rather than built around.
        guard await isAnyGameRunning() else { return nil }
        let names = siblings.map(\.name).joined(separator: ", ")
        return "This prefix is also used by \(names). A game appears to be running somewhere — "
             + "quitting Steam here could close it. Quit Steam from the bottle that's actually "
             + "playing it instead."
    }

    /// process has gone. Reports whether Steam is actually gone rather than assuming.
    @discardableResult
    func quitSteam(in bottle: Bottle) async -> Bool {
        await disableSteamAutoStart(in: bottle)
        await shutdownPrefix(for: bottle)
        if await isSteamRunning() { await shutdownPrefix(for: bottle) }
        let stopped = await !isSteamRunning()
        // The menu-bar icon outlives Steam; clear it now that nothing is running.
        if stopped { reapOrphanedSystray() }
        return stopped
    }

    /// Launch a long-lived program without popping a console sheet. Used for games/Steam, where
    /// the user just wants the app to open — not a log window.
    private func launchQuietly(bottle: Bottle, arguments: [String],
                               extraEnvironment: [String: String] = [:]) {
        guard let installation = installation(for: bottle) else { return }
        var env = Wine.environment(for: bottle, using: installation)
        for (k, v) in extraEnvironment { env[k] = v }
        _ = try? Shell.stream(installation.loader, arguments: arguments, environment: env,
                              onOutput: { _ in }, onExit: { _ in })
    }

    /// Remove Steam's macOS menu-bar (systray) icon by killing Wine's `explorer.exe`.
    ///
    /// Wine's `explorer.exe` bridges a Windows systray icon to an `NSStatusItem` in the menu bar.
    /// Killing explorer drops it; explorer does not respawn and Steam keeps running fine (verified).
    ///
    /// NOT done for game-launcher bottles. On those, `explorer.exe` is also the per-app virtual
    /// desktop that produces the borderless-fullscreen window, and GAMING-STACK.md §7 is explicit
    /// that killing it too early *prevents that window from ever being created*. The game's own
    /// launcher (`Scripts/sekiro/sekiro-launcher.sh`) handles this correctly — it waits for
    /// `sekiro.exe` to exist and only then sweeps. A blind 15s timer here raced that and broke
    /// fullscreen.
    ///
    /// CAVEAT: `pkill -f explorer.exe` is process-wide — Wine gives no way to scope it to one
    /// prefix from argv (the prefix lives in the env, not the command line). So this also kills
    /// explorer in *other* running bottles. That's why it's limited to the plain-Steam case,
    /// where the only cost is losing a tray icon.
    /// `SteamAppId`/`SteamGameId` for a direct-exe launch. Steam is not spawning the process, so
    /// `steam_api64.dll` has no other way to know which app it belongs to. Falls back to parsing
    /// `-applaunch <id>` out of the Steam arguments if the field is blank.
    /// Block until Steam reports a completed logon, or `timeout` seconds pass.
    ///
    /// Counts NEW "Logged On," lines rather than checking for any, because the log is cumulative:
    /// a client that logged on yesterday would otherwise look ready the instant it is launched.
    /// Returns true if a logon landed; a timeout still lets the caller proceed, since a slow login
    /// beats refusing to start.
    @discardableResult
    private func waitForSteamLogon(in bottle: Bottle, timeout: Int) async -> Bool {
        let log = bottle.driveC
            .appendingPathComponent("Program Files (x86)/Steam/logs/connection_log.txt")
        func logons() -> Int {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { return 0 }
            return text.components(separatedBy: "Logged On,").count - 1
        }
        let baseline = logons()
        for _ in 0..<(timeout / 2) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if logons() > baseline {
                // The client logs on slightly before it is ready to answer the game.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return true
            }
        }
        return false
    }

    /// Play stayed disabled — surfaces a launch that never produced anything, instead of the
    /// button quietly re-enabling with no explanation. F6 (bug-sweep).
    @Published var lastLaunchFailure: String?

    /// Release `launchingBottleIDs` as soon as `success` goes true, or after `ceiling` seconds,
    /// whichever comes first — instead of always waiting out a flat duration regardless of outcome.
    /// Publishes `lastLaunchFailure` if the ceiling passes with nothing to show for it. F6
    /// (bug-sweep). Same poll-then-sleep shape as `waitForSteamLogon`, but checks BEFORE the first
    /// sleep too: if the evidence is already true (e.g. Steam was already running), the guard
    /// should clear immediately rather than waiting a pointless 2s.
    private func clearLaunchGuard(for bottle: Bottle, ceiling: Int = 30,
                                  success: @escaping () async -> Bool) {
        Task {
            var launched = await success()
            var waited = 0
            while !launched && waited < ceiling {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                waited += 2
                launched = await success()
            }
            launchingBottleIDs.remove(bottle.id)
            if !launched {
                lastLaunchFailure = "\(bottle.name) didn't start. Check that Steam is installed "
                    + "and logged in, then try again."
            }
        }
    }

    /// True if a process named `exeName` (matched case-insensitively on the final path component,
    /// same split rule as `isAnyGameRunning`) is currently running. F6's success signal for a
    /// direct-exe launch — the specific binary just started, not "some game or other."
    private func isProcessRunning(named exeName: String) async -> Bool {
        guard let result = try? await Shell.run(URL(fileURLWithPath: "/bin/ps"),
                                                 arguments: ["-Ao", "comm="]) else { return false }
        let target = exeName.lowercased()
        return result.stdout.split(separator: "\n").contains { line in
            let name = String(line.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "")
                .lowercased()
            return name == target
        }
    }

    private func steamAppEnvironment(for bottle: Bottle) -> [String: String] {
        var id = (bottle.settings.steamAppID ?? "").trimmingCharacters(in: .whitespaces)
        if id.isEmpty, let r = bottle.settings.steamArguments.range(of: "-applaunch ") {
            id = bottle.settings.steamArguments[r.upperBound...]
                .prefix(while: { $0.isNumber }).description
        }
        guard !id.isEmpty else { return [:] }
        return ["SteamAppId": id, "SteamGameId": id]
    }

    private func suppressWineSystray(isGameLauncher: Bool) {
        guard !isGameLauncher else { return }
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)     // let the window come up first
            for _ in 0..<12 {                                       // then sweep ~48s for the tray icon
                _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/pkill"),
                                         arguments: ["-f", "explorer.exe"])
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// Remove a Steam menu-bar icon that OUTLIVES Steam itself.
    ///
    /// `suppressWineSystray` only sweeps for ~48s after a launch, so it cannot help here: when
    /// Steam is quit later, Wine's `explorer.exe` survives (it is not a child of steam.exe) and
    /// keeps its `NSStatusItem` in the menu bar indefinitely — a stale icon for a Steam that is
    /// gone. Killing explorer is safe: game windows are owned by `winemac.drv`, not explorer, and
    /// explorer does not respawn.
    ///
    /// Only fires when NOTHING is running in any bottle, so it can never kill the per-app virtual
    /// desktop a running game depends on.
    func reapOrphanedSystray() {
        Task {
            guard await !isSteamRunning(), await !isAnyGameRunning() else { return }
            _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/pkill"),
                                     arguments: ["-f", "explorer.exe"])
        }
    }

    /// True if any Windows game process is running in a bottle (not Steam itself).
    /// Is a Windows game (as opposed to Wine's own helpers) currently running?
    ///
    /// USES `comm=`, NOT `command=`. `command=` is the full argument list, so ANY process that
    /// merely mentions a .exe path — a shell running a script, a grep, an installer — was counted
    /// as a running game. That made the app refuse perfectly safe operations with "quit the game
    /// first" when nothing was running. `comm=` is the executable itself, which a shell cannot
    /// spoof: it reads `/bin/zsh`, never `something.exe`.
    ///
    /// Wine's own service processes are excluded by name; they run constantly in any live prefix
    /// and are not games.
    private func isAnyGameRunning() async -> Bool {
        guard let result = try? await Shell.run(URL(fileURLWithPath: "/bin/ps"),
                                                arguments: ["-Ao", "comm="]) else { return false }
        let helpers: Set<String> = ["steam.exe", "explorer.exe", "services.exe", "winedevice.exe",
                                    "svchost.exe", "rpcss.exe", "plugplay.exe", "steamwebhelper.exe",
                                    "conhost.exe", "wineboot.exe", "start.exe", "tabtip.exe",
                                    "steamsysinfo.exe", "steamerrorreporter64.exe",
                                    // Observed running with Steam alone and NOT previously listed,
                                    // so a Steam with no game counted as "a game is running" —
                                    // which gates the post-game reaper, the engine switch and the
                                    // systray sweep. Same allowlist bug as the Windows-path split.
                                    "steamservice.exe", "steamerrorreporter.exe",
                                    "gameoverlayui.exe", "gameoverlayui64.exe",
                                    "winemenubuilder.exe", "wineconsole.exe", "rundll32.exe"]
        // SPLIT ON BOTH SEPARATORS. Wine reports `comm` as a WINDOWS path —
        // `C:\windows\system32\services.exe` — so splitting on "/" alone leaves the whole string,
        // the allowlist above never matches, and every Wine helper counts as a running game.
        // Verified live: 6 of 7 helpers misclassified, only the bare `start.exe` matched.
        //
        // That made this return true for hours after any Wine use (services/winedevice/plugplay
        // outlive their prefix), which silently disabled everything gated on it: the stale
        // menu-bar sweep never ran, and the engine switch always refused with "Quit Steam and any
        // running game first".
        return result.stdout.split(separator: "\n").contains { line in
            let name = String(line.split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .last ?? "").lowercased()
            return name.hasSuffix(".exe") && !helpers.contains(name)
        }
    }

    // MARK: Console plumbing

    /// Internal rather than private: menu commands have nowhere inline to show a result, so they
    /// report through this. Keeping it private is what left ⇧⌘R and Import CrossOver silent.
    @discardableResult
    func openConsole(title: String) -> TaskConsole {
        let console = TaskConsole(title: title)
        activeConsole = console
        return console
    }

    /// Stream a single long-lived Wine process into a fresh console.
    private func launch(title: String, bottle: Bottle, arguments: [String]) {
        guard let installation = installation(for: bottle) else {
            let console = openConsole(title: title)
            console.append("No Wine installation available. Add one in Setup.")
            console.finish()
            return
        }
        let env = Wine.environment(for: bottle, using: installation)
        let console = openConsole(title: title)
        console.append("$ wine \(arguments.joined(separator: " "))")
        console.handle = try? Shell.stream(
            installation.loader,
            arguments: arguments,
            environment: env,
            onOutput: { console.append($0) },
            onExit: { code in console.finish(code) }
        )
    }

    // MARK: Persistence

    /// Set when `loadBottles` had to salvage — i.e. `bottles.json` did not decode as a whole and
    /// at least one entry was dropped rather than merely reordered. nil the rest of the time.
    ///
    /// F3 (bug-sweep, 2026-08-22): this recovery path existed and worked, but said so only via
    /// `NSLog` — invisible to anyone not attached to Console.app. Every one of the 5 times this has
    /// fired on this machine to date dropped only test fixtures, never a real bottle, so there is
    /// no live damage this is recovering FROM here — but the failure mode is real (see the doc
    /// comment on `loadBottles`: a single unknown-shape entry used to drop the WHOLE list, and the
    /// very next save would have overwritten the original file with the empty result). The banner
    /// is for the case that has not happened yet on this machine, not evidence that it has.
    @Published var bottleSalvageWarning: String?

    /// Load the bottle index, surviving a single corrupt or out-of-date entry.
    ///
    /// The naive version — decode `[Bottle]` and silently give up — turns a recoverable problem
    /// into permanent data loss. Decoding is all-or-nothing, so ONE bottle carrying an unknown
    /// shape drops the whole list; `bottles` stays empty; the app shows first-run setup as though
    /// nothing were installed; and then the next `saveBottles()` (creating a bottle, or changing
    /// any setting) writes that empty array straight over the file. The user's bottles are gone.
    ///
    /// That very nearly happened on 2026-07-27, when adding a non-optional property made every
    /// previously-saved bottle undecodable.
    ///
    /// So: try the whole array, and on failure fall back to decoding entry by entry, keeping
    /// whatever survives — and back the original file up untouched before anything can overwrite
    /// it.
    private func loadBottles() {
        guard let data = try? Data(contentsOf: Paths.bottlesIndex) else { return }
        let decoder = JSONDecoder()

        if let decoded = try? decoder.decode([Bottle].self, from: data) {
            bottles = decoded
            selectedBottleID = bottles.first?.id
            return
        }

        // Preserve the file BEFORE any save can clobber it. This is the only copy of the user's
        // bottle list, and it is still intact on disk at this point.
        let backup = Paths.appSupport
            .appendingPathComponent("bottles.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: backup)

        // Per-entry salvage: re-encode each element on its own and decode it in isolation.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return }
        var salvaged: [Bottle] = []
        for element in raw {
            guard let itemData = try? JSONSerialization.data(withJSONObject: element),
                  let bottle = try? decoder.decode(Bottle.self, from: itemData) else { continue }
            salvaged.append(bottle)
        }
        bottles = salvaged
        selectedBottleID = bottles.first?.id
        let dropped = raw.count - salvaged.count
        NSLog("Decanter: bottles.json partially unreadable — salvaged \(salvaged.count) of \(raw.count). Original saved to \(backup.lastPathComponent)")
        // User-visible counterpart to the NSLog above — that line is invisible to anyone not
        // attached to Console.app, which is how this went unnoticed as a gap rather than a bug:
        // the mechanism worked, nobody could see it working. Names the backup file explicitly so
        // whoever sees this (the user, or an AI helper following DEBUGGING-GUIDE.md) can find and
        // inspect exactly what didn't make it, rather than being told only a count.
        //
        // ⚠️ MUST BE DEFERRED TO THE NEXT RUN LOOP TICK, not set synchronously here. `loadBottles`
        // runs inside `AppModel.init()`, which completes BEFORE SwiftUI ever constructs
        // `ContentView` — so setting the property directly makes `bottleSalvageWarning` already
        // `true` on ContentView's very FIRST render. `.alert(isPresented:)` needs an OBSERVED
        // false→true transition while the view is live; a binding that starts true never fires
        // it. REPRODUCED LIVE: injected a malformed entry, confirmed via the corrupt-*.json
        // timestamp and the in-memory bottle count that salvage genuinely ran — and no alert ever
        // appeared. `DispatchQueue.main.async` pushes the write to the tick after `init()`
        // returns, by which point ContentView exists and is observing, so the transition is real.
        if dropped > 0 {
            let message = "\(dropped) bottle\(dropped == 1 ? "" : "s") couldn't be read "
                + "and \(dropped == 1 ? "was" : "were") skipped. Nothing was deleted — the original "
                + "file was saved as \(backup.lastPathComponent) in "
                + "~/Library/Application Support/Decanter before anything was changed."
            DispatchQueue.main.async { self.bottleSalvageWarning = message }
        }
    }

    /// Persist the bottle index atomically.
    ///
    /// `.atomic` writes to a temporary file and renames it into place, so the index is either the
    /// old contents or the new ones and never a half-written mixture. The plain `write(to:)` this
    /// replaced could leave a truncated file if the app was force-quit, crashed, or hit a full
    /// disk mid-write — producing exactly the corruption `loadBottles` now has to salvage.
    ///
    /// Failures are logged rather than swallowed: silently not saving looks identical to saving,
    /// and the user only discovers it after losing work.
    private func saveBottles() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(bottles)
            try data.write(to: Paths.bottlesIndex, options: .atomic)
        } catch {
            NSLog("Decanter: FAILED to save bottles.json — \(error.localizedDescription)")
        }
    }

    private func persistExtraDirectories() {
        let paths = extraWineDirectories.map(\.path)
        UserDefaults.standard.set(paths, forKey: Keys.extraDirectories)
    }

    private func loadExtraDirectories() {
        let paths = UserDefaults.standard.stringArray(forKey: Keys.extraDirectories) ?? []
        extraWineDirectories = paths.map { URL(fileURLWithPath: $0) }
    }
}
