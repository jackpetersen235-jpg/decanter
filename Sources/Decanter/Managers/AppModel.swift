import Foundation
import SwiftUI
import AppKit

/// Central observable state + all user-facing actions. Views read from and call into this.
@MainActor
final class AppModel: ObservableObject {

    // MARK: Published state
    @Published var bottles: [Bottle] = []
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
        // Generate the .app launchers for every bottle that resolves to a game.
        //   Decanter.app/Contents/MacOS/Decanter --build-game-apps
        if CommandLine.arguments.contains("--build-game-apps") {
            Task {
                var out = "\n"
                for bottle in bottles {
                    guard let game = resolvedGame(for: bottle) else {
                        out += "  \(bottle.name.prefix(36)): no game (launcher bottle)\n"
                        continue
                    }
                    switch await buildGameApp(for: bottle) {
                    case .success(let url):
                        out += "  \(bottle.name.prefix(36)): \(url.lastPathComponent)\n"
                        out += "      game -> \(game.executable.lastPathComponent) (appid \(game.appID ?? "-"))\n"
                    case .failure(let e):
                        out += "  \(bottle.name.prefix(36)): FAILED — \(e.localizedDescription)\n"
                    }
                }
                FileHandle.standardError.write(out.data(using: .utf8)!)
                exit(0)
            }
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
        if profile == .online, !isOnlineEngineInstalled {
            guard await cloneEngineForOnline() else { return "Could not create the online engine." }
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
        if defaultInstallationID == nil { defaultInstallationID = installations.first?.id }
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
    @discardableResult
    func cloneEngineForOnline(console: TaskConsole? = nil) async -> Bool {
        if isOnlineEngineInstalled { console?.append("Online engine already present."); return true }
        guard FileManager.default.fileExists(atPath: Paths.wineEngineBin.appendingPathComponent("wine").path) else {
            console?.append("The main engine is not installed yet — run Setup Assistant first.")
            return false
        }
        console?.append("Cloning the engine (APFS clone — instant, uses almost no disk)…")
        try? FileManager.default.removeItem(at: Paths.onlineEngineRoot)
        let result = try? await Shell.run(
            URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-Rc", Paths.wineEngineRoot.path, Paths.onlineEngineRoot.path],
            environment: ProcessInfo.processInfo.environment)
        guard result?.exitCode == 0, isOnlineEngineInstalled else {
            console?.append("Clone failed: \(result?.stderr ?? "unknown error")")
            return false
        }
        rescanInstallations()
        console?.append("Online engine ready at \(Paths.onlineEngineRoot.lastPathComponent).")
        return true
    }

    /// Throw away the online engine and re-clone it from the offline one.
    ///
    /// This is what makes the isolation worth having: experiment freely on the online engine, and
    /// if it ends up broken, restore a known-good copy in about a second instead of re-downloading
    /// 480 MB. The offline engine is only ever read from, never written to.
    @discardableResult
    func resetOnlineEngine(console: TaskConsole? = nil) async -> Bool {
        let steamUp = await isSteamRunning()
        let gameUp = await isAnyGameRunning()
        if steamUp || gameUp {
            console?.append("Quit Steam and any running game first.")
            return false
        }
        console?.append("Removing the online engine…")
        try? FileManager.default.removeItem(at: Paths.onlineEngineRoot)
        rescanInstallations()
        return await cloneEngineForOnline(console: console)
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
            let exe = direct.hasPrefix("/")
                ? URL(fileURLWithPath: direct)
                : bottle.driveC.appendingPathComponent(direct)
            if fm.fileExists(atPath: exe.path) {
                return GameAppBuilder.Game(name: bottle.name,
                                           folder: exe.deletingLastPathComponent(),
                                           executable: exe,
                                           appID: appID)
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

    /// A bottle name not already taken, since the generated launcher's path is derived from it.
    ///
    /// Two bottles sharing a name means two bottles resolving to the SAME `~/Applications/x.app`,
    /// and `GameAppBuilder.build` deletes before it writes — so the second silently replaces the
    /// first's launcher. Numbering keeps the filename readable, which a bottle-id suffix would not.
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
        Task { await buildGameApp(for: bottle) }
        return bottle.id
    }

    /// Build (or rebuild) the bottle's launcher bundle in ~/Applications.
    @discardableResult
    func buildGameApp(for bottle: Bottle) async -> Result<URL, Error> {
        guard let installation = installation(for: bottle) else {
            return .failure(GameAppBuilder.BuildError.writeFailed("no Wine engine for this bottle"))
        }
        guard let game = resolvedGame(for: bottle) else {
            return .failure(GameAppBuilder.BuildError.noGame)
        }
        // Reuse the exact environment a Decanter-launched game gets, so the bundle and the app's
        // own Launch button cannot drift apart in behaviour.
        var env = Wine.environment(for: bottle, using: installation)
        for key in ProcessInfo.processInfo.environment.keys where env[key] == ProcessInfo.processInfo.environment[key] {
            env.removeValue(forKey: key)      // keep only what Decanter actually set
        }
        do {
            let url = try GameAppBuilder.build(
                game: game, bottle: bottle,
                wineBin: installation.binDirectory,
                wineLib: FileManager.default.fileExists(atPath: installation.libDirectory.path)
                    ? installation.libDirectory : nil,
                environment: env,
                steamExecutable: bottle.steamExecutable,
                skipInitialBootstrap: bottle.isSteamBootstrapped)
            return .success(url)
        } catch {
            return .failure(error)
        }
    }

    /// Open the generated launcher, building it first if it is missing.
    func launchGameApp(in bottle: Bottle) {
        Task {
            let app = GameAppBuilder.destination(for: bottle)
            // Rebuild when MISSING **or STALE**. Checking only for existence meant a launcher
            // written by an older build kept running forever: updating Decanter shipped the fix
            // but never reached the file that needed it, so Play went on using the old script.
            if !GameAppBuilder.isCurrent(for: bottle) {
                if case .failure = await buildGameApp(for: bottle) { return }
            }
            NSWorkspace.shared.open(app)
        }
    }

    /// True when this bottle has a game to make a launcher for.
    func hasGameApp(for bottle: Bottle) -> Bool {
        FileManager.default.fileExists(atPath: GameAppBuilder.destination(for: bottle).path)
    }

    /// Copy the bundled DXMT DLLs into each detected game and register the per-game DLL overrides.
    ///
    /// PER-GAME, NEVER PREFIX-WIDE. A prefix-wide d3d11/dxgi override routes Steam's own CEF UI
    /// through DXMT and black-screens the client (GAMING-STACK.md section 6), so the override is
    /// scoped to `AppDefaults\<exe>` and the DLLs are dropped beside the game rather than into
    /// system32.
    @discardableResult
    func installGraphicsDriver(in bottle: Bottle, console: TaskConsole? = nil) async -> Int {
        guard let src = Paths.bundledDXMT else {
            console?.append("This build of Decanter ships no DXMT payload.")
            return 0
        }
        guard let installation = installation(for: bottle) else {
            console?.append("No Wine installation available for this bottle.")
            return 0
        }
        let games = detectedSteamGames(in: bottle)
        if games.isEmpty { console?.append("No games found in this bottle's Steam library yet.") }

        let fm = FileManager.default
        let env = Wine.environment(for: bottle, using: installation)
        var done = 0
        for game in games {
            // Skip games that already have exactly these DLLs. This is what makes the call cheap
            // enough to run on every Steam launch, which in turn means a newly-installed game gets
            // the driver with no user action. Size comparison is sufficient: the patched DLLs are a
            // different size from both stock DXMT and whatever the game itself shipped.
            let already = Paths.dxmtDLLs.allSatisfy { dll in
                let a = (try? game.folder.appendingPathComponent(dll)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let b = (try? src.appendingPathComponent(dll)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
                return a == b
            }
            if already { continue }

            var copied = true
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
            guard copied else { continue }

            // CHECK the registry writes. Copying the DLLs is only half the job — without the
            // override Wine ignores them entirely and the game falls back to WineD3D, which is
            // precisely the slow path this feature exists to avoid. Discarding the result meant a
            // silent failure would still be reported as "installed", and the user would be left
            // wondering why a game that Decanter said was patched still ran badly.
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
        let stillReferenced = bottles.contains { $0.url.standardizedFileURL == bottle.url.standardizedFileURL }
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
        if bottles.contains(where: { $0.name == name && $0.url == prefix }) { return nil }
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
        if finish { console.finish() }
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
            let result = try await Shell.run(installation.loader,
                                             arguments: Steam.installArguments(installerPath: installer),
                                             environment: env)
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
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
                                 arguments: ["--install-rosetta", "--agree-to-license"])
        isRosettaInstalled = SystemChecks.isRosettaInstalled
        return isRosettaInstalled
    }

    /// Launch the Steam client already installed in the bottle.
    func launchSteam(in bottle: Bottle) {
        // A bottle with `-applaunch` launches a *game*: if Steam is already up, running
        // `steam.exe -applaunch <id>` just tells the running client to start the game, which is
        // exactly right — so we must NOT skip it. Only a plain Steam launcher should short-circuit.
        let isGameLauncher = bottle.settings.steamArguments.contains("-applaunch")
        Task {
            // Guard against a rapid double-click on the same bottle regardless of kind.
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
                Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    launchingBottleIDs.remove(bottle.id)
                }
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
            // Quiet: no console sheet pops over Decanter (which made the first click look like a
            // no-op). Steam just opens on its own.
            launchQuietly(bottle: bottle, arguments: args)
            suppressWineSystray(isGameLauncher: isGameLauncher)
            Task {
                // Hold the guard while Steam comes up, then let isSteamRunning take over.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                launchingBottleIDs.remove(bottle.id)
            }
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
            if appeared {
                var clearStreak = 0
                while clearStreak < 3 {                        // ~15 s of quiet before believing it
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    clearStreak = await isAnyGameRunning() ? 0 : clearStreak + 1
                }
            }

            // Phase 3 — if the user has meanwhile started using Steam directly, leave it alone.
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
                                    "steamsysinfo.exe", "steamerrorreporter64.exe"]
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

    @discardableResult
    private func openConsole(title: String) -> TaskConsole {
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
        NSLog("Decanter: bottles.json partially unreadable — salvaged \(salvaged.count) of \(raw.count). Original saved to \(backup.lastPathComponent)")
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
