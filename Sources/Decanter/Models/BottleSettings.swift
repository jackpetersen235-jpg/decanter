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

    /// Environment variables implied purely by these settings (no Wine paths — those are
    /// added by `Wine.environment(...)`).
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
            // NOTE: deliberately no prefix-wide WINEDLLOVERRIDES here. A global override
            // also routes the Steam client's CEF/ANGLE UI through DXVK, which fails to
            // create a GL context and renders the client as a black window. DXVK is
            // instead scoped per-executable via HKCU\Software\Wine\AppDefaults\<game>.exe,
            // so only the game gets it and the launcher UI keeps Wine's built-in path.
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
