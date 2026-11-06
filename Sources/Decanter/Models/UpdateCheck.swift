import Foundation

/// What Decanter → Check for Updates needs from GitHub's "latest release" API, and whether that
/// release is newer than the running app. Pure, so it's testable without the network.
///
/// RELEASE RULE this depends on: every release bumps `CFBundleShortVersionString` in
/// `Scripts/make_app.sh` and is tagged `v<that version>` with the app zip attached. A rebuild
/// re-uploaded under the same tag is invisible to friends' apps.
enum UpdateCheck {

    struct Release: Equatable {
        let version: String
        let notes: String
        let zipURL: URL
    }

    /// Where the release information lives. `DECANTER_UPDATE_API` overrides it so the whole update
    /// flow can be exercised against a local fake release (a `file://` URL) instead of GitHub.
    static var latestReleaseAPI: URL {
        if let override = ProcessInfo.processInfo.environment["DECANTER_UPDATE_API"],
           let url = URL(string: override) { return url }
        return URL(string: "https://api.github.com/repos/jackpetersen235-jpg/decanter/releases/latest")!
    }

    static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }),
              let link = zip["browser_download_url"] as? String,
              let url = URL(string: link) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", zipURL: url)
    }

    /// Numeric, component by component, missing parts counting as zero: "1.10" > "1.9",
    /// "1.0.1" > "1.0", and "1.0.0" == "1.0".
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
