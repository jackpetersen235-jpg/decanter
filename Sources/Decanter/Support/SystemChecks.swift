import Foundation

/// Host-machine capability checks. Gaming with a Wine translation layer on Apple
/// Silicon needs Rosetta 2 (to run the x86-64 Wine build + x86 Windows games).
enum SystemChecks {
    /// Rosetta 2 leaves this runtime behind once installed.
    static var isRosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// The command a user can run to install Rosetta. It prompts for admin rights,
    /// so we surface it rather than silently attempting it.
    static let rosettaInstallCommand = "softwareupdate --install-rosetta --agree-to-license"
}
