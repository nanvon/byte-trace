import AppKit
import ByteTraceCore

/// 为列表行找一个可以显示图标的文件路径；只影响展示，不参与归属和 appKey。
///
/// 自身应用包有图标时直接用；否则依次借用相近应用的图标：按 bundle ID 重新定位的应用 →
/// 外层 `.app` → 同厂商应用 → 同名应用 → 系统服务对应的系统应用 → 终端 / 系统设置。
/// 都找不到（如已卸载的应用、拿不到路径的图形进程）时返回 nil，由界面显示占位符号。
@MainActor
enum AppIconResolver {
    static func iconPath(for record: DailyUsageRecord) -> String? {
        if let path = ownApp(of: record) { return path }
        if let path = outermostApp(in: record.bundlePath) ?? outermostApp(in: record.executablePath) {
            return path
        }
        if let path = sameVendorApp(for: record.bundleID) { return path }
        if let path = namedApp(for: record) { return path }
        if let path = systemServiceApp(for: record) { return path }
        return fallbackApp(for: record)
    }

    // MARK: - 匹配步骤

    private static func ownApp(of record: DailyUsageRecord) -> String? {
        if let bundlePath = record.bundlePath, hasIcon(bundlePath) {
            return bundlePath
        }
        // 应用被移动过，或记录的是运行时路径（如 iOS 应用的 /var/folders/.../Wrapper）。
        if let bundleID = record.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           hasIcon(url.path) {
            return url.path
        }
        return nil
    }

    /// 位于某个应用包内的 helper / 插件 / 扩展，用最外层应用的图标。
    private static func outermostApp(in path: String?) -> String? {
        guard let path else { return nil }
        var current = ""
        for component in (path as NSString).pathComponents {
            current = (current as NSString).appendingPathComponent(component)
            if component.hasSuffix(".app") {
                return hasIcon(current) ? current : nil
            }
        }
        return nil
    }

    /// bundle ID 前缀相同且唯一的已安装应用，如 `com.anthropic.claude-code` → Claude。
    private static func sameVendorApp(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let parts = bundleID.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2,
              !sharedBundleNamespaces.contains(parts.prefix(2).joined(separator: ".")) else {
            return nil
        }
        var bestLength = 0
        var bestPaths: Set<String> = []
        for app in installedApps.apps {
            let shared = zip(parts, app.bundleIDParts).prefix { $0 == $1 }.count
            guard shared >= 2 else { continue }
            if shared > bestLength {
                bestLength = shared
                bestPaths = [app.path]
            } else if shared == bestLength {
                bestPaths.insert(app.path)
            }
        }
        // 同厂商有多个应用时无法判断，不借用。
        return bestPaths.count == 1 ? bestPaths.first : nil
    }

    /// 展示名或路径里出现的已安装应用名，如 `Cursor Helper` → Cursor、
    /// `~/.local/share/claude/versions/*` → Claude、`.../clashbar/core/mihomo` → ClashBar。
    private static func namedApp(for record: DailyUsageRecord) -> String? {
        for key in nameKeys(record.displayName) {
            if let path = installedApps.lookup(key) { return path }
        }
        for path in [record.executablePath, record.bundlePath].compactMap({ $0 }) where !isSystemPath(path) {
            for key in pathKeys(path) {
                if let path = installedApps.lookup(key) { return path }
            }
        }
        return nil
    }

    /// 系统服务按用途借用对应系统应用的图标，如 appstoreagent → App Store。
    private static func systemServiceApp(for record: DailyUsageRecord) -> String? {
        let isSystem = record.category == .systemProcess
            || [record.executablePath, record.bundlePath].compactMap({ $0 }).contains(where: isSystemPath)
        guard isSystem else { return nil }
        let names = [
            record.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent },
            record.bundleID
        ].compactMap { $0?.lowercased() }
        for service in systemServiceApps
        where service.keywords.contains(where: { keyword in names.contains { $0.contains(keyword) } }) {
            if hasIcon(service.appPath) { return service.appPath }
        }
        return nil
    }

    private static func fallbackApp(for record: DailyUsageRecord) -> String? {
        let candidate: String?
        if let path = record.executablePath, path.hasPrefix("/usr/bin/") || path.hasPrefix("/bin/") {
            candidate = terminalApp
        } else if record.category == .systemProcess {
            candidate = systemSettingsApp
        } else if record.bundlePath == nil, let path = record.executablePath, !path.contains(".app/") {
            candidate = terminalApp
        } else if record.bundlePath == nil, record.executablePath == nil,
                  looksLikeCommandName(record.displayName) {
            candidate = terminalApp
        } else {
            candidate = nil
        }
        guard let candidate, hasIcon(candidate) else { return nil }
        return candidate
    }

    // MARK: - 名称与路径拆词

    private static func nameKeys(_ displayName: String) -> [String] {
        let words = displayName.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var keys = stride(from: words.count, to: 0, by: -1).map {
            normalized(words.prefix($0).joined(separator: " "))
        }
        keys.append(normalized(firstSegment(of: words[0])))
        // 归属时附加的宿主应用名，如「自动填充 (Ardia)」。
        keys += displayName.matches(of: /\(([^()]*)\)/).map { normalized(String($0.1)) }
        return keys.filter { $0.count >= 2 }
    }

    private static func pathKeys(_ path: String) -> [String] {
        var components = (path as NSString).pathComponents
        let home = (NSHomeDirectory() as NSString).pathComponents
        if components.starts(with: home) {
            components.removeFirst(home.count)
            // ~/Code、~/Documents 这类用户自建目录不代表任何应用；~/.codex 等工具目录保留。
            if let first = components.first, !first.hasPrefix(".") {
                components.removeFirst()
            }
        }
        var keys: [String] = []
        for component in components.reversed() {
            var name = component
            if name.hasPrefix(".") { name.removeFirst() }
            if name.hasSuffix(".app") { name.removeLast(4) }
            for key in [normalized(name), normalized(firstSegment(of: name))]
            where key.count >= 2 && !pathStopwords.contains(key) && !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    private static func firstSegment(of text: String) -> String {
        String(text.split(whereSeparator: { "-_ ".contains($0) }).first ?? "")
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// 拿不到路径时，全小写的单词名（curl、gh、node）基本是命令行工具。
    private static func looksLikeCommandName(_ name: String) -> Bool {
        guard name.count >= 2, let first = name.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(first) else { return false }
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-_."))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isSystemPath(_ path: String) -> Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/"].contains { path.hasPrefix($0) }
    }

    // MARK: - 图标与已安装应用

    private static var iconAvailability: [String: Bool] = [:]

    private static func hasIcon(_ appPath: String) -> Bool {
        if let cached = iconAvailability[appPath] { return cached }
        let fileManager = FileManager.default
        let available: Bool
        if fileManager.fileExists(atPath: (appPath as NSString).appendingPathComponent("WrappedBundle")) {
            available = true // 在 Mac 上运行的 iOS 应用，图标在内层包里，NSWorkspace 能取到。
        } else if let info = NSDictionary(contentsOfFile: (appPath as NSString).appendingPathComponent("Contents/Info.plist")) {
            available = ["CFBundleIconFile", "CFBundleIconName"].contains {
                !((info[$0] as? String) ?? "").isEmpty
            }
        } else {
            available = false
        }
        iconAvailability[appPath] = available
        return available
    }

    private struct InstalledApp {
        let path: String
        let bundleIDParts: [String]
    }

    private struct InstalledAppIndex {
        var apps: [InstalledApp] = []
        var byName: [String: String] = [:]
        var byBundleID: [String: String] = [:]

        func lookup(_ key: String) -> String? {
            byName[key] ?? byBundleID[key]
        }
    }

    /// 首次需要借用图标时扫描一次 /Applications 与 ~/Applications；系统自带应用不收录，
    /// 避免「天气」「主页」这类通用词误配，系统服务走 `systemServiceApps`。
    private static let installedApps: InstalledAppIndex = {
        var index = InstalledAppIndex()
        let fileManager = FileManager.default
        let roots = ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        var appPaths: [String] = []
        for root in roots {
            let children = ((try? fileManager.contentsOfDirectory(atPath: root)) ?? []).sorted()
            for child in children {
                let path = (root as NSString).appendingPathComponent(child)
                if child.hasSuffix(".app") {
                    appPaths.append(path)
                } else {
                    // 再进一层子目录（Utilities、Setapp 等）。
                    let nested = ((try? fileManager.contentsOfDirectory(atPath: path)) ?? []).sorted()
                    appPaths += nested.filter { $0.hasSuffix(".app") }.map { (path as NSString).appendingPathComponent($0) }
                }
            }
        }
        for path in appPaths where hasIcon(path) {
            let info = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Contents/Info.plist"))
            guard let bundleID = (info?["CFBundleIdentifier"] as? String)?.lowercased(),
                  !bundleID.hasPrefix("com.apple.") else { continue }
            let parts = bundleID.split(separator: ".").map(String.init)
            index.apps.append(InstalledApp(path: path, bundleIDParts: parts))
            index.byBundleID[bundleID] = index.byBundleID[bundleID] ?? path

            var names = [((path as NSString).lastPathComponent as NSString).deletingPathExtension]
            names += ["CFBundleName", "CFBundleDisplayName"].compactMap { info?[$0] as? String }
            // Finder 显示的本地化名称（如 DingTalk.app →「钉钉」），对应「钉钉 Networking」这类展示名。
            names.append((fileManager.displayName(atPath: path) as NSString).deletingPathExtension)
            if let meaningful = parts.dropFirst().reversed().first(where: { part in
                !genericBundleIDParts.contains(part) && !part.contains(where: \.isNumber)
            }) {
                names.append(meaningful)
            }
            for name in names {
                let key = normalized(name)
                if key.count >= 2, index.byName[key] == nil {
                    index.byName[key] = path
                }
            }
        }
        return index
    }()

    // MARK: - 规则表

    private static let terminalApp = "/System/Applications/Utilities/Terminal.app"
    private static let systemSettingsApp = "/System/Applications/System Settings.app"

    /// 多个无关开发者共用的 bundle ID 前缀，不能按厂商借图标；Apple 的走系统服务表。
    private static let sharedBundleNamespaces: Set<String> = [
        "com.apple", "com.github", "io.github", "github.io", "com.electron", "org.chromium"
    ]

    /// bundle ID 末段常见的通用词，取应用名时跳过。
    private static let genericBundleIDParts: Set<String> = [
        "app", "apps", "desktop", "mac", "macos", "osx", "client", "browser", "helper", "agent",
        "service", "electron", "core", "product", "main", "application", "ios", "dmg", "free",
        "pro", "beta", "community", "cef", "plus", "lite"
    ]

    /// 路径里不代表具体应用的目录名。
    private static let pathStopwords: Set<String> = [
        "bin", "sbin", "lib", "libexec", "usr", "opt", "local", "share", "versions", "version",
        "current", "library", "application support", "application", "caches", "cache",
        "node_modules", "node", "users", "homebrew", "cellar", "caskroom", "resources", "contents",
        "macos", "frameworks", "helpers", "xpcservices", "applications", "packages", "releases",
        "standalone", "runtime", "installs", "core", "user", "globalstorage", "extensions",
        "downloads", "documents", "desktop", "code", "app", "apps", "tmp", "var", "private",
        "debug", "release", "target", "build", "dist", "support", "data", "config", "plugins",
        "tools", "scripts", "helper", "service", "agent", "daemon", "server", "native", "binary"
    ]

    /// 系统服务可执行文件名 / bundle ID 包含关键词 → 借用的系统应用；按顺序取第一个命中。
    private static let systemServiceApps: [(keywords: [String], appPath: String)] = [
        (["photo", "mstreamd"], "/System/Applications/Photos.app"),
        (["appstore", "storekit", "commerce", "amsaccountsd", "amsengagementd", "amsondevicestor",
          "amsuipayment", "managedappdistr", "askpermission"], "/System/Applications/App Store.app"),
        (["softwareupdate", "mobileasset", "nrdupdated", "jetpackassetd", "griddatad",
          "betaenrollment"], "/System/Library/CoreServices/Software Update.app"),
        (["itunescloud", "amplibrary", "ampartwork"], "/System/Applications/Music.app"),
        (["weather"], "/System/Applications/Weather.app"),
        (["stocks"], "/System/Applications/Stocks.app"),
        (["homed", "homekit"], "/System/Applications/Home.app"),
        (["searchparty", "findmy"], "/System/Applications/FindMy.app"),
        (["remindd"], "/System/Applications/Reminders.app"),
        (["addressbook", "contacts"], "/System/Applications/Contacts.app"),
        (["dataaccessd", "calaccessd"], "/System/Applications/Calendar.app"),
        (["imtransfer", "identityservicesd", "imagent"], "/System/Applications/Messages.app"),
        (["callhistory"], "/System/Applications/Phone.app"),
        (["tipsd", "helpd"], "/System/Applications/Tips.app"),
        (["assistantd", "siri", "parsec"], "/System/Applications/Siri.app"),
        (["geod", "locationd"], "/System/Applications/Maps.app"),
        (["safari", "webprivacyd", "webkit"], "/Applications/Safari.app"),
        (["passwordbreach", "swcd", "authenticationservices"], "/System/Applications/Passwords.app"),
        (["shortcut", "workflowkit"], "/System/Applications/Shortcuts.app"),
        (["gamed"], "/System/Applications/Games.app"),
        (["watchlistd"], "/System/Applications/TV.app"),
        (["cloud", "bird", "replicatord", "com.apple.sbd", "networkserviceproxy", "familycircle"],
         "/System/Library/CoreServices/iCloud.app")
    ]
}
