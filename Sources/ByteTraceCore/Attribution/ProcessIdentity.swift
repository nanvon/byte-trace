import AppKit
import Darwin
import Foundation

public struct NettopProcessToken: Equatable, Sendable {
    public let rawValue: String
    public let processName: String
    public let pid: Int32?

    public init(rawValue: String) {
        self.rawValue = rawValue

        guard let dotIndex = rawValue.lastIndex(of: "."), dotIndex < rawValue.index(before: rawValue.endIndex) else {
            processName = rawValue
            pid = nil
            return
        }

        let suffixStart = rawValue.index(after: dotIndex)
        let suffix = rawValue[suffixStart...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let parsedPID = Int32(suffix) else {
            processName = rawValue
            pid = nil
            return
        }

        processName = String(rawValue[..<dotIndex])
        pid = parsedPID
    }
}

public struct ProcessAncestor: Equatable, Sendable {
    public let pid: Int32
    public let processStartTime: Date?
    public let executablePath: String?
    public let bundleID: String?
    public let bundlePath: String?
    public let displayName: String?
    public let parentPID: Int32?
    /// 脚本解释器（node、ruby、python…）运行的脚本对应的程序名，见 `ExecutablePathNormalizer.scriptProgramName`。
    public let scriptName: String?

    public init(
        pid: Int32,
        processStartTime: Date? = nil,
        executablePath: String? = nil,
        bundleID: String? = nil,
        bundlePath: String? = nil,
        displayName: String? = nil,
        parentPID: Int32? = nil,
        scriptName: String? = nil
    ) {
        self.pid = pid
        self.processStartTime = processStartTime
        self.executablePath = executablePath
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.displayName = displayName
        self.parentPID = parentPID
        self.scriptName = scriptName
    }
}

/// 可执行文件路径上最外层的 `.app` 包。只在它与进程自身的应用包不同时才有值，
/// 例如 `Xcode.app/Contents/…/Python.app` 里的 Python，用于父进程已退出时仍能归到外层应用。
public struct ContainingApplication: Equatable, Sendable {
    public let bundleID: String?
    public let bundlePath: String
    public let displayName: String?
    public let executablePath: String?

    public init(
        bundleID: String?,
        bundlePath: String,
        displayName: String?,
        executablePath: String? = nil
    ) {
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.displayName = displayName
        self.executablePath = executablePath
    }
}

public struct ProcessIdentity: Equatable, Sendable {
    public let pid: Int32?
    public let processStartTime: Date?
    public let nettopProcessName: String
    public let executablePath: String?
    public let bundleID: String?
    public let bundlePath: String?
    public let displayName: String?
    public let parentPID: Int32?
    public let ancestors: [ProcessAncestor]
    public let containingApplication: ContainingApplication?
    /// 已知附属应用的主应用（如 GoogleUpdater → Google Chrome）。
    public let delegatingApplication: ContainingApplication?
    /// 系统记录的负责进程所属的应用（`responsibility_get_pid_responsible_for_pid`）：
    /// XPC 服务的委托方（「Raycast Networking」→ Raycast），终端里被 launchd 收养的子进程 → 终端。
    public let responsibleApplication: ContainingApplication?
    public let scriptName: String?

    public init(
        pid: Int32?,
        processStartTime: Date? = nil,
        nettopProcessName: String,
        executablePath: String? = nil,
        bundleID: String? = nil,
        bundlePath: String? = nil,
        displayName: String? = nil,
        parentPID: Int32? = nil,
        ancestors: [ProcessAncestor] = [],
        containingApplication: ContainingApplication? = nil,
        delegatingApplication: ContainingApplication? = nil,
        responsibleApplication: ContainingApplication? = nil,
        scriptName: String? = nil
    ) {
        self.pid = pid
        self.processStartTime = processStartTime
        self.nettopProcessName = nettopProcessName
        self.executablePath = executablePath
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.displayName = displayName
        self.parentPID = parentPID
        self.ancestors = ancestors
        self.containingApplication = containingApplication
        self.delegatingApplication = delegatingApplication
        self.responsibleApplication = responsibleApplication
        self.scriptName = scriptName
    }
}

public struct SystemProcessIdentityResolver: Sendable {
    public let maxAncestorDepth: Int

    private final class ResolverCache: @unchecked Sendable {
        struct Entry {
            let identity: ProcessIdentity
            let cachedAt: Date
        }

        let lock = NSLock()
        var entries: [Int32: Entry] = [:]
    }

    private let cache: ResolverCache
    private let cacheTTL: TimeInterval
    private let maxCacheCount: Int

    public init(
        maxAncestorDepth: Int = 8,
        cacheTTL: TimeInterval = 15,
        maxCacheCount: Int = 512
    ) {
        self.maxAncestorDepth = max(0, maxAncestorDepth)
        self.cache = ResolverCache()
        self.cacheTTL = max(0, cacheTTL)
        self.maxCacheCount = max(1, maxCacheCount)
    }

    public func resolve(_ token: NettopProcessToken) -> ProcessIdentity {
        guard let pid = token.pid else {
            return ProcessIdentity(pid: nil, nettopProcessName: token.processName)
        }

        let now = Date()
        // 一次 proc_pidinfo 即可拿到当前进程的启动时间，用它校验缓存项是否仍属于同一个
        // 进程：pid 会被系统复用，只按 pid 命中会把新进程的流量记到已退出的旧进程头上。
        // 这次 syscall 比一次完整 buildIdentity（最多 9 次 snapshot，含 LaunchServices
        // 查询与读取 Info.plist）便宜数个数量级，缓存收益不受影响。
        let currentStartTime = Self.processInfo(for: pid)?.startTime

        cache.lock.lock()
        if let entry = cache.entries[pid],
           now.timeIntervalSince(entry.cachedAt) < cacheTTL,
           entry.identity.nettopProcessName == token.processName,
           (currentStartTime == nil || entry.identity.processStartTime == currentStartTime) {
            cache.lock.unlock()
            return entry.identity
        }
        cache.lock.unlock()

        let identity = buildIdentity(for: pid, fallbackName: token.processName)

        cache.lock.lock()
        cache.entries[pid] = ResolverCache.Entry(identity: identity, cachedAt: now)
        pruneLocked(now: now)
        cache.lock.unlock()
        return identity
    }

    /// 淘汰缓存条目，调用方必须已持有 `cache.lock`。
    ///
    /// TTL 只决定「能否命中」，不会让条目消失；短命进程（shell、xpc helper、更新器）
    /// 每个都会占用一条，不清理则随运行时长单调增长。仅在超过上限时才整理一次，
    /// 摊销后成本可忽略。
    private func pruneLocked(now: Date) {
        guard cache.entries.count > maxCacheCount else { return }

        cache.entries = cache.entries.filter {
            now.timeIntervalSince($0.value.cachedAt) < cacheTTL
        }
        guard cache.entries.count > maxCacheCount else { return }

        // 过期项清完仍超限：丢弃最久未刷新的条目。
        let overflow = cache.entries.count - maxCacheCount
        let stalest = cache.entries
            .sorted { $0.value.cachedAt < $1.value.cachedAt }
            .prefix(overflow)
        for (pid, _) in stalest {
            cache.entries.removeValue(forKey: pid)
        }
    }

    private func buildIdentity(for pid: Int32, fallbackName: String) -> ProcessIdentity {
        let current = snapshot(for: pid, fallbackName: fallbackName)
        var ancestors: [ProcessAncestor] = []
        var nextPID = current.parentPID
        var visited: Set<Int32> = [pid]

        for _ in 0..<maxAncestorDepth {
            guard let parentPID = nextPID,
                  parentPID > 0,
                  visited.insert(parentPID).inserted else {
                break
            }

            let parent = snapshot(for: parentPID, fallbackName: nil)
            ancestors.append(
                ProcessAncestor(
                    pid: parentPID,
                    processStartTime: parent.processStartTime,
                    executablePath: parent.executablePath,
                    bundleID: parent.bundleID,
                    bundlePath: parent.bundlePath,
                    displayName: parent.displayName,
                    parentPID: parent.parentPID,
                    scriptName: parent.scriptName
                )
            )
            nextPID = parent.parentPID
        }

        return ProcessIdentity(
            pid: pid,
            processStartTime: current.processStartTime,
            nettopProcessName: fallbackName,
            executablePath: current.executablePath,
            bundleID: current.bundleID,
            bundlePath: current.bundlePath,
            displayName: current.displayName,
            parentPID: current.parentPID,
            ancestors: ancestors,
            containingApplication: Self.containingApplication(
                for: current.executablePath,
                ownBundlePath: current.bundlePath
            ),
            delegatingApplication: delegatingApplication(for: current),
            responsibleApplication: responsibleApplication(for: pid, ancestors: ancestors),
            scriptName: current.scriptName
        )
    }

    /// 系统记录的负责进程（活动监视器同款）。父进程链里已有它时直接复用，否则补一次快照；
    /// root 进程查不到（返回 -1），自己负责自己的进程不算。
    private func responsibleApplication(for pid: Int32, ancestors: [ProcessAncestor]) -> ContainingApplication? {
        guard let responsiblePID = Self.responsiblePID(for: pid),
              responsiblePID > 1,
              responsiblePID != pid else { return nil }
        let bundleID: String?
        let bundlePath: String?
        let displayName: String?
        let executablePath: String?
        if let ancestor = ancestors.first(where: { $0.pid == responsiblePID }) {
            (bundleID, bundlePath, displayName, executablePath) = (
                ancestor.bundleID, ancestor.bundlePath, ancestor.displayName, ancestor.executablePath
            )
        } else {
            let responsible = snapshot(for: responsiblePID, fallbackName: nil)
            (bundleID, bundlePath, displayName, executablePath) = (
                responsible.bundleID, responsible.bundlePath, responsible.displayName, responsible.executablePath
            )
        }
        guard let bundlePath, URL(fileURLWithPath: bundlePath).pathExtension.lowercased() == "app" else {
            return nil
        }
        return ContainingApplication(
            bundleID: bundleID,
            bundlePath: bundlePath,
            displayName: displayName,
            executablePath: executablePath
        )
    }

    /// 已知附属应用按 bundle ID 找主应用。
    private func delegatingApplication(for current: Snapshot) -> ContainingApplication? {
        guard let bundleID = current.bundleID,
              let hostBundleID = ProcessAttributor.auxiliaryApplicationHosts[bundleID],
              let hostURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hostBundleID) else {
            return nil
        }
        let bundle = Bundle(url: hostURL)
        return ContainingApplication(
            bundleID: hostBundleID,
            bundlePath: Self.canonicalPath(hostURL.path) ?? hostURL.path,
            displayName: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? hostURL.deletingPathExtension().lastPathComponent,
            executablePath: Self.canonicalPath(bundle?.executableURL?.path)
        )
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` 是 libquarantine 的非公开接口（活动监视器同款），
    /// 运行时按符号查找，找不到时不做委托归属。
    private static let responsibilityFunction: ResponsibilityFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    private static func responsiblePID(for pid: Int32) -> Int32? {
        guard let function = responsibilityFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }

    static func containingApplication(
        for executablePath: String?,
        ownBundlePath: String?
    ) -> ContainingApplication? {
        guard let executablePath else { return nil }
        var path = ""
        for component in URL(fileURLWithPath: executablePath).pathComponents.dropFirst() {
            path += "/" + component
            guard URL(fileURLWithPath: component).pathExtension.lowercased() == "app" else { continue }
            guard path != ownBundlePath, executablePath.hasPrefix(path + "/Contents/") else { return nil }
            let bundle = Bundle(url: URL(fileURLWithPath: path))
            return ContainingApplication(
                bundleID: bundle?.bundleIdentifier,
                bundlePath: path,
                displayName: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            )
        }
        return nil
    }

    private struct Snapshot {
        let processStartTime: Date?
        let executablePath: String?
        let bundleID: String?
        let bundlePath: String?
        let displayName: String?
        let parentPID: Int32?
        let scriptName: String?
    }

    private func snapshot(for pid: Int32, fallbackName: String?) -> Snapshot {
        let runningApplication = Self.runningApplicationSnapshot(for: pid)
        let executablePath = Self.canonicalPath(Self.executablePath(for: pid))
        let bundleURL = runningApplication.bundlePath
            .map(URL.init(fileURLWithPath:))
            ?? Self.nearestAppBundleURL(for: executablePath)
        let bundle = bundleURL.flatMap(Bundle.init(url:))
        let bundleID = runningApplication.bundleID ?? bundle?.bundleIdentifier
        let bundlePath = Self.canonicalPath(bundleURL?.path)
        let displayName = runningApplication.displayName
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundleURL?.deletingPathExtension().lastPathComponent
            ?? fallbackName

        let processInfo = Self.processInfo(for: pid)
        // 只为脚本解释器读启动参数，其他进程不多一次 sysctl。
        var scriptName: String?
        if let executablePath,
           ExecutablePathNormalizer.isInterpreter(URL(fileURLWithPath: executablePath).lastPathComponent),
           let arguments = MihomoControllerDiscovery.processArguments(pid: pid) {
            scriptName = ExecutablePathNormalizer.scriptProgramName(arguments: arguments)
        }
        return Snapshot(
            processStartTime: processInfo?.startTime,
            executablePath: executablePath,
            bundleID: bundleID,
            bundlePath: bundlePath,
            displayName: displayName,
            parentPID: processInfo?.parentPID,
            scriptName: scriptName
        )
    }

    private struct RunningApplicationSnapshot: Sendable {
        let bundlePath: String?
        let bundleID: String?
        let displayName: String?
    }

    @MainActor
    private static func readRunningApplication(_ pid: Int32) -> RunningApplicationSnapshot {
        let application = NSRunningApplication(processIdentifier: pid)
        return RunningApplicationSnapshot(
            bundlePath: application?.bundleURL?.path,
            bundleID: application?.bundleIdentifier,
            displayName: application?.localizedName
        )
    }

    private static func runningApplicationSnapshot(for pid: Int32) -> RunningApplicationSnapshot {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { readRunningApplication(pid) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { readRunningApplication(pid) }
        }
    }

    private struct ProcessInfoSnapshot {
        let parentPID: Int32
        let startTime: Date
    }

    private static func processInfo(for pid: Int32) -> ProcessInfoSnapshot? {
        var info = proc_bsdinfo()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.stride)
            )
        }
        guard result == Int32(MemoryLayout<proc_bsdinfo>.stride) else { return nil }

        let startTime = Date(
            timeIntervalSince1970:
                TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )
        return ProcessInfoSnapshot(parentPID: Int32(info.pbi_ppid), startTime: startTime)
    }

    private static func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard length > 0 else { return nil }

        return String(
            decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func nearestAppBundleURL(for executablePath: String?) -> URL? {
        guard let executablePath else { return nil }

        var candidate = URL(fileURLWithPath: executablePath)
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func canonicalPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
