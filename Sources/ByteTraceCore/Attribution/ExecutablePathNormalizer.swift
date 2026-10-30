import Foundation

/// 把可执行文件路径里的版本号目录、内容哈希目录折叠成 `*`，让 mise / fnm /
/// 自更新 CLI（Claude Code、codex、cursor-agent…）的各个版本归到同一个 `exec:` appKey。
///
/// 规则变化会改变已有 appKey，修改时必须在 `UsageStore.migrate()` 追加迁移，
/// 把旧 appKey 的历史行合并过去（当前规则对应 schemaVersion 7）。
public enum ExecutablePathNormalizer {
    public static let wildcard = "*"

    private static let genericDirectoryNames: Set<String> = [
        "versions", "releases", "installs", "installation", "bin", "lib",
        "libexec", "current", "contents", "macos"
    ]

    public static func normalize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { normalizeComponent(String($0)) }
            .joined(separator: "/")
    }

    /// 路径派生的展示名。可执行文件名本身就是版本号（如
    /// `~/.local/share/claude/versions/2.1.314`）时，向上取第一个有意义的目录名。
    public static func displayName(forExecutablePath path: String) -> String? {
        let components = normalize(path)
            .split(separator: "/")
            .map(String.init)
        guard let last = components.last, !last.isEmpty else { return nil }

        if last != wildcard {
            if let range = last.range(of: "-\(wildcard)") ?? last.range(of: "_\(wildcard)"),
               range.lowerBound > last.startIndex {
                return String(last[..<range.lowerBound])
            }
            return last
        }

        for component in components.dropLast().reversed() {
            guard component != wildcard,
                  !component.contains(wildcard),
                  !genericDirectoryNames.contains(component.lowercased()),
                  !component.hasPrefix(".") else {
                continue
            }
            return component
        }
        return nil
    }

    /// 整段是否为版本号（`2.1.300`、`v24.17.0`、`0.163.0-aarch64-apple-darwin`）。
    public static func isVersionLike(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard let end = versionEnd(in: scalars, from: 0) else { return false }
        return end == scalars.count || isVersionSuffix(scalars, from: end)
    }

    static func normalizeComponent(_ component: String) -> String {
        guard !component.isEmpty, component != wildcard else { return component }
        if isHashLike(component) {
            if let dot = component.firstIndex(of: ".") {
                return wildcard + component[dot...]
            }
            return wildcard
        }
        if isUUID(component) || isVersionLike(component) {
            return wildcard
        }

        // 内嵌版本：`node-v22.22.2`、`claude-2.1.300-darwin-arm64`。
        let scalars = Array(component.unicodeScalars)
        var index = 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "-" || scalar == "_",
               let end = versionEnd(in: scalars, from: index + 1),
               end == scalars.count || isSeparator(scalars[end]) {
                let prefix = String(String.UnicodeScalarView(scalars[...index]))
                let suffix = String(String.UnicodeScalarView(scalars[end...]))
                return prefix + wildcard + suffix
            }
            index += 1
        }
        return component
    }

    /// 从 `start` 起匹配 `v?数字+(.数字+)+`，返回结束位置。
    private static func versionEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var index = start
        if index < scalars.count, scalars[index] == "v" || scalars[index] == "V" {
            index += 1
        }
        let digitsStart = index
        while index < scalars.count, isDigit(scalars[index]) { index += 1 }
        guard index > digitsStart else { return nil }

        var groups = 0
        while index + 1 < scalars.count, scalars[index] == ".", isDigit(scalars[index + 1]) {
            index += 1
            while index < scalars.count, isDigit(scalars[index]) { index += 1 }
            groups += 1
        }
        return groups > 0 ? index : nil
    }

    private static func isVersionSuffix(_ scalars: [Unicode.Scalar], from index: Int) -> Bool {
        guard index + 1 < scalars.count else { return false }
        let separator = scalars[index]
        guard separator == "-" || separator == "+" || separator == "_" else { return false }
        return scalars[(index + 1)...].allSatisfy {
            isAlphanumeric($0) || $0 == "." || $0 == "-" || $0 == "_" || $0 == "+"
        }
    }

    private static func isHashLike(_ component: String) -> Bool {
        let stem = component.split(separator: ".", maxSplits: 1).first ?? ""
        guard stem.count >= 16 else { return false }
        return stem.unicodeScalars.allSatisfy {
            isDigit($0) || ("a"..."f").contains($0)
        }
    }

    private static func isUUID(_ component: String) -> Bool {
        let scalars = Array(component.unicodeScalars)
        guard scalars.count == 36 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard scalar == "-" else { return false }
            } else if !(isDigit(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)) {
                return false
            }
        }
        return true
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "-" || scalar == "_" || scalar == "+" || scalar == "."
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isDigit(scalar) || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}
