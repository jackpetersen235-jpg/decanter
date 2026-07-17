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
    /// Apple's Game Porting Toolkit path: DirectX 11/12 → Metal directly.
    case d3dmetal
    /// DXVK: DirectX 9/10/11 → Vulkan → MoltenVK → Metal.
    case dxvk
    /// Wine's built-in OpenGL-based renderer. Most compatible, slowest.
    case wined3d

    var id: String { rawValue }

    var label: String {
        switch self {
        case .d3dmetal: return "D3DMetal (Game Porting Toolkit)"
        case .dxvk:     return "DXVK (Vulkan)"
        case .wined3d:  return "WineD3D (built-in)"
        }
    }

    var detail: String {
        switch self {
        case .d3dmetal: return "DirectX 11/12 → Metal. Best performance for modern titles; needs a GPTk-based Wine build."
        case .dxvk:     return "DirectX 9–11 → Vulkan → Metal. Applied per-game (not to the launcher UI, which must stay on the built-in renderer)."
        case .wined3d:  return "DirectX → OpenGL. Most compatible fallback, lowest performance."
        }
    }
}

/// Everything that distinguishes one bottle from another. Serialized into the bottle index.
struct BottleSettings: Codable, Equatable {
    var windowsVersion: WindowsVersion = .win10
    var syncMode: SyncMode = .msync
    var graphics: GraphicsBackend = .d3dmetal

    var metalHUD: Bool = false        // MTL_HUD_ENABLED — Metal performance overlay
    var metalFX: Bool = false         // D3DM_ENABLE_METALFX — MetalFX upscaling
    var dxvkHUD: Bool = false         // DXVK_HUD — DXVK's own overlay
    var advertiseAVX: Bool = true     // ROSETTA_ADVERTISE_AVX — several GPTk games require AVX
    var retinaMode: Bool = false      // HiDPI rendering inside the prefix
    var dpi: Int = 96                 // LogPixels
    var verboseLogging: Bool = false  // WINEDEBUG toggle
    var esyncFileLimit: Bool = true   // raise RLIMIT_NOFILE-style behaviour hint

    /// Extra environment variables the user wants layered on for launches.
    var environment: [String: String] = [:]

    /// Optional default launch arguments passed to Steam.
    var steamArguments: String = "-no-cef-sandbox -noverifyfiles"

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
