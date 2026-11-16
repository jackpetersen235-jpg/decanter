import Foundation

/// The settings a game started by Steam (`steam.exe -applaunch`) takes from the RUNNING Steam's
/// environment rather than from its own bottle — see the config note in
/// `BottleSettings.derivedEnvironment`.
///
/// Selecting a game in the sidebar warm-starts Steam at once, so a setting changed after that
/// (MetalFX, a HUD, thread sync) never reached the game: it ran with whatever Steam was started
/// with, often another bottle's settings, and nothing said so. Play now compares the two and
/// restarts Steam when they differ (`AppModel.launchSteam`).
enum SteamInheritedSettings {
    /// The values a game with `settings` should get from Steam's environment.
    static func expected(for settings: BottleSettings) -> [String: String] {
        var env = settings.derivedEnvironment
        env["WINEDEBUG"] = settings.wineDebug
        return env
    }

    /// The environment keys that matter to a game with `settings`. Graphics-specific keys only for
    /// its own graphics (a DXVK HUD means nothing to a DXMT game), and never incidental ones such as
    /// the per-bottle shader cache folder, which would restart Steam for no visible difference.
    static func keys(for settings: BottleSettings) -> [String] {
        var keys = ["WINEMSYNC", "WINEESYNC", "MTL_HUD_ENABLED", "ROSETTA_ADVERTISE_AVX", "WINEDEBUG"]
        switch settings.graphics {
        case .dxmt: keys += ["DXMT_METALFX_SPATIAL_SWAPCHAIN", "DXMT_CONFIG"]
        case .dxvk: keys += ["DXVK_HUD"]
        case .d3dmetal: keys += ["D3DM_ENABLE_METALFX"]
        case .wined3d: break
        }
        return keys + settings.environment.keys.sorted()
    }

    /// Readable names of the settings that differ between the game's bottle and the running Steam,
    /// in the order of `keys(for:)`, each named once. Empty when Steam would give the game exactly
    /// its own settings.
    static func differing(game settings: BottleSettings, steamEnvironment steam: [String: String]) -> [String] {
        let wanted = expected(for: settings)
        var names: [String] = []
        for key in keys(for: settings) where wanted[key] != steam[key] {
            let name = readableName[key] ?? key
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// DXMT_CONFIG carries the MetalFX scale (the rest of it is fixed), so it reads as MetalFX too.
    private static let readableName: [String: String] = [
        "WINEMSYNC": "Thread sync", "WINEESYNC": "Thread sync",
        "MTL_HUD_ENABLED": "Metal performance HUD", "ROSETTA_ADVERTISE_AVX": "Advertise AVX",
        "WINEDEBUG": "Verbose Wine logging", "DXMT_METALFX_SPATIAL_SWAPCHAIN": "MetalFX upscaling",
        "DXMT_CONFIG": "MetalFX upscaling", "D3DM_ENABLE_METALFX": "MetalFX upscaling",
        "DXVK_HUD": "DXVK HUD",
    ]
}
