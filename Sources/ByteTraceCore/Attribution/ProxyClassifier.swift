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

    public static let defaultClassifier = ProxyClassifier(
        rules: [
            ProxyRule(key: "mihomo", displayName: "Mihomo", processNames: ["mihomo"]),
            ProxyRule(key: "clashbar", displayName: "ClashBar", processNames: ["ClashBar"])
        ]
    )
}
