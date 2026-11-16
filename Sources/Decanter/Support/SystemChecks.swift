import Foundation

/// Host-machine capability checks. Gaming with a Wine translation layer on Apple
/// Silicon needs Rosetta 2 (to run the x86-64 Wine build + x86 Windows games).
enum SystemChecks {
    /// Rosetta 2 leaves this runtime behind once installed.
    static var isRosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    /// Whether this Mac has an Apple silicon chip — asked of the HARDWARE, not of how Decanter was
    /// compiled. The old `#if arch(arm64)` would answer "Intel" for an Apple silicon Mac running
    /// Decanter under Rosetta, and nothing ever checked it anyway: an Intel Mac (the app is
    /// universal, so it opens there) went all the way to a Rosetta failure that could never pass.
    static var isAppleSilicon: Bool {
        var flag: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Absent entirely on Intel, so a failed lookup means no.
        guard sysctlbyname("hw.optional.arm64", &flag, &size, nil, 0) == 0 else { return false }
        return flag == 1
    }

    static let unsupportedMacMessage = "Decanter needs a Mac with Apple silicon (M1 or later). "
        + "This Mac has an Intel processor, which Decanter's Windows engine and graphics layer "
        + "don't support."

    /// DirectX 10/11 games run through DXMT, and the macOS side of the DXMT that engines ship
    /// (`winemetal.so`) is built for macOS 15 and later, so Sonoma can't load it. Decanter still
    /// opens there, and DXVK (MoltenVK, built for macOS 11) is the way left to run those games.
    static var supportsDXMT: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }

    static let olderMacOSMessage = "DirectX 10 and 11 games need macOS 15 (Sequoia) or later. "
        + "On this Mac, try switching a game's Graphics to DXVK in its Configuration."

    /// The command a user can run to install Rosetta. It prompts for admin rights,
    /// so we surface it rather than silently attempting it.
    static let rosettaInstallCommand = "softwareupdate --install-rosetta --agree-to-license"
}
