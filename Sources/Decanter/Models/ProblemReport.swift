import Foundation

/// Help ▸ Report a Problem… — GitHub's bug form (`.github/ISSUE_TEMPLATE/bug_report.yml`), opened
/// with the version, the Mac and the `--verify` report already filled in, so nobody needs Terminal
/// to file a useful bug.
///
/// Nothing is sent from here: the browser shows the form and the person reads it before pressing
/// Create. But the issue will be PUBLIC, so the home folder — which names the person — becomes `~`
/// first. Pure apart from `thisMac()`/`appVersion()`, so it's testable without a browser.
enum ProblemReport {

    static let newIssuePage = URL(string: "https://github.com/jackpetersen235-jpg/decanter/issues/new")!

    /// The form's file name. The query keys below are its fields' `id:`s — rename one there and its
    /// field silently stops being filled in.
    static let template = "bug_report.yml"

    /// GitHub turns away very long links (HTTP 414 somewhere past 8 KB), so a long report is
    /// trimmed to keep the whole link under this.
    static let maxURLLength = 7_500

    static let trimmedNote = "\n… (trimmed to fit the link — Help ▸ Export Diagnostics saves the full report)"

    /// Every `home` becomes `~` — but only the whole folder name: "/Users/sam" must not match the
    /// front of "/Users/samantha" or "/Users/sam.smith" (account names can contain dots), while
    /// "/Users/sam." at the end of a sentence still counts.
    static func redactingHome(_ text: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: home)
                    + #"(?![A-Za-z0-9_-]|\.[A-Za-z0-9._-])"#)
        else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: "~")
    }

    static func issueURL(version: String, mac: String, report: String,
                         maxLength: Int = maxURLLength) -> URL {
        let report = report.trimmingCharacters(in: .newlines)
        let full = link(version: version, mac: mac, report: report)
        guard full.absoluteString.count > maxLength else { return full }

        // Keep as many whole lines from the top as fit (binary search: a report can be long).
        let lines = report.components(separatedBy: "\n")
        func trimmed(_ count: Int) -> URL {
            link(version: version, mac: mac,
                 report: lines.prefix(count).joined(separator: "\n") + trimmedNote)
        }
        var fits = 0, tooLong = lines.count
        while tooLong - fits > 1 {
            let mid = (fits + tooLong) / 2
            if trimmed(mid).absoluteString.count <= maxLength { fits = mid } else { tooLong = mid }
        }
        return trimmed(fits)
    }

    /// RFC 3986's unreserved characters. Everything else is escaped — including "+", which a query
    /// would otherwise read as a space, and "&"/"=", which would split the field.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func link(version: String, mac: String, report: String) -> URL {
        let fields = [("template", template), ("version", version), ("mac", mac), ("diagnostics", report)]
        let query = fields
            .map { name, value in "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        return URL(string: newIssuePage.absoluteString + "?" + query) ?? newIssuePage
    }

    // MARK: - This Mac

    /// "1.1 (35)", or "development build" for a `swift run` with no Info.plist.
    static func appVersion(_ bundle: Bundle = .main) -> String {
        guard let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return "development build" }
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// "Apple M5 (Mac16,13), macOS 27.2.0" — the model identifier pins the exact machine.
    static func thisMac() -> String {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown chip"
        let model = sysctlString("hw.model").map { " (\($0))" } ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(chip)\(model), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
