import Darwin
import Foundation

public enum PublicSuffixListError: LocalizedError {
    case missingBundledList
    case unreadableBundledList(String)

    public var errorDescription: String? {
        switch self {
        case .missingBundledList:
            return "缺少内置 Public Suffix List"
        case let .unreadableBundledList(message):
            return "无法读取 Public Suffix List：\(message)"
        }
    }
}

public struct PublicSuffixList: Sendable {
    public static let unidentifiedSiteKey = "__unidentified__"

    private let exactRules: Set<String>
    private let wildcardRules: Set<String>
    private let exceptionRules: Set<String>

    public init(list: String) {
        var exact: Set<String> = []
        var wildcard: Set<String> = []
        var exceptions: Set<String> = []

        for rawLine in list.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }
            if line.hasPrefix("!"), line.count > 1 {
                exceptions.insert(String(line.dropFirst()).lowercased())
            } else if line.hasPrefix("*."), line.count > 2 {
                wildcard.insert(String(line.dropFirst(2)).lowercased())
            } else {
                exact.insert(line.lowercased())
            }
        }

        exactRules = exact
        wildcardRules = wildcard
        exceptionRules = exceptions
    }

    public static func bundled() throws -> PublicSuffixList {
        let resourceBundleName = "ByteTrace_ByteTraceCore.bundle"
        let fileName = "public_suffix_list.dat"
        var candidates: [URL] = []
        func appendCandidates(near startURL: URL) {
            var directory = startURL
            for _ in 0..<5 {
                candidates.append(
                    directory
                        .appendingPathComponent(resourceBundleName, isDirectory: true)
                        .appendingPathComponent(fileName)
                )
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else { break }
                directory = parent
            }
        }

        if let resourceURL = Bundle.main.resourceURL {
            appendCandidates(near: resourceURL)
        }
        appendCandidates(near: Bundle.main.bundleURL)
        if let executableURL = Bundle.main.executableURL {
            appendCandidates(near: executableURL.deletingLastPathComponent())
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            appendCandidates(near: bundle.bundleURL)
            if let resourceURL = bundle.resourceURL {
                appendCandidates(near: resourceURL)
            }
        }

        guard let url = candidates.first(where: {
            FileManager.default.isReadableFile(atPath: $0.path)
        }) else {
            throw PublicSuffixListError.missingBundledList
        }
        do {
            return PublicSuffixList(list: try String(contentsOf: url, encoding: .utf8))
        } catch {
            throw PublicSuffixListError.unreadableBundledList(error.localizedDescription)
        }
    }

    public func registrableDomain(for rawHost: String?) -> String? {
        guard let host = normalizedHost(rawHost) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }

        var exceptionLength: Int?
        var matchedRuleLength = 1 // PSL 隐含默认规则 "*"

        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if exceptionRules.contains(suffix) {
                exceptionLength = labels.count - index
                break
            }
            if exactRules.contains(suffix) {
                matchedRuleLength = max(matchedRuleLength, labels.count - index)
            }
            if index > labels.startIndex, wildcardRules.contains(suffix) {
                matchedRuleLength = max(matchedRuleLength, labels.count - index + 1)
            }
        }

        let publicSuffixLength: Int
        if let exceptionLength {
            publicSuffixLength = exceptionLength - 1
        } else {
            publicSuffixLength = matchedRuleLength
        }

        guard labels.count > publicSuffixLength else { return nil }
        return labels.suffix(publicSuffixLength + 1).joined(separator: ".")
    }

    public func siteKey(for rawHost: String?) -> String {
        registrableDomain(for: rawHost) ?? Self.unidentifiedSiteKey
    }

    private func normalizedHost(_ rawHost: String?) -> String? {
        guard var host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }
        while host.last == "." {
            host.removeLast()
        }
        host = host.lowercased()
        guard !host.isEmpty,
              !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" }),
              !isIPAddress(host) else {
            return nil
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253,
              labels.count >= 2,
              labels.allSatisfy(isValidDNSLabel) else {
            return nil
        }
        return host
    }

    private func isValidDNSLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty,
              label.utf8.count <= 63,
              label.first != "-",
              label.last != "-" else {
            return false
        }
        return label.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
        }
    }

    private func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }
}
