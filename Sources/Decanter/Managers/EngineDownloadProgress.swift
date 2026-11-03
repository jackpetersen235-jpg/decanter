import Foundation

/// One progress bar for the whole engine install.
///
/// The engine arrives as two downloads — the base bundle, then the msync overlay — and each used
/// to drive the setup wizard's bar from 0 to 100% by itself, so the bar filled, vanished while
/// unpacking, then started over (HIG: report advancement as accurately as possible). This maps
/// each part onto a single bar weighted by size, so it fills once and never moves backwards.
/// Kept out of `WineInstaller` so it can be tested without network or disk.
enum EngineDownloadProgress {
    enum Part { case base, overlay }

    /// Approximate sizes — they only weight the bar. The base matches
    /// `WineInstaller.approximateBytes`; the overlay is the rest of the "~480 MB in two parts".
    static let baseBytes: Double = 317_000_000
    static let overlayBytes: Double = 163_000_000

    /// `fraction` is one part's own progress (0…1); the result is progress through the whole install.
    static func overall(_ part: Part, _ fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        let baseShare = baseBytes / (baseBytes + overlayBytes)
        switch part {
        case .base:    return clamped * baseShare
        case .overlay: return baseShare + clamped * (1 - baseShare)
        }
    }
}
