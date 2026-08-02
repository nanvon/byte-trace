import Darwin

public enum NettopEndpointKind: String, CaseIterable, Hashable, Sendable {
    case hostname
    case ipAddress
    case unknown
}

public enum NettopEndpointClassifier {
    public static func classify(_ endpoint: String?) -> NettopEndpointKind {
        guard let endpoint else { return .unknown }
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("*") else { return .unknown }
        guard let host = host(from: value), !host.isEmpty else { return .unknown }
        return isIPAddress(host) ? .ipAddress : .hostname
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
