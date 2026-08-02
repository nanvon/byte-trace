import Foundation

public enum AppCategory: String, Codable, Equatable, Sendable {
    case userApp = "user_app"
    case systemProcess = "system_process"
    case proxyTransport = "proxy_transport"
    case unclassified
}

public struct AttributedProcess: Equatable, Sendable {
    public let appKey: String
    public let displayName: String
    public let category: AppCategory
    public let pid: Int32?
    public let processStartTime: Date?
    public let nettopProcessName: String
    public let executablePath: String?
    public let bundleID: String?
    public let bundlePath: String?

    public init(
        appKey: String,
        displayName: String,
        category: AppCategory,
        pid: Int32?,
        processStartTime: Date?,
        nettopProcessName: String,
        executablePath: String?,
        bundleID: String?,
        bundlePath: String?
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
    }
}

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

        let host = hostCandidate(for: identity)
        let executablePath = Self.canonicalPath(identity.executablePath)
        let appKey: String
        if let bundleID = host.bundleID, !bundleID.isEmpty {
            appKey = "bundle:\(bundleID)"
        } else if let bundlePath = host.bundlePath {
            appKey = "app:\(bundlePath)"
        } else if let executablePath {
            appKey = "exec:\(executablePath)"
        } else if !identity.nettopProcessName.isEmpty {
            appKey = "process:\(identity.nettopProcessName)"
        } else {
            let fingerprint = [
                identity.nettopProcessName,
                executablePath ?? "",
                host.bundlePath ?? "",
                identity.pid.map(String.init) ?? "",
                identity.processStartTime.map(Self.timestampString) ?? ""
            ].joined(separator: "|")
            appKey = "unknown:\(Self.stableHash(fingerprint))"
        }

        let category: AppCategory
        if Self.isSystemExecutable(executablePath) {
            category = .systemProcess
        } else if host.bundleID != nil || host.bundlePath != nil {
            category = .userApp
        } else {
            category = .unclassified
        }

        return AttributedProcess(
            appKey: appKey,
            displayName: displayName(for: identity, host: host),
            category: category,
            pid: identity.pid,
            processStartTime: identity.processStartTime,
            nettopProcessName: identity.nettopProcessName,
            executablePath: executablePath,
            bundleID: host.bundleID,
            bundlePath: host.bundlePath
        )
    }

    private struct HostCandidate {
        let executablePath: String?
        let bundleID: String?
        let bundlePath: String?
        let displayName: String?
    }

    private func hostCandidate(for identity: ProcessIdentity) -> HostCandidate {
        let current = HostCandidate(
            executablePath: Self.canonicalPath(identity.executablePath),
            bundleID: identity.bundleID,
            bundlePath: Self.canonicalPath(identity.bundlePath),
            displayName: identity.displayName
        )

        guard let executablePath = current.executablePath else { return current }

        let candidates = [current] + identity.ancestors.map {
            HostCandidate(
                executablePath: Self.canonicalPath($0.executablePath),
                bundleID: $0.bundleID,
                bundlePath: Self.canonicalPath($0.bundlePath),
                displayName: $0.displayName
            )
        }
        return candidates
            .filter { candidate in
                guard let bundlePath = candidate.bundlePath else { return false }
                return Self.isInsideAppContents(executablePath, bundlePath: bundlePath)
            }
            .min { lhs, rhs in
                (lhs.bundlePath?.count ?? Int.max) < (rhs.bundlePath?.count ?? Int.max)
            } ?? current
    }

    private func displayName(for identity: ProcessIdentity, host: HostCandidate) -> String {
        if let displayName = host.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        let processName = identity.nettopProcessName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !processName.isEmpty {
            return processName
        }
        if let executablePath = Self.canonicalPath(identity.executablePath) {
            return URL(fileURLWithPath: executablePath).lastPathComponent
        }
        return "未知进程"
    }

    private static func isInsideAppContents(_ executablePath: String, bundlePath: String) -> Bool {
        executablePath == bundlePath
            || executablePath.hasPrefix(bundlePath + "/Contents/")
    }

    private static func isSystemExecutable(_ executablePath: String?) -> Bool {
        guard let executablePath else { return false }
        let prefixes = [
            "/System/",
            "/usr/bin/",
            "/usr/lib/",
            "/usr/libexec/",
            "/usr/sbin/",
            "/bin/",
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

    private static func timestampString(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSince1970)
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

public final class ProcessAttributionCache: @unchecked Sendable {
    private struct CacheKey: Hashable {
        let pid: Int32
        let processStartTime: Date
    }

    private let lock = NSLock()
    private let attributor: ProcessAttributor
    private var cache: [CacheKey: AttributedProcess] = [:]

    public init(attributor: ProcessAttributor = ProcessAttributor()) {
        self.attributor = attributor
    }

    public func attribute(_ identity: ProcessIdentity) -> AttributedProcess {
        guard let pid = identity.pid,
              let processStartTime = identity.processStartTime else {
            return attributor.attribute(identity)
        }

        let key = CacheKey(pid: pid, processStartTime: processStartTime)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let attributed = attributor.attribute(identity)
        lock.lock()
        cache[key] = attributed
        lock.unlock()
        return attributed
    }

    public func removeAll() {
        lock.lock()
        cache.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}
