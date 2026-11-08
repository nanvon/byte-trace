import Foundation

/// 把可执行文件路径里的版本号目录、内容哈希目录折叠成 `*`，让 mise / fnm /
/// 自更新 CLI（Claude Code、codex、cursor-agent…）的各个版本归到同一个 `exec:` appKey。
///
/// 规则变化会改变已有 appKey，修改时必须在 `UsageStore.migrate()` 追加迁移，
/// 把旧 appKey 的历史行合并过去（路径归一化对应 schemaVersion 7；`commandName` 的合并
/// 在 `UsageStore.mergeCommandLineToolKeys()`，每次打开数据库都会执行）。
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

    /// 位于 `bin` / `sbin` 目录下的命令行工具返回文件名，同名工具不论装在哪里
    /// （`/usr/bin/curl`、Homebrew 的 curl、mise / fnm 的各个 node）都归到同一个 `command:` appKey。
    /// 应用附带的工具（`.app/` 内、`~/Library/Application Support/`、`.cache/` 下）不在此列，
    /// 它们按目录归到所属应用；文件名含通配（版本号就是文件名）时也不按名称合并。
    /// 另外几种固定布局也按工具名合并：git 的 `libexec/git-core/` helper 记为 git，
    /// `~/.local/share/<工具>/versions/`、Homebrew `Caskroom/<cask>/<版本>/` 和
    /// `~/.<工具>/downloads/<工具>-<版本>…` 下的自更新 CLI 记为工具名（如 Claude Code 的各种安装方式）。
    public static func commandName(forExecutablePath path: String) -> String? {
        let normalized = normalize(path)
        // Xcode 工具链（`Xcode.app/Contents/Developer/usr/bin/git`）是普通命令行工具，不算应用附带。
        let isInAppBundle = normalized.contains(".app/") && !normalized.contains(".app/Contents/Developer/")
        guard normalized.hasPrefix("/"),
              !isInAppBundle,
              !normalized.contains("/Library/Application Support/"),
              !normalized.contains("/.cache/") else {
            return nil
        }
        let components = normalized.split(separator: "/").map(String.init)
        guard components.count >= 2, let name = components.last, !name.isEmpty else {
            return nil
        }
        let parent = components[components.count - 2]

        // git 的传输 helper（git-remote-https 等）由 git 调起，算作 git 本身。
        if parent == "git-core", components.count >= 3, components[components.count - 3] == "libexec" {
            return "git"
        }
        // 自更新 CLI 的版本目录：`~/.local/share/<工具>/versions/<版本>[/…]`（Claude Code、cursor-agent）。
        if let index = components.lastIndex(of: "versions"),
           index >= 3,
           components[index - 2] == "share",
           components[index - 3] == ".local",
           !components[index - 1].contains(wildcard) {
            return components[index - 1]
        }
        // Homebrew cask 安装的命令行工具：`/opt/homebrew/Caskroom/<cask>/<版本>/<文件>`。
        if components.count >= 4,
           components[components.count - 4] == "Caskroom",
           parent == wildcard,
           !name.contains(wildcard) {
            return name
        }
        // 安装器下载的二进制：`~/.<工具>/downloads/<工具>-<版本>-…`。
        if parent == "downloads", components.count >= 3 {
            let directory = components[components.count - 3]
            let tool = String(directory.dropFirst())
            if directory.hasPrefix("."), !tool.isEmpty, name.hasPrefix(tool + "-") {
                return tool
            }
        }

        guard !name.contains(wildcard), ["bin", "sbin"].contains(parent) else {
            return nil
        }
        return name
    }

    /// 程序维度的工具名：`commandName` 之外，再按文件名统一几类应用附带、但实际是独立工具的程序：
    /// `~/Library/Application Support` 下的工具包（Claude 桌面版内置的 Claude Code）、
    /// 编辑器扩展自带的二进制（`~/.vscode/extensions/…/claude`），以及没带脚本的解释器（Python.app → python）。
    public static func programName(forExecutablePath path: String) -> String? {
        if let name = commandName(forExecutablePath: path) { return name }
        let normalized = normalize(path)
        let fileName = URL(fileURLWithPath: normalized).lastPathComponent
        guard !fileName.isEmpty, !fileName.contains(wildcard) else { return nil }
        if isInterpreter(fileName) { return interpreterName(fileName) }
        if normalized.contains("/Library/Application Support/"),
           normalized.contains(".app/Contents/MacOS/") {
            return fileName
        }
        if editorExtensionDirectories.contains(where: { normalized.contains($0) }) {
            return fileName
        }
        return nil
    }

    private static let editorExtensionDirectories = [
        "/.vscode/extensions/", "/.vscode-insiders/extensions/", "/.cursor/extensions/",
        "/.windsurf/extensions/", "/.vscode-oss/extensions/"
    ]

    /// 按脚本命名的解释器。bun、deno 多是编译好的单文件程序，不在此列。
    public static func isInterpreter(_ fileName: String) -> Bool {
        let name = fileName.lowercased()
        if ["node", "nodejs", "ruby", "perl", "php"].contains(name) { return true }
        guard name.hasPrefix("python") else { return false }
        return name.dropFirst("python".count).allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func interpreterName(_ fileName: String) -> String {
        let name = fileName.lowercased()
        if name.hasPrefix("python") { return "python" }
        if name == "nodejs" { return "node" }
        return name
    }

    /// 解释器的启动参数 → 它运行的程序名：第一个非选项参数是脚本（`python -m pip` 取模块名），
    /// Homebrew 的 `brew.rb` 记为 brew，`node_modules/<包>/…` 取包名，`bin` 下的脚本取文件名，
    /// `index.js` / `main.py` 这类通用文件名取所在目录名。`-e` / `-c` 执行的内联代码没有脚本，返回 nil。
    public static func scriptProgramName(arguments: [String]) -> String? {
        guard arguments.count >= 2 else { return nil }
        let interpreter = interpreterName(URL(fileURLWithPath: arguments[0]).lastPathComponent)
        let valueOptions: Set<String> = [
            "-r", "--require", "--import", "--loader", "--experimental-loader",
            "-I", "-C", "-E", "-W", "-X"
        ]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-m", interpreter == "python", index + 1 < arguments.count {
                let module = arguments[index + 1].split(separator: ".").first.map(String.init) ?? ""
                return module.isEmpty ? nil : module
            }
            if ["-e", "--eval", "-p", "--print", "-c"].contains(argument) { return nil }
            if argument.hasPrefix("-") {
                index += valueOptions.contains(argument) ? 2 : 1
                continue
            }
            return scriptName(forPath: argument)
        }
        return nil
    }

    private static let scriptExtensions: Set<String> = [
        "js", "mjs", "cjs", "ts", "mts", "cts", "rb", "py", "pyc", "pl", "php"
    ]
    private static let genericScriptNames: Set<String> = [
        "index", "main", "cli", "run", "start", "app", "server", "entry", "__main__", "bin"
    ]
    private static let genericScriptDirectories: Set<String> = [
        "bin", "dist", "lib", "src", "build", "out", "libexec", "scripts"
    ]

    static func scriptName(forPath path: String) -> String? {
        if path.contains("/Library/Homebrew/") || path.hasSuffix("/brew.rb") { return "brew" }
        if path.hasPrefix("/"), let name = commandName(forExecutablePath: path) {
            return strippingScriptExtension(name)
        }
        let components = path.split(separator: "/").map(String.init)
        if let index = components.lastIndex(of: "node_modules"), index + 1 < components.count {
            let package = components[index + 1]
            if package.hasPrefix("@") {
                return index + 2 < components.count ? components[index + 2] : nil
            }
            return package
        }
        guard let last = components.last else { return nil }
        let name = strippingScriptExtension(last)
        guard !name.isEmpty else { return nil }
        if genericScriptNames.contains(name.lowercased()) {
            return components.dropLast().reversed().first {
                !$0.hasPrefix(".") && !genericScriptDirectories.contains($0.lowercased())
            }
        }
        return name
    }

    private static func strippingScriptExtension(_ fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        guard scriptExtensions.contains(url.pathExtension.lowercased()) else { return fileName }
        return url.deletingPathExtension().lastPathComponent
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
