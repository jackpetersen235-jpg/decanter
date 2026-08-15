import Foundation

/// The emulated Windows version reported to games/installers.
enum WindowsVersion: String, Codable, CaseIterable, Identifiable {
    case win11, win10, win81, win7

    var id: String { rawValue }

    var label: String {
        switch self {
        case .win11: return "Windows 11"
        case .win10: return "Windows 10"
        case .win81: return "Windows 8.1"
        case .win7:  return "Windows 7"
        }
    }

    /// Registry values written to HKLM\...\Windows NT\CurrentVersion.
    var registry: (currentVersion: String, build: String, productName: String) {
        switch self {
        case .win11: return ("10.0", "22000", "Microsoft Windows 11")
        case .win10: return ("10.0", "19045", "Microsoft Windows 10")
        case .win81: return ("6.3",  "9600",  "Microsoft Windows 8.1")
        case .win7:  return ("6.1",  "7601",  "Microsoft Windows 7")
        }
    }
}

/// Wine's thread-synchronization primitive. `msync` is the macOS-native path shipped
/// with CrossOver / Game Porting Toolkit builds and is fastest for games.
/// Which engine build a bottle runs on.
///
/// Both engines are independent copies of the same Wine tree, so a bottle can be switched between
/// them freely — the prefix, saves, Steam install and games are untouched by the choice. Isolation
/// is the point: the offline engine is heavily tuned for single-player performance and was
/// expensive to get right, so online experimentation must not be able to modify its files.
///
/// Created with `cp -Rc` (APFS clone), which shares disk blocks until a file is written: the second
/// engine cost 2 MB and one second, measured on a 719 MB tree.
enum EngineProfile: String, Codable, CaseIterable, Identifiable {
    /// The tuned single-player engine: DXMT graphics fixes, msync, MetalFX.
    case offline
    /// A separate copy used for online play, so networking changes cannot affect the above.
    case online
    /// A separate copy for old 32-bit titles, so experiments aimed at them cannot affect the above.
    case legacy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .offline: return "Offline (tuned for single-player)"
        case .online:  return "Online (multiplayer)"
        case .legacy:  return "Legacy (old 32-bit games)"
        }
    }

    /// The bare name, for use inside a sentence.
    ///
    /// `label` carries a parenthetical that reads well in a picker and badly anywhere else —
    /// "Could not create the Legacy (old 32-bit games) engine."
    var shortName: String {
        switch self {
        case .offline: return "Offline"
        case .online:  return "Online"
        case .legacy:  return "Legacy"
        }
    }

    var detail: String {
        switch self {
        case .offline: return "The engine your games are tuned on. Best framerate, no online changes."
        case .online:  return "A separate copy for playing with friends. Changes here can't affect offline."
        case .legacy:  return "A separate copy for pre-2010 games. Experiment freely — it can't affect the others."
        }
    }

    /// The `bin` directory this profile resolves to.
    var binDirectory: URL {
        switch self {
        case .offline: return Paths.wineEngineBin
        case .online:  return Paths.onlineEngineBin
        case .legacy:  return Paths.legacyEngineBin
        }
    }
}

enum SyncMode: String, Codable, CaseIterable, Identifiable {
    case msync, esync, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .msync: return "MSync (recommended)"
        case .esync: return "ESync"
        case .none:  return "Off"
        }
    }
}

/// How DirectX calls get translated to the Mac's Metal API.
enum GraphicsBackend: String, Codable, CaseIterable, Identifiable {
    /// DXMT: DirectX 11 → Metal, directly (1 hop). Best on Apple Silicon.
    /// Ships with WhiskyWine (Libraries/DXMT) and needs wine's `winemetal` driver.
    case dxmt
    /// Apple's Game Porting Toolkit path: DirectX 11/12 → Metal directly.
    case d3dmetal
    /// DXVK: DirectX 9/10/11 → Vulkan → MoltenVK → Metal (3 hops — slow here).
    case dxvk
    /// Wine's built-in OpenGL-based renderer. Most compatible, slowest.
    case wined3d

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dxmt:     return "DXMT (DirectX → Metal)"
        case .d3dmetal: return "D3DMetal (Game Porting Toolkit)"
        case .dxvk:     return "DXVK (Vulkan)"
        case .wined3d:  return "WineD3D (built-in)"
        }
    }

    var detail: String {
        switch self {
        case .dxmt:     return "DirectX 11 → Metal in one hop. Fastest option on Apple Silicon. Applied per-game: DXMT's DLLs sit beside the game .exe and are enabled via AppDefaults, so the launcher UI is untouched."
        case .d3dmetal: return "DirectX 11/12 → Metal. Best performance for modern titles; needs a GPTk-based Wine build."
        case .dxvk:     return "DirectX 9–11 → Vulkan → MoltenVK → Metal (3 hops). Much slower than DXMT here; prefer DXMT unless a game misbehaves."
        case .wined3d:  return "DirectX → OpenGL. Most compatible fallback, lowest performance."
        }
    }
}

/// Everything that distinguishes one bottle from another. Serialized into the bottle index.
struct BottleSettings: Codable, Equatable {
    var windowsVersion: WindowsVersion = .win10
    var syncMode: SyncMode = .msync
    // DXMT is the backend Decanter's shipped engine (WhiskyWine 11) provides — the right default
    // for a newly created bottle. CrossOver-imported bottles override this to .d3dmetal.
    var graphics: GraphicsBackend = .dxmt

    var metalHUD: Bool = false        // MTL_HUD_ENABLED — Metal performance overlay (small cost)
    var metalFX: Bool = false         // MetalFX upscaling

    /// MetalFX upscale factor. NOTE: MetalFX upscales *from the game's own render resolution*
    /// (input × factor = output). It does NOT reduce what the game renders — on its own it is a
    /// quality feature that costs an extra pass and buys zero frames. To gain performance you must
    /// ALSO lower the game's internal resolution and let MetalFX rebuild it to the display size.
    var metalFXFactor: Double = 2.0
    var dxvkHUD: Bool = false         // DXVK_HUD — DXVK's own overlay
    var advertiseAVX: Bool = true     // ROSETTA_ADVERTISE_AVX — several GPTk games require AVX

    /// Force the game's SOFTWARE renderer (old 2D DirectDraw/D3D7 titles).
    ///
    /// Counter-intuitive, and measured: Peggle Deluxe issues **3,567 draw calls per frame** — one
    /// 4-vertex quad per sprite, from a user-memory pointer. Each costs ~62,300 cycles through
    /// ddraw → wined3d → OpenGL (a native draw is 1,000–3,000), because wined3d must map a GL
    /// buffer per draw and the upstream fix for that needs `ARB_buffer_storage`, which requires
    /// GL 4.4 — while **Apple caps OpenGL at 4.1**. So the per-draw tax cannot be avoided on macOS.
    ///
    /// Rendering in software does more pixel work but presents ONE surface per frame instead of
    /// 3,567 draws, sidestepping the tax entirely. Measured on Peggle: **17.8 fps → 90.1 fps mean**
    /// (max 100.5, n=363 during real play).
    ///
    /// Applied per-executable, never prefix-wide — three bottles here share `Steam-Wine11`, and
    /// denying 3D to Sekiro would be catastrophic.
    var software2D: Bool = false

    var retinaMode: Bool = false      // HiDPI rendering inside the prefix
    var dpi: Int = 96                 // LogPixels
    var verboseLogging: Bool = false  // WINEDEBUG toggle
    var esyncFileLimit: Bool = true   // raise RLIMIT_NOFILE-style behaviour hint

    /// Extra environment variables the user wants layered on for launches.
    var environment: [String: String] = [:]

    /// Launch arguments passed to Steam.
    ///
    /// `-skipinitialbootstrap`: Steam normally re-execs itself for a startup update check, and
    /// **both** processes stay resident — Wine gives each one a Dock tile, so you get two "Steam"
    /// icons for one Steam. This skips that phase: 1 process, 1 tile. Verified to still log in and
    /// keep Steam's normal self-update path (it still resolves client-update hosts).
    ///
    /// Do **not** add `-silent` here: it starts Steam with no window, so "Launch Steam" appears
    /// to do nothing and the user has to click twice (the second click surfaces the already-
    /// running instance). `-silent` is only appropriate on a per-game bottle that also passes
    /// `-applaunch`, where Steam is just a DRM host and its UI is unwanted.
    var steamArguments: String = "-no-cef-sandbox -skipinitialbootstrap"

    /// Windows path of a game .exe to run DIRECTLY, instead of going through
    /// `steam.exe -applaunch`. Empty means "launch via Steam" (the normal path).
    ///
    /// Why this exists: some titles ship an anti-cheat shim as their Steam entry point
    /// (JJBA: All-Star Battle R launches `start_protected_game.exe`, which loads Easy
    /// Anti-Cheat). EAC does not work under Wine on macOS, so `-applaunch` cannot start
    /// those games at all. Running the real executable directly bypasses the shim and gets
    /// single-player working; online play is not possible either way.
    ///
    /// Steam still has to be RUNNING — `steam_api64.dll` talks to the live client — so the
    /// launcher starts Steam first and only then runs this. `SteamAppId` tells the API which
    /// app the process is, since Steam is not the one spawning it.
    /// OPTIONAL ON PURPOSE. `BottleSettings` uses synthesized `Codable`, and Swift's synthesized
    /// decoder FAILS on a missing key for a non-optional property even when it has a default —
    /// which means adding a plain `String` here makes every previously-saved bottle undecodable,
    /// the whole array fails, and Decanter shows the first-run setup screen with no bottles.
    /// That happened on 2026-07-27. Optional makes the decoder use decodeIfPresent instead.
    var directExecutable: String? = nil

    /// Which engine build this bottle runs on. OPTIONAL for exactly the reason above: every bottle
    /// saved before this property existed has no such key, and a non-optional would make the whole
    /// array fail to decode. `nil` means "offline", so existing bottles keep their behaviour.
    var engineProfile: EngineProfile? = nil

    /// Steam AppID, used to set SteamAppId/SteamGameId when `directExecutable` is used.
    var steamAppID: String? = nil

    /// Environment variables implied purely by these settings (no Wine paths — those are
    /// added by `Wine.environment(...)`).
    // MARK: - Codable

    /// Decode every field with `decodeIfPresent`, falling back to the property's default.
    ///
    /// ⚠️ THE REASON THIS EXISTS. Swift's *synthesized* decoder throws `keyNotFound` for a missing
    /// key on a non-optional property **even when that property has a default value**. So adding
    /// any new non-optional field silently makes every previously-saved bottle undecodable — on
    /// update, a user's bottles.json partially fails to load and Decanter salvages what it can.
    ///
    /// That is not hypothetical: adding `software2D` did exactly this here, and 3 of 4 bottles
    /// stopped decoding. The file was intact; the decoder was the problem. The old workaround was
    /// "make new fields Optional", which relies on every future author remembering. This does not.
    ///
    /// **Add new fields freely — just give them a default and decode them here.**
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)) .flatMap { $0 } ?? fallback
        }
        windowsVersion  = v(.windowsVersion, .win10)
        syncMode        = v(.syncMode, .msync)
        graphics        = v(.graphics, .dxmt)
        metalHUD        = v(.metalHUD, false)
        metalFX         = v(.metalFX, false)
        metalFXFactor   = v(.metalFXFactor, 2.0)
        dxvkHUD         = v(.dxvkHUD, false)
        advertiseAVX    = v(.advertiseAVX, true)
        software2D      = v(.software2D, false)
        retinaMode      = v(.retinaMode, false)
        dpi             = v(.dpi, 96)
        verboseLogging  = v(.verboseLogging, false)
        esyncFileLimit  = v(.esyncFileLimit, true)
        environment     = v(.environment, [:])
        steamArguments  = v(.steamArguments, "-no-cef-sandbox -skipinitialbootstrap")
        directExecutable = try? c.decodeIfPresent(String.self, forKey: .directExecutable)
        engineProfile    = try? c.decodeIfPresent(EngineProfile.self, forKey: .engineProfile)
        steamAppID       = try? c.decodeIfPresent(String.self, forKey: .steamAppID)
    }

    init() {}

    var derivedEnvironment: [String: String] {
        var env: [String: String] = [:]

        switch syncMode {
        case .msync:
            env["WINEMSYNC"] = "1"
            env["WINEESYNC"] = "1"
        case .esync:
            env["WINEMSYNC"] = "0"
            env["WINEESYNC"] = "1"
        case .none:
            env["WINEMSYNC"] = "0"
            env["WINEESYNC"] = "0"
        }

        switch graphics {
        case .dxmt:
            // No prefix-wide WINEDLLOVERRIDES: DXMT is scoped per-executable (AppDefaults +
            // DLLs beside the game .exe). A global override drags Steam's CEF UI through it,
            // which fails to make a GL context and renders the client as a black window.
            env["DXMT_SHADER_CACHE"] = "1"          // persistent; kills repeat shader stutter
            if metalFX {
                env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1"
            }
            // `ignoreMapFlagNoWait` matters more than it looks. A game launched via
            // `steam.exe -applaunch` inherits the environment of the ALREADY-RUNNING Steam — so
            // if Steam was started from Decanter, the game gets THIS config, not the tuned one in
            // a per-game launcher like Sekiro.app. Keeping the two in sync means either launch
            // order produces the same performance. (Diagnosed 2026-07-18: launching Sekiro while
            // a Decanter-started Steam was up produced load freezes + stutter for exactly this
            // reason.) Verified real DXMT key — see GAMING-STACK.md §5.
            var cfg = ["d3d11.preferredMaxFrameRate=60", "d3d11.ignoreMapFlagNoWait=True"]
            if metalFX {
                cfg.append("d3d11.metalSpatialUpscaleFactor=\(String(format: "%.1f", metalFXFactor))")
            }
            env["DXMT_CONFIG"] = cfg.joined(separator: ";")

        case .dxvk:
            // NOTE: no prefix-wide WINEDLLOVERRIDES here. A global override also routes the Steam
            // client's CEF/ANGLE UI through DXVK, which fails to create a GL context and renders
            // the client as a black window.
            //
            // ⚠️ This comment used to claim DXVK "is instead scoped per-executable via
            // HKCU\Software\Wine\AppDefaults\<game>.exe". **No such code ever existed** — a
            // description of an intention, left reading as a description of behaviour. Nothing
            // installed DXVK at all; `installGraphicsDriver` copied DXMT whatever was selected.
            // It now refuses with a reason, because the engine ships no `dxgi.dll` to pair with
            // DXVK's `d3d11.dll` and DXVK will not create a device without it.
            if dxvkHUD { env["DXVK_HUD"] = "fps,frametimes,gpuload" }
        case .d3dmetal:
            if metalFX { env["D3DM_ENABLE_METALFX"] = "1" }
        case .wined3d:
            env["WINEDLLOVERRIDES"] = "d3d9,d3d10core,d3d11,dxgi=b"
        }

        env["MTL_HUD_ENABLED"] = metalHUD ? "1" : "0"
        env["ROSETTA_ADVERTISE_AVX"] = advertiseAVX ? "1" : "0"

        // User overrides win.
        for (key, value) in environment { env[key] = value }
        return env
    }
}
