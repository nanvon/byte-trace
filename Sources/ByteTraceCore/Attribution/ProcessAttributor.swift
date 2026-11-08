import Foundation

public enum AppCategory: String, Codable, Equatable, Sendable {
    case userApp = "user_app"
    case systemProcess = "system_process"
    case proxyTransport = "proxy_transport"
    case unclassified
}

/// 没有 GUI 应用可归属时的虚拟宿主。appKey 以 `host:` 开头，展示名固定。
public enum VirtualHost {
    /// 系统目录下的守护进程与服务。
    public static let systemKey = "host:system"
    /// 命令行工具：不在任何 GUI 应用里运行的第三方程序（launchd 直接启动的后台程序、
    /// 早期版本没有记下来源的命令行流量），以及解析前就退出、来源不明的进程。
    public static let otherKey = "host:other"

    public static func displayName(for appKey: String) -> String? {
        switch appKey {
        case systemKey: return "macOS 系统"
        case otherKey: return "命令行工具"
        default: return nil
        }
    }

    public static func category(for appKey: String) -> AppCategory {
        appKey == systemKey ? .systemProcess : .unclassified
    }

    public static func isVirtual(_ appKey: String) -> Bool {
        appKey.hasPrefix("host:")
    }
}

/// 宿主之下实际产生流量的程序。`nil` 表示宿主应用自身（主进程、helper、为它工作的 XPC 服务）。
public struct AttributedProgram: Equatable, Sendable {
    /// `command:<工具名>` / `exec:<归一化路径>` / `process:<进程名>` / `unknown:<哈希>`，
    /// 附属应用为 `bundle:<bundle ID>`。
    public let key: String
    public let displayName: String
    public let category: AppCategory
    public let executablePath: String?

    public init(key: String, displayName: String, category: AppCategory, executablePath: String?) {
        self.key = key
        self.displayName = displayName
        self.category = category
        self.executablePath = executablePath
    }
}

public struct AttributedProcess: Equatable, Sendable {
    /// 宿主：GUI 应用（`bundle:` / `app:`）、虚拟宿主（`host:`）或代理传输（`proxy:`）。
    public let appKey: String
    public let displayName: String
    public let category: AppCategory
    public let pid: Int32?
    public let processStartTime: Date?
    public let nettopProcessName: String
    public let executablePath: String?
    public let bundleID: String?
    public let bundlePath: String?
    public let program: AttributedProgram?

    public init(
        appKey: String,
        displayName: String,
        category: AppCategory,
        pid: Int32?,
        processStartTime: Date?,
        nettopProcessName: String,
        executablePath: String?,
        bundleID: String?,
        bundlePath: String?,
        program: AttributedProgram? = nil
    ) {
        self.appKey = appKey
        self.displayName = displayName
        self.category = category
        self.pid = pid
        self.processStartTime = processStartTime
        self.nettopProcessName = nettopProcessName
        self.executablePath = executablePath
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.program = program
    }
}

/// 每个进程归到「宿主 + 程序」两级：
///
/// 宿主按顺序找，命中即停：代理内核单独记录 → 可执行文件所在的最外层 `.app` →
/// 父进程链上最近的 GUI 应用（终端、编辑器都算）→ 系统记录的负责进程（XPC 服务、被 launchd
/// 收养的子进程）→ 虚拟宿主「macOS 系统」/「命令行工具」。附属应用（更新器等）归到主应用。
///
/// 程序是宿主之下由宿主或 shell 直接启动的那个（跳过 shell、tmux 等透明启动者），
/// 它再调起的子进程都算它；宿主自己的进程算「应用本身」。程序按工具名统一，
/// 脚本解释器按脚本命名（brew 运行的 ruby 记为 brew）。
public struct ProcessAttributor: Sendable {
    public let proxyClassifier: ProxyClassifier

    public init(proxyClassifier: ProxyClassifier = .defaultClassifier) {
        self.proxyClassifier = proxyClassifier
    }

    public func attribute(_ identity: ProcessIdentity) -> AttributedProcess {
        if let proxyRule = proxyClassifier.match(identity) {
            return AttributedProcess(
                appKey: "proxy:\(proxyRule.key)",
                displayName: proxyRule.displayName,
                category: .proxyTransport,
                pid: identity.pid,
                processStartTime: identity.processStartTime,
                nettopProcessName: identity.nettopProcessName,
                executablePath: Self.canonicalPath(identity.executablePath),
                bundleID: identity.bundleID,
                bundlePath: Self.canonicalPath(identity.bundlePath)
            )
        }

        let ownPath = Self.canonicalPath(identity.executablePath)
        let chain = Self.chain(of: identity)

        // 1. 附属应用（多装在 `~/Library/Application Support`，自身不作宿主）归主应用，程序是它自己。
        if let bundleID = identity.bundleID,
           let mainBundleID = Self.auxiliaryApplicationHosts[bundleID],
           let main = identity.delegatingApplication.flatMap(hostCandidate(from:)),
           main.bundleID == mainBundleID {
            let name = identity.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let program = AttributedProgram(
                key: "bundle:\(bundleID)",
                displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? identity.nettopProcessName,
                category: .userApp,
                executablePath: ownPath
            )
            return make(identity, host: main, program: program)
        }

        // 2. 进程就在某个应用包里：helper、内置工具、应用本身。
        if let host = ownApplication(of: identity, ownPath: ownPath) {
            return make(identity, host: host.with(executablePath: ownPath), program: nil)
        }

        // 3. 父进程链上最近的 GUI 应用。
        if let (index, host) = ancestorApplication(of: identity) {
            return make(identity, host: host, program: program(in: chain.prefix(index + 1), host: host))
        }

        // 4. 系统记录的负责进程：XPC 服务替它工作，算应用本身；被收养的子进程照常找程序。
        if let host = identity.responsibleApplication.flatMap(hostCandidate(from:)) {
            let program = ownPath?.contains(".xpc/Contents/MacOS/") == true
                ? nil
                : self.program(in: chain[...], host: host)
            return make(identity, host: host, program: program)
        }

        // 5. 没有 GUI 应用：按程序所在目录分到「macOS 系统」或「命令行工具」。
        let program = self.program(in: chain[...], host: nil, fingerprint: Self.fingerprint(of: identity))
            ?? Self.programIdentity(of: chain[0], fallbackFingerprint: Self.fingerprint(of: identity))
        let hostKey = program.category == .systemProcess ? VirtualHost.systemKey : VirtualHost.otherKey
        return AttributedProcess(
            appKey: hostKey,
            displayName: VirtualHost.displayName(for: hostKey) ?? hostKey,
            category: VirtualHost.category(for: hostKey),
            pid: identity.pid,
            processStartTime: identity.processStartTime,
            nettopProcessName: identity.nettopProcessName,
            executablePath: nil,
            bundleID: nil,
            bundlePath: nil,
            program: program
        )
    }

    /// 已知附属应用（独立安装的更新器、助手）→ 主应用的 bundle ID。运行时归属与历史迁移共用。
    static let auxiliaryApplicationHosts: [String: String] = [
        "com.google.GoogleUpdater": "com.google.Chrome",
        "com.citrolabs.EgoUpdater": "com.citrolabs.ego.lite",
        "com.hezongyidev.BobHelper": "com.hezongyidev.Bob",
        "com.openai.sky.CUAService": "com.openai.codex"
    ]

    /// 有应用包但不作为宿主：它启动的进程继续向上找。
    private static let nonHostBundleIDs: Set<String> = ["com.apple.loginwindow"]

    /// 找程序时跳过的启动者：shell、会话与多路复用器、只负责转发参数的通用工具。
    static let transparentLauncherNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu",
        "login", "sudo", "env", "nohup", "tmux", "screen", "script", "xargs",
        "make", "timeout", "time", "launchd", "arch", "caffeinate", "nice",
        "zellij", "byobu", "mosh-server", "abduco", "dtach"
    ]

    // MARK: - 宿主

    private struct HostCandidate {
        let executablePath: String?
        let bundleID: String?
        let bundlePath: String
        let displayName: String?

        var name: String {
            if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !displayName.isEmpty {
                return displayName
            }
            return URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        }

        func with(executablePath: String?) -> HostCandidate {
            HostCandidate(
                executablePath: executablePath ?? self.executablePath,
                bundleID: bundleID,
                bundlePath: bundlePath,
                displayName: displayName
            )
        }
    }

    private func make(
        _ identity: ProcessIdentity,
        host: HostCandidate,
        program: AttributedProgram?
    ) -> AttributedProcess {
        let appKey: String
        if let bundleID = host.bundleID, !bundleID.isEmpty {
            appKey = "bundle:\(bundleID)"
        } else {
            appKey = "app:\(host.bundlePath)"
        }
        return AttributedProcess(
            appKey: appKey,
            displayName: host.name,
            category: Self.isSystemExecutable(host.bundlePath) ? .systemProcess : .userApp,
            pid: identity.pid,
            processStartTime: identity.processStartTime,
            nettopProcessName: identity.nettopProcessName,
            executablePath: host.executablePath,
            bundleID: host.bundleID.flatMap { $0.isEmpty ? nil : $0 },
            bundlePath: host.bundlePath,
            program: program
        )
    }

    /// 可执行文件所在的最外层 `.app`。Xcode 工具链（`.app/Contents/Developer/`）、
    /// 框架里的 `.app`（Homebrew Python.app）、`~/Library/Application Support` 下的附属包不算。
    private func ownApplication(of identity: ProcessIdentity, ownPath: String?) -> HostCandidate? {
        let outer: String?
        if let ownPath {
            guard !ownPath.contains(".app/Contents/Developer/") else { return nil }
            outer = Self.outermostApplicationPath(in: ownPath)
        } else {
            outer = Self.validatedBundlePath(identity.bundlePath)
        }
        guard let outer, Self.isHostBundlePath(outer) else { return nil }

        var info: (bundleID: String?, displayName: String?)?
        if Self.validatedBundlePath(identity.bundlePath) == outer {
            info = (identity.bundleID, identity.displayName)
        } else if let containing = identity.containingApplication,
                  Self.validatedBundlePath(containing.bundlePath) == outer {
            info = (containing.bundleID, containing.displayName)
        } else if let ancestor = identity.ancestors.first(where: { Self.validatedBundlePath($0.bundlePath) == outer }) {
            info = (ancestor.bundleID, ancestor.displayName)
        }
        let host = HostCandidate(
            executablePath: ownPath,
            bundleID: info?.bundleID,
            bundlePath: outer,
            displayName: info?.displayName
        )
        return isUsableHost(host) ? host : nil
    }

    /// 父进程链上第一个可作宿主的应用，返回它在 `ancestors` 里的位置。
    private func ancestorApplication(of identity: ProcessIdentity) -> (Int, HostCandidate)? {
        let ancestors = identity.ancestors
        for (index, ancestor) in ancestors.enumerated() where ancestor.pid > 1 {
            let path = Self.canonicalPath(ancestor.executablePath)
            if path?.contains(".app/Contents/Developer/") == true { continue }
            guard let outer = path.flatMap(Self.outermostApplicationPath)
                    ?? Self.validatedBundlePath(ancestor.bundlePath),
                  Self.isHostBundlePath(outer) else { continue }

            // helper 的父进程通常就是主进程，从那里取 bundle ID 和名称。
            let owner = ancestors[index...].first { Self.validatedBundlePath($0.bundlePath) == outer }
            let host = HostCandidate(
                executablePath: owner.flatMap { Self.canonicalPath($0.executablePath) } ?? path,
                bundleID: owner?.bundleID,
                bundlePath: outer,
                displayName: owner?.displayName
            )
            if isUsableHost(host) {
                return (index, host)
            }
        }
        return nil
    }

    private func hostCandidate(from application: ContainingApplication) -> HostCandidate? {
        guard let bundlePath = Self.validatedBundlePath(application.bundlePath),
              Self.isHostBundlePath(bundlePath) else { return nil }
        let host = HostCandidate(
            executablePath: Self.canonicalPath(application.executablePath),
            bundleID: application.bundleID,
            bundlePath: bundlePath,
            displayName: application.displayName
        )
        return isUsableHost(host) ? host : nil
    }

    /// 代理应用与 loginwindow 不作为宿主。
    private func isUsableHost(_ host: HostCandidate) -> Bool {
        if let bundleID = host.bundleID, Self.nonHostBundleIDs.contains(bundleID) { return false }
        let hostIdentity = ProcessIdentity(
            pid: nil,
            nettopProcessName: host.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
            executablePath: host.executablePath,
            bundleID: host.bundleID,
            bundlePath: host.bundlePath
        )
        return proxyClassifier.match(hostIdentity) == nil
    }

    static func outermostApplicationPath(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func isHostBundlePath(_ bundlePath: String) -> Bool {
        !bundlePath.contains("/Library/Application Support/") && !bundlePath.contains(".framework/")
    }

    // MARK: - 程序

    private struct ChainLink {
        let executablePath: String?
        let scriptName: String?
        let processName: String
    }

    /// 进程自身在前，接着是父进程链（不含 launchd）。
    private static func chain(of identity: ProcessIdentity) -> [ChainLink] {
        let ownPath = canonicalPath(identity.executablePath)
        var links = [ChainLink(
            executablePath: ownPath,
            scriptName: identity.scriptName,
            processName: identity.nettopProcessName
        )]
        for ancestor in identity.ancestors {
            guard ancestor.pid > 1 else { break }
            let path = canonicalPath(ancestor.executablePath)
            links.append(ChainLink(
                executablePath: path,
                scriptName: ancestor.scriptName,
                processName: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            ))
        }
        return links
    }

    /// 宿主之下最外层、不透明的那个程序；它就在宿主的数据目录里（Raycast 内置的 node）时算应用本身。
    private func program(
        in links: ArraySlice<ChainLink>,
        host: HostCandidate?,
        fingerprint: String? = nil
    ) -> AttributedProgram? {
        guard let first = links.first else { return nil }
        let actor = links.reversed().first { !Self.isTransparent($0) } ?? first
        if let host, let path = actor.executablePath, Self.belongs(path, to: host) {
            return nil
        }
        return Self.programIdentity(of: actor, fallbackFingerprint: fingerprint)
    }

    private static func isTransparent(_ link: ChainLink) -> Bool {
        guard let path = link.executablePath else { return true }
        return transparentLauncherNames.contains(URL(fileURLWithPath: path).lastPathComponent)
    }

    private static func belongs(_ path: String, to host: HostCandidate) -> Bool {
        if path.hasPrefix(host.bundlePath + "/") { return true }
        guard !path.contains(".app/") else { return false }
        let lowered = path.lowercased()
        var directories: [String] = []
        if let bundleID = host.bundleID, !bundleID.isEmpty {
            directories.append("/library/application support/\(bundleID.lowercased())/")
        }
        let name = host.name.lowercased()
        directories.append("/library/application support/\(name)/")
        directories.append("/.cache/\(name)/")
        return directories.contains { lowered.contains($0) }
    }

    private static func programIdentity(of link: ChainLink, fallbackFingerprint: String?) -> AttributedProgram {
        guard let path = link.executablePath else {
            let name = link.processName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                let key = "unknown:\(stableHash(fallbackFingerprint ?? ""))"
                return AttributedProgram(key: key, displayName: "未知进程", category: .unclassified, executablePath: nil)
            }
            return AttributedProgram(
                key: "process:\(link.processName)",
                displayName: name,
                category: .unclassified,
                executablePath: nil
            )
        }
        let category: AppCategory = isSystemExecutable(path) ? .systemProcess : .unclassified
        if let script = link.scriptName, !script.isEmpty {
            return AttributedProgram(key: "command:\(script)", displayName: script, category: category, executablePath: path)
        }
        if let name = ExecutablePathNormalizer.programName(forExecutablePath: path) {
            return AttributedProgram(key: "command:\(name)", displayName: name, category: category, executablePath: path)
        }
        return AttributedProgram(
            key: "exec:\(ExecutablePathNormalizer.normalize(path))",
            displayName: executableDisplayName(path: path, processName: link.processName),
            category: category,
            executablePath: path
        )
    }

    /// nettop 进程名最多 15 个字符，自更新 CLI 的进程名还可能就是版本号；优先用路径派生的稳定名称。
    private static func executableDisplayName(path: String, processName: String) -> String {
        let processName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pathName = ExecutablePathNormalizer.displayName(forExecutablePath: path),
              !pathName.isEmpty else {
            return processName.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : processName
        }
        if ExecutablePathNormalizer.normalize(path) != path
            || processName.isEmpty
            || ExecutablePathNormalizer.isVersionLike(processName)
            || (pathName.count > processName.count && pathName.hasPrefix(processName)) {
            return pathName
        }
        return processName
    }

    private static func fingerprint(of identity: ProcessIdentity) -> String {
        [
            identity.nettopProcessName,
            identity.executablePath ?? "",
            identity.bundlePath ?? "",
            identity.pid.map(String.init) ?? "",
            identity.processStartTime.map { String(format: "%.6f", $0.timeIntervalSince1970) } ?? ""
        ].joined(separator: "|")
    }

    // MARK: - 路径工具

    /// NSRunningApplication 偶发把非 app 进程的可执行文件路径自身当成 bundleURL
    /// （如 node 出现 bundlePath=/…/bin/node）。bundlePath 必须是真实 `.app` 包目录，否则置 nil。
    private static func validatedBundlePath(_ path: String?) -> String? {
        guard let canonical = canonicalPath(path) else { return nil }
        guard URL(fileURLWithPath: canonical).pathExtension.lowercased() == "app" else { return nil }
        return canonical
    }

    /// 系统守护进程与后台服务。`/usr/bin/`、`/bin/` 下是用户运行的命令行工具（curl、ssh、git），不算。
    static func isSystemExecutable(_ executablePath: String?) -> Bool {
        guard let executablePath else { return false }
        let prefixes = [
            "/System/",
            "/usr/lib/",
            "/usr/libexec/",
            "/usr/sbin/",
            "/sbin/"
        ]
        return prefixes.contains { executablePath.hasPrefix($0) }
    }

    private static func canonicalPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

/// 落库的「nettop 进程名 → 归属」，启动时预填名称缓存，让重启后解析前就退出的短命进程
/// 仍能沿用上次的归属，而不是拆出 `process:` 记录。
public struct RememberedProcessAttribution: Equatable, Sendable {
    public let processName: String
    public let appKey: String
    public let displayName: String
    public let category: AppCategory
    public let bundleID: String?
    public let bundlePath: String?
    public let executablePath: String?
    public let program: AttributedProgram?

    public init(
        processName: String,
        appKey: String,
        displayName: String,
        category: AppCategory,
        bundleID: String?,
        bundlePath: String?,
        executablePath: String?,
        program: AttributedProgram? = nil
    ) {
        self.processName = processName
        self.appKey = appKey
        self.displayName = displayName
        self.category = category
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.program = program
    }
}

public final class ProcessAttributionCache: @unchecked Sendable {
    private struct CacheKey: Hashable {
        let pid: Int32
        let processStartTime: Date
    }

    private let lock = NSLock()
    private var attributor: ProcessAttributor
    private let maxCount: Int
    private var cache: [CacheKey: AttributedProcess] = [:]
    private var accessOrder: [CacheKey] = []
    /// 每个 nettop 进程名最近一次解析成功的归属。进程在读到路径前就退出时沿用它，
    /// 避免同一程序拆出一条 `process:` 记录；同名不同路径时取最近一次。
    private var lastResolvedByName: [String: AttributedProcess] = [:]
    private let maxNameCount = 1000

    public init(
        attributor: ProcessAttributor = ProcessAttributor(),
        maxCount: Int = 2000
    ) {
        self.attributor = attributor
        self.maxCount = max(1, maxCount)
    }

    public func attribute(_ identity: ProcessIdentity) -> AttributedProcess {
        if Self.isUnresolved(identity) {
            lock.lock()
            let currentAttributor = attributor
            let remembered = lastResolvedByName[identity.nettopProcessName]
            lock.unlock()
            let attributed = currentAttributor.attribute(identity)
            guard attributed.category != .proxyTransport, let remembered else { return attributed }
            return AttributedProcess(
                appKey: remembered.appKey,
                displayName: remembered.displayName,
                category: remembered.category,
                pid: identity.pid,
                processStartTime: identity.processStartTime,
                nettopProcessName: identity.nettopProcessName,
                executablePath: remembered.executablePath,
                bundleID: remembered.bundleID,
                bundlePath: remembered.bundlePath,
                program: remembered.program
            )
        }

        guard let pid = identity.pid,
              let processStartTime = identity.processStartTime else {
            lock.lock()
            let currentAttributor = attributor
            lock.unlock()
            let attributed = currentAttributor.attribute(identity)
            remember(attributed)
            return attributed
        }

        let key = CacheKey(pid: pid, processStartTime: processStartTime)
        lock.lock()
        if let cached = cache[key] {
            // LRU：命中项移到队尾（最近使用）。
            if let index = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: index)
                accessOrder.append(key)
            }
            lock.unlock()
            return cached
        }
        lock.unlock()

        lock.lock()
        let currentAttributor = attributor
        lock.unlock()
        let attributed = currentAttributor.attribute(identity)
        lock.lock()
        if cache[key] == nil {
            cache[key] = attributed
            accessOrder.append(key)
            evictIfNeeded()
        }
        lock.unlock()
        remember(attributed)
        return attributed
    }

    /// 解析时进程已退出：拿不到路径、应用包和启动时间。
    private static func isUnresolved(_ identity: ProcessIdentity) -> Bool {
        identity.executablePath == nil
            && identity.bundlePath == nil
            && (identity.bundleID ?? "").isEmpty
            && identity.processStartTime == nil
            && !identity.nettopProcessName.isEmpty
    }

    private func remember(_ attributed: AttributedProcess) {
        guard !attributed.nettopProcessName.isEmpty,
              attributed.executablePath != nil || attributed.bundlePath != nil
                || attributed.program?.executablePath != nil,
              attributed.category != .proxyTransport else { return }
        lock.lock()
        if lastResolvedByName.count >= maxNameCount,
           lastResolvedByName[attributed.nettopProcessName] == nil {
            lastResolvedByName.removeAll(keepingCapacity: true)
        }
        lastResolvedByName[attributed.nettopProcessName] = attributed
        lock.unlock()
    }

    private func evictIfNeeded() {
        while accessOrder.count > maxCount, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    /// 把运行时识别出的代理进程加入分类规则；规则有变化时清空缓存并返回 true。
    @discardableResult
    public func registerDetectedProxy(executablePath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let classifier = attributor.proxyClassifier.addingDetectedProxy(
            executablePath: executablePath
        )
        guard classifier.rules.count != attributor.proxyClassifier.rules.count else {
            return false
        }
        attributor = ProcessAttributor(proxyClassifier: classifier)
        cache.removeAll(keepingCapacity: true)
        accessOrder.removeAll(keepingCapacity: true)
        // 只丢弃这个代理进程的名称记忆，启动时预填的其他名称保留。
        lastResolvedByName = lastResolvedByName.filter {
            $0.value.executablePath != executablePath && $0.value.program?.executablePath != executablePath
        }
        return true
    }

    /// 启动时用落库的名称归属预填；运行中解析到的归属优先，已有的名称不覆盖。
    public func seed(_ remembered: [RememberedProcessAttribution]) {
        lock.lock()
        defer { lock.unlock() }
        for item in remembered where !item.processName.isEmpty && item.category != .proxyTransport {
            guard lastResolvedByName[item.processName] == nil,
                  lastResolvedByName.count < maxNameCount else { continue }
            lastResolvedByName[item.processName] = AttributedProcess(
                appKey: item.appKey,
                displayName: item.displayName,
                category: item.category,
                pid: nil,
                processStartTime: nil,
                nettopProcessName: item.processName,
                executablePath: item.executablePath,
                bundleID: item.bundleID,
                bundlePath: item.bundlePath,
                program: item.program
            )
        }
    }

    public func removeAll() {
        lock.lock()
        cache.removeAll(keepingCapacity: false)
        accessOrder.removeAll(keepingCapacity: false)
        lastResolvedByName.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}
