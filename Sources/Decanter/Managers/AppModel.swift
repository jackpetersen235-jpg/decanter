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
        // Headless online-play setup, so the isolation can be verified without the GUI:
        //   Decanter.app/Contents/MacOS/Decanter --setup-online
        if CommandLine.arguments.contains("--setup-online") {
            Task {
                let console = TaskConsole(title: "online")
                let id = await setUpOnlinePlay(console: console)
                let bottle = bottles.first { $0.id == id }
                FileHandle.standardError.write("""
                    online bottle: \(bottle?.name ?? "FAILED")
                    prefix:        \(bottle?.url.path ?? "-")
                    engine:        \(bottle?.wineBinDirectory?.path ?? "-")

                    """.data(using: .utf8)!)
                exit(id == nil ? 1 : 0)
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
    func installation(for bottle: Bottle) -> WineInstallation? {
        if let dir = bottle.wineBinDirectory,
           let match = installations.first(where: { $0.binDirectory == dir }) {
            return match
        }
        return defaultInstallation
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
        guard code == 0 else { return nil }
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

    /// The discovered installation backing the online engine, if it exists.
    var onlineInstallation: WineInstallation? {
        installations.first {
            $0.binDirectory.standardizedFileURL == Paths.onlineEngineBin.standardizedFileURL
        }
    }

    /// Any bottle already running on the online engine.
    var onlineBottles: [Bottle] {
        bottles.filter {
            $0.wineBinDirectory?.standardizedFileURL == Paths.onlineEngineBin.standardizedFileURL
        }
    }

    /// Build the whole isolated online setup: cloned engine, fresh prefix, Steam.
    ///
    /// Deliberately does NOT reuse `createBottleForSetup`, which binds to `defaultInstallation` —
    /// that would silently attach the online bottle to the single-player engine and defeat the
    /// isolation this whole feature exists for.
    @discardableResult
    func setUpOnlinePlay(name: String = "Online", console: TaskConsole? = nil) async -> Bottle.ID? {
        guard await cloneEngineForOnline(console: console) else { return nil }
        guard let installation = onlineInstallation else {
            console?.append("Online engine did not appear in discovery — cannot continue.")
            return nil
        }
        if let existing = onlineBottles.first {
            console?.append("Online bottle already exists: \(existing.name)")
            return existing.id
        }

        console?.append("Creating an isolated prefix…")
        let (bottle, _) = makeBottle(name: name, installation: installation)
        bottles.append(bottle)
        selectedBottleID = bottle.id
        saveBottles()

        let boot = console ?? TaskConsole(title: "online setup")
        let code: Int32 = await withCheckedContinuation { continuation in
            let handle = Wine.bootPrefix(bottle, using: installation, console: boot) { continuation.resume(returning: $0) }
            if handle == nil { continuation.resume(returning: -1) }
        }
        guard code == 0 else { console?.append("Prefix creation failed."); return nil }
        markInitialized(bottle.id)
        await applyRegistry(bottleID: bottle.id, console: boot, finish: false)
        console?.append("Prefix ready: \(bottle.url.lastPathComponent)")
        return bottle.id
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

            let key = #"HKCU\Software\Wine\AppDefaults\"# + game.exe + #"\DllOverrides"#
            for dll in ["d3d11", "dxgi", "d3d10core"] {
                let args = ["reg", "add", key, "/v", dll, "/t", "REG_SZ", "/d", "native,builtin", "/f"]
                _ = try? await Shell.run(installation.loader, arguments: args, environment: env)
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

    private func diskSafe(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
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
                if await !isSteamRunning() {
                    let steamArgs = [bottle.steamExecutable.path]
                        + Steam.launchArguments(from: "-silent -no-cef-sandbox -skipinitialbootstrap")
                    launchQuietly(bottle: bottle, arguments: steamArgs)
                    // Let the client come up and log on before the game asks it anything.
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                }
                launchQuietly(bottle: bottle, arguments: [direct], extraEnvironment: steamAppEnvironment(for: bottle))
                suppressWineSystray(isGameLauncher: true)
                Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    launchingBottleIDs.remove(bottle.id)
                }
                return
            }

            let args = [bottle.steamExecutable.path] + Steam.launchArguments(from: bottle.settings.steamArguments)
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
        for pattern in ["steam\\.exe", "steamwebhelper", "explorer\\.exe",
                        "services\\.exe", "winedevice", "rpcss\\.exe", "plugplay"] {
            _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/pkill"),
                                     arguments: ["-f", pattern])
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
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
    private func isAnyGameRunning() async -> Bool {
        guard let result = try? await Shell.run(URL(fileURLWithPath: "/bin/ps"),
                                                arguments: ["-Ao", "command="]) else { return false }
        return result.stdout.split(separator: "\n").contains { line in
            line.contains(".exe") && !line.contains("steam.exe") && !line.contains("explorer.exe")
                && !line.contains("services.exe") && !line.contains("winedevice.exe")
                && !line.contains("svchost.exe") && !line.contains("rpcss.exe")
                && !line.contains("plugplay.exe") && !line.contains("steamwebhelper.exe")
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

    private func loadBottles() {
        guard let data = try? Data(contentsOf: Paths.bottlesIndex) else { return }
        if let decoded = try? JSONDecoder().decode([Bottle].self, from: data) {
            bottles = decoded
            selectedBottleID = bottles.first?.id
        }
    }

    private func saveBottles() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(bottles) {
            try? data.write(to: Paths.bottlesIndex)
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
