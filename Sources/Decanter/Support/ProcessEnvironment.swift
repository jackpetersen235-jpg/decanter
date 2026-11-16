import Darwin
import Foundation

/// The environment a running process started with, read the way `ps -E` reads it
/// (`KERN_PROCARGS2`). Only works for the current user's processes — Steam's, here.
///
/// Why Decanter needs it: a game Steam starts (`steam.exe -applaunch`) inherits the RUNNING Steam's
/// environment, so to know which settings a game is about to get, Play reads Steam's.
enum ProcessEnvironment {
    static func of(pid: pid_t) -> [String: String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` is argc (4 bytes), the executable path, padding, argv, then the
    /// environment, all NUL-separated. Wine rewrites a process's argv in place (steam.exe shows its
    /// Windows path there), so argc can't be trusted to find where the environment starts. A
    /// variable is told apart by its shape instead: a NAME of letters, digits and `_`, then `=`.
    static func parse(_ bytes: [UInt8]) -> [String: String] {
        guard bytes.count > 4 else { return [:] }
        var env: [String: String] = [:]
        for chunk in bytes.dropFirst(4).split(separator: 0) {
            guard let text = String(bytes: chunk, encoding: .utf8),
                  let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            let name = text[..<equals]
            guard name.first.map({ !$0.isNumber }) ?? false,
                  name.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) })
            else { continue }
            env[String(name)] = String(text[text.index(after: equals)...])
        }
        return env
    }
}
