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

    /// The command a user can run to install Rosetta. It prompts for admin rights,
    /// so we surface it rather than silently attempting it.
    static let rosettaInstallCommand = "softwareupdate --install-rosetta --agree-to-license"
}
