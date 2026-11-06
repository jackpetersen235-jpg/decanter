import Foundation

/// Short, stable codes on user-visible failures, so a customer can say "it stopped with
/// DEC-E04" instead of only "it failed." Part of Phase 4 of the pre-release debug plan —
/// docs/COMMERCIAL-READINESS.md's point about first-run failures being the ones that generate every
/// support email, because each one produces a customer who paid and got nothing, with no
/// explanation of which step it was.
///
/// Numbered in the order a first run hits them (E01–E05, one per `runGuidedSetup`/`SetupWizard`
/// step — the two independently implement the same steps, per F15's doc comment, so BOTH surface
/// the same code for the same step rather than drifting into their own numbering). E06–E08 are
/// runtime failures that can happen any time after setup, not during it.
enum FailureCode: String {
    case rosetta = "DEC-E01"        // Rosetta 2 install failed or was declined
    case engineInstall = "DEC-E02"  // engine download/unpack/msync-graft failed
    case engineMissing = "DEC-E03"  // no usable engine even after installation ran
    case bottleCreate = "DEC-E04"   // prefix creation failed
    case steamInstall = "DEC-E05"   // Steam install into the bottle failed
    case launch = "DEC-E06"         // a game/Steam launch didn't produce anything
    case save = "DEC-E07"           // bottles.json failed to write
    case salvage = "DEC-E08"        // bottles.json was unreadable and had to be reset
    case quit = "DEC-E09"           // Steam did not fully shut down after quitSteam
    case unsupportedMac = "DEC-E10" // an Intel Mac — the engine and DXMT need Apple silicon

    /// Prepends the code to a message — the one place this formatting is decided, so a grep for
    /// "DEC-E" across every failure site (or a diagnostics export) finds the same shape everywhere.
    func tag(_ message: String) -> String { "[\(rawValue)] \(message)" }
}
