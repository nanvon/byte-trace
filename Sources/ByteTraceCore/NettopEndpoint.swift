import Darwin

public enum NettopEndpointKind: String, CaseIterable, Hashable, Sendable {
    case hostname
    case ipAddress
    case unknown
}

public struct NettopEndpointInfo: Equatable, Sendable {
    public let kind: NettopEndpointKind
    public let hostname: String?

    public init(kind: NettopEndpointKind, hostname: String? = nil) {
        self.kind = kind
        self.hostname = hostname
    }
}

public enum NettopEndpointClassifier {
    public static func classify(_ endpoint: String?) -> NettopEndpointKind {
        info(for: endpoint).kind
    }

    /// Returns only a hostname that is directly visible in the nettop endpoint.
    /// IP addresses and unresolved endpoints deliberately do not expose a value.
    public static func info(for endpoint: String?) -> NettopEndpointInfo {
        guard let endpoint else { return NettopEndpointInfo(kind: .unknown) }
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("*") else {
            return NettopEndpointInfo(kind: .unknown)
        }
        guard let host = host(from: value), !host.isEmpty else {
            return NettopEndpointInfo(kind: .unknown)
        }
        guard !isIPAddress(host) else {
            return NettopEndpointInfo(kind: .ipAddress)
        }
        return NettopEndpointInfo(kind: .hostname, hostname: host)
    }

    private static func host(from endpoint: String) -> String? {
        if endpoint.first == "[", let closingBracket = endpoint.firstIndex(of: "]") {
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket])
        }

        let colonCount = endpoint.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        if colonCount == 1, let separator = endpoint.lastIndex(of: ":") {
            return String(endpoint[..<separator])
        }

        if colonCount > 1, let separator = endpoint.lastIndex(of: ".") {
            let port = endpoint[endpoint.index(after: separator)...]
            if Int(port) != nil {
                return String(endpoint[..<separator])
            }
        }

        return endpoint
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var address4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &address4) }) == 1 {
            return true
        }

        var address6 = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address6) == 1 }
    }
}
