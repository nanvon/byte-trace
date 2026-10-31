import AppKit
import ByteTraceCore

/// 列表行图标的来源：借用某个应用包的图标，或对应不到具体应用的 Apple 系统服务显示苹果标志。
enum AppIconSource: Equatable {
    case app(String)
    case appleLogo
}

/// 为列表行找一个可以显示的图标；只影响展示，不参与归属和 appKey。
///
/// 自身应用包有图标时直接用；否则依次借用相近应用的图标：按 bundle ID 重新定位的应用 →
/// 外层 `.app` → 同厂商应用 → 同名应用 → 系统服务对应的系统应用 / 苹果标志 →
/// 终端 / 系统设置 / 苹果标志。
/// 都找不到（如已卸载的应用、拿不到路径的图形进程）时返回 nil，由界面显示占位符号。
@MainActor
enum AppIconResolver {
    static func source(for record: DailyUsageRecord) -> AppIconSource? {
        if let path = ownApp(of: record) { return .app(path) }
        if let path = outermostApp(in: record.bundlePath) ?? outermostApp(in: record.executablePath) {
            return .app(path)
        }
        if let path = sameVendorApp(for: record.bundleID) { return .app(path) }
        if let path = namedApp(for: record) { return .app(path) }
        if let path = hostSystemApp(for: record) { return .app(path) }
        if let source = systemServiceSource(for: record) { return source }
        return fallbackSource(for: record)
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
        // 解析前就退出的进程只剩 nettop 进程名（最多 15 字符）：截断名是应用名的前缀，
        // 或 helper 名以应用名开头，如 DeepSeek Harnes → DeepSeek Harness、UURemoteServer → UURemote。
        if record.executablePath == nil, record.bundlePath == nil {
            let key = normalized(record.displayName)
            let isTruncated = record.displayName.count == 15
            if key.count >= 5, let path = installedApps.uniqueApp(named: { name in
                (isTruncated && name.hasPrefix(key)) || (name.count >= 5 && key.hasPrefix(name))
            }) {
                return path
            }
        }
        return nil
    }

    /// 归属时附加的宿主是系统应用，如「互联网账户 (系统设置)」→ 系统设置。
    private static func hostSystemApp(for record: DailyUsageRecord) -> String? {
        for match in record.displayName.matches(of: /\(([^()]*)\)/) {
            if let path = systemAppsByName[normalized(String(match.1))] { return path }
        }
        return nil
    }

    /// 系统服务按用途借用对应系统应用的图标，如 appstoreagent → App Store；
    /// 系统更新类服务显示苹果标志（软件更新.app 声明的图标文件不存在）。
    private static func systemServiceSource(for record: DailyUsageRecord) -> AppIconSource? {
        let paths = [record.executablePath, record.bundlePath].compactMap { $0 }
        let names: [String]
        if record.category == .systemProcess || paths.contains(where: isSystemPath) {
            names = [
                record.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent },
                record.bundleID
            ].compactMap { $0?.lowercased() }
        } else if paths.isEmpty, record.bundleID == nil, !looksLikeCommandName(record.displayName) {
            // 解析前就退出的系统服务只剩 nettop 截断的进程名，如 AddressBookSour；
            // 全小写的命令名仍按命令行工具处理。
            if record.displayName.lowercased().hasPrefix("com.apple.") { return .appleLogo }
            names = [record.displayName.lowercased()]
        } else {
            return nil
        }
        let matches: ([String]) -> Bool = { keywords in
            keywords.contains { keyword in names.contains { $0.contains(keyword) } }
        }
        if matches(appleLogoServiceKeywords) { return .appleLogo }
        for service in systemServiceApps where matches(service.keywords) {
            if hasIcon(service.appPath) { return .app(service.appPath) }
        }
        return nil
    }

    private static func fallbackSource(for record: DailyUsageRecord) -> AppIconSource? {
        let candidate: String?
        if let path = record.executablePath, path.hasPrefix("/usr/bin/") || path.hasPrefix("/bin/") {
            candidate = terminalApp
        } else if record.category == .systemProcess {
            return .appleLogo
        } else if record.bundlePath == nil, let path = record.executablePath, !path.contains(".app/") {
            candidate = terminalApp
        } else if record.bundlePath == nil, record.executablePath == nil, isSystemDaemonName(record.displayName) {
            return .appleLogo
        } else if record.bundlePath == nil, record.executablePath == nil,
                  looksLikeCommandName(record.displayName) || isVersionNumber(record.displayName) {
            candidate = terminalApp
        } else {
            candidate = nil
        }
        guard let candidate, hasIcon(candidate) else { return nil }
        return .app(candidate)
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

    /// 拿不到路径的系统守护进程，如 trustd、kernel_task；/usr/bin 下的命令行工具不算。
    private static func isSystemDaemonName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/") else { return false }
        return name == "kernel_task" || ["/usr/libexec/", "/usr/sbin/"].contains {
            FileManager.default.fileExists(atPath: $0 + name)
        }
    }

    /// 自更新 CLI 的进程名可能就是版本号，如 Claude Code 的 2.1.314。
    private static func isVersionNumber(_ name: String) -> Bool {
        name.wholeMatch(of: /\d+(\.\d+)+/) != nil
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
            // 只看 Info.plist 字段不够：软件更新.app 等系统包声明了图标文件却没有附带，
            // NSWorkspace 会返回空白的通用应用图标。
            let resources = (appPath as NSString).appendingPathComponent("Contents/Resources")
            let iconFile = (info["CFBundleIconFile"] as? String) ?? ""
            let iconName = (info["CFBundleIconName"] as? String) ?? ""
            let hasIconFile = !iconFile.isEmpty && [iconFile, iconFile + ".icns"].contains {
                fileManager.fileExists(atPath: (resources as NSString).appendingPathComponent($0))
            }
            let hasAssetIcon = !iconName.isEmpty
                && fileManager.fileExists(atPath: (resources as NSString).appendingPathComponent("Assets.car"))
            available = hasIconFile || hasAssetIcon
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

        /// 名称满足条件的已安装应用只有一个时返回它。
        func uniqueApp(named predicate: (String) -> Bool) -> String? {
            let paths = Set(byName.filter { predicate($0.key) }.values)
            return paths.count == 1 ? paths.first : nil
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
            // 在 Mac 上运行的 iOS 应用（如微信读书）的 Info.plist 在内层包里。
            let isWrapped = fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("WrappedBundle"))
            let infoPath = isWrapped ? "WrappedBundle/Info.plist" : "Contents/Info.plist"
            let info = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent(infoPath))
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

    /// 系统自带应用按文件名与本地化名称索引，只用于归属附加的宿主名，如「(系统设置)」。
    private static let systemAppsByName: [String: String] = {
        let fileManager = FileManager.default
        var index: [String: String] = [:]
        for root in ["/System/Applications", "/System/Applications/Utilities"] {
            let children = ((try? fileManager.contentsOfDirectory(atPath: root)) ?? []).sorted()
            for child in children where child.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(child)
                guard hasIcon(path) else { continue }
                let names = [child, fileManager.displayName(atPath: path)].map {
                    ($0 as NSString).deletingPathExtension
                }
                for name in names {
                    let key = normalized(name)
                    if key.count >= 2, index[key] == nil { index[key] = path }
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

    /// 系统更新类服务：没有可用的系统应用图标，显示苹果标志。
    private static let appleLogoServiceKeywords = [
        "softwareupdate", "mobileasset", "nrdupdated", "jetpackassetd", "griddatad", "betaenrollment"
    ]

    /// 系统服务可执行文件名 / bundle ID 包含关键词 → 借用的系统应用；按顺序取第一个命中。
    private static let systemServiceApps: [(keywords: [String], appPath: String)] = [
        (["photo", "mstreamd"], "/System/Applications/Photos.app"),
        (["appstore", "storekit", "commerce", "amsaccountsd", "amsengagementd", "amsondevicestor",
          "amsuipayment", "managedappdistr", "askpermission"], "/System/Applications/App Store.app"),
        (["akd", "appleaccount"], systemSettingsApp),
        (["submitdiaginfo"], "/System/Library/CoreServices/Applications/Feedback Assistant.app"),
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
        (["featureaccessagent"], "/System/Library/CoreServices/iCloud+.app"),
        (["testflight"], "/Applications/TestFlight.app"),
        (["cloud", "bird", "replicatord", "com.apple.sbd", "networkserviceproxy", "familycircle"],
         "/System/Library/CoreServices/iCloud.app"),
        // 系统设置的面板扩展，如 AppleIDSettings、com.apple.Family-Settings.extension。
        (["settings", "systempreferences"], systemSettingsApp)
    ]
}
