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

    /// What the update alert shows from a release's notes: the "What's new" section when there is
    /// one — the rest of a release page is download-by-hand steps, which the alert's own Install
    /// button replaces — as plain text, since an alert can't render Markdown. Cut at a whole line.
    static func summary(ofNotes notes: String, limit: Int = 600) -> String {
        let lines = notes.components(separatedBy: .newlines)
        let isHeading: (String) -> Bool = { $0.hasPrefix("#") }
        let whatsNew = lines.firstIndex {
            isHeading($0) && $0.lowercased().replacingOccurrences(of: "’", with: "'").contains("what's new")
        }
        let section = whatsNew.map { lines[($0 + 1)...].prefix { !isHeading($0) } } ?? lines[...]

        // One blank line at most between paragraphs, none at either end.
        let tidy = section.map(plainText).reduce(into: [String]()) { kept, line in
            if !(line.isEmpty && (kept.last?.isEmpty ?? true)) { kept.append(line) }
        }
        let kept = tidy.last?.isEmpty == true ? Array(tidy.dropLast()) : tidy

        let text = kept.joined(separator: "\n")
        guard text.count > limit else { return text }
        let ellipsis = "\n…"
        var used = 0
        let fitting = kept.prefix { line in
            used += line.count + 1
            return used - 1 <= limit - ellipsis.count
        }
        return fitting.joined(separator: "\n") + ellipsis
    }

    private static let markdownLink = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]*\)"#)

    /// One line of Markdown as plain text: links keep their words, bullets become "•", and heading
    /// marks, bold and code marks go.
    private static func plainText(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if let link = markdownLink {
            text = link.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                 withTemplate: "$1")
        }
        if text.hasPrefix("#") { text = String(text.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("- ") || text.hasPrefix("* ") { text = "• " + text.dropFirst(2) }
        return ["**", "__", "`"].reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
    }
}
