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
    }

    /// The complete first-run automation, factored out of the wizard view so it (a) survives any
    /// view lifecycle and (b) is testable headlessly via `--run-setup`. Steps self-skip if done.
    func runGuidedSetup() async {
        isSettingUp = true
        defer { isSettingUp = false }

        guard await ensureRosetta() else { return }              // 1. Rosetta

        if defaultInstallation == nil {                          // 2. Engine
            await installEngine()
            rescanInstallations()
        }
        guard defaultInstallation != nil else { return }

        if bottles.isEmpty {                                     // 3. Bottle
            _ = await createBottleForSetup(name: "Games")
        }

        if let bottle = bottles.first, !bottle.isSteamInstalled { // 4. Steam
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

    private func enrichVersions() async {
        var updated = installations
        for index in updated.indices where updated[index].version == nil {
            updated[index].version = await Wine.version(of: updated[index])
        }
        installations = updated
    }

    func addWineDirectory(_ url: URL) {
        // Accept either a `bin` directory or a `wine` binary the user picked.
        let dir = url.lastPathComponent == "bin" ? url : url.deletingLastPathComponent()
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

    func deleteBottle(_ bottle: Bottle, removeFiles: Bool) {
        bottles.removeAll { $0.id == bottle.id }
        if selectedBottleID == bottle.id { selectedBottleID = bottles.first?.id }
        saveBottles()
        if removeFiles {
            try? FileManager.default.removeItem(at: bottle.url)
        }
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
        console.append("Downloading WhiskyWine 11.0 (~317 MB)…")
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
                activateRunningGame()
                return
            }
            launchingBottleIDs.insert(bottle.id)
            let args = [bottle.steamExecutable.path] + Steam.launchArguments(from: bottle.settings.steamArguments)
            // Quiet: no console sheet pops over Decanter (which made the first click look like a
            // no-op). Steam just opens on its own.
            launchQuietly(bottle: bottle, arguments: args)
            suppressWineSystray()
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
    private func activateRunningGame() {
        for app in NSWorkspace.shared.runningApplications
        where app.localizedName == "wine" || app.localizedName == "Steam" {
            app.activate()
        }
    }

    /// Launch a long-lived program without popping a console sheet. Used for games/Steam, where
    /// the user just wants the app to open — not a log window.
    private func launchQuietly(bottle: Bottle, arguments: [String]) {
        guard let installation = installation(for: bottle) else { return }
        let env = Wine.environment(for: bottle, using: installation)
        _ = try? Shell.stream(installation.loader, arguments: arguments, environment: env,
                              onOutput: { _ in }, onExit: { _ in })
    }

    /// Remove the macOS menu-bar tray icon Wine creates for Steam.
    ///
    /// Wine's `explorer.exe` bridges a Windows systray icon to an `NSStatusItem` in the menu bar.
    /// Killing explorer drops it; explorer does not respawn and Steam keeps running fine (verified).
    ///
    /// IMPORTANT: wait before the first kill. A game may run in a per-app Wine *virtual desktop*
    /// for fullscreen (that desktop is itself an `explorer.exe`); killing it before the game's
    /// window exists would prevent fullscreen. By the time we start (~15s) the window is up, so
    /// killing explorer only drops the unneeded systray bridge — the game window survives (owned
    /// by winemac.drv, not explorer). Verified with Sekiro's fullscreen setup.
    private func suppressWineSystray() {
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)     // let the window come up first
            for _ in 0..<12 {                                       // then sweep ~48s for the tray icon
                _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/pkill"),
                                         arguments: ["-f", "explorer.exe"])
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
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
