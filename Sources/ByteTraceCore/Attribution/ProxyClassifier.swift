import Foundation

public struct ProxyRule: Equatable, Sendable {
    public let key: String
    public let displayName: String
    public let bundleIDs: Set<String>
    public let executablePaths: Set<String>
    public let processNames: Set<String>

    public init(
        key: String,
        displayName: String,
        bundleIDs: Set<String> = [],
        executablePaths: Set<String> = [],
        processNames: Set<String> = []
    ) {
        self.key = key
        self.displayName = displayName
        self.bundleIDs = bundleIDs
        self.executablePaths = Set(executablePaths.map(Self.canonicalPath))
        self.processNames = processNames
    }

    fileprivate func matches(_ identity: ProcessIdentity) -> Bool {
        if let bundleID = identity.bundleID, bundleIDs.contains(bundleID) {
            return true
        }
        if let executablePath = identity.executablePath,
           executablePaths.contains(Self.canonicalPath(executablePath)) {
            return true
        }
        return processNames.contains(identity.nettopProcessName)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

public struct ProxyClassifier: Sendable {
    public let rules: [ProxyRule]

    public init(rules: [ProxyRule]) {
        self.rules = rules
    }

    public func match(_ identity: ProcessIdentity) -> ProxyRule? {
        rules.first { $0.matches(identity) }
    }

    /// 追加一个运行时识别出的代理进程（监听系统代理端口的进程）。
    /// 已被现有规则覆盖的路径原样返回，避免重复规则改变 appKey。
    public func addingDetectedProxy(executablePath: String) -> ProxyClassifier {
        let identity = ProcessIdentity(
            pid: nil,
            nettopProcessName: "",
            executablePath: executablePath
        )
        guard match(identity) == nil else { return self }
        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        let key = Self.ruleKey(for: name)
        guard !key.isEmpty else { return self }
        return ProxyClassifier(
            rules: rules + [
                ProxyRule(key: key, displayName: name, executablePaths: [executablePath])
            ]
        )
    }

    static func ruleKey(for name: String) -> String {
        String(
            name.lowercased().unicodeScalars.filter {
                ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" || $0 == "."
            }
        )
    }

    public static let defaultClassifier = ProxyClassifier(
        rules: [
            ProxyRule(
                key: "mihomo",
                displayName: "Mihomo",
                processNames: ["mihomo", "verge-mihomo", "verge-mihomo-alpha", "clash-meta", "mihomo-darwin-arm64"]
            ),
            ProxyRule(key: "clashbar", displayName: "ClashBar", processNames: ["ClashBar"]),
            ProxyRule(key: "clash", displayName: "Clash", processNames: ["clash"]),
            ProxyRule(key: "sing-box", displayName: "sing-box", processNames: ["sing-box"]),
            ProxyRule(key: "xray", displayName: "Xray", processNames: ["xray", "Xray"]),
            ProxyRule(key: "v2ray", displayName: "V2Ray", processNames: ["v2ray"]),
            ProxyRule(key: "hysteria", displayName: "Hysteria", processNames: ["hysteria"])
        ]
    )
}
