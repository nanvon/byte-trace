import Darwin
import Foundation

/// mihomo（Clash.Meta）外部控制器的位置。只用于读取 `/connections`，判断经代理的连接
/// 走节点还是命中 DIRECT 规则；字节数仍以 nettop 为准。
public struct MihomoController: Equatable, Sendable {
    public enum Transport: Equatable, Sendable {
        case tcp(host: String, port: UInt16)
        case unix(path: String)
    }

    public let transport: Transport
    public let secret: String?

    public init(transport: Transport, secret: String?) {
        self.transport = transport
        self.secret = secret
    }
}

public enum MihomoControllerDiscovery {
    /// 从内核进程的命令行参数与配置文件推断控制器地址。
    /// 参数优先（`-ext-ctl` / `-ext-ctl-unix` / `-secret`），否则读 `-f` 指定或 `-d` 目录下的
    /// `config.yaml` 顶层 `external-controller` / `external-controller-unix` / `secret`。
    public static func controller(
        arguments: [String],
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> MihomoController? {
        var tcpAddress = value(after: "-ext-ctl", in: arguments)
        var unixPath = value(after: "-ext-ctl-unix", in: arguments)
        var secret = value(after: "-secret", in: arguments)

        let configPath = value(after: "-f", in: arguments)
            ?? value(after: "-d", in: arguments).map { ($0 as NSString).appendingPathComponent("config.yaml") }
        if let configPath, let config = readFile(configPath) {
            let keys = topLevelValues(in: config)
            tcpAddress = tcpAddress ?? keys["external-controller"]
            unixPath = unixPath ?? keys["external-controller-unix"]
            secret = secret ?? keys["secret"]
        }
        let normalizedSecret = secret.flatMap { $0.isEmpty ? nil : $0 }

        if let tcpAddress, let endpoint = tcpEndpoint(tcpAddress) {
            return MihomoController(transport: .tcp(host: endpoint.host, port: endpoint.port), secret: normalizedSecret)
        }
        if let unixPath, !unixPath.isEmpty {
            return MihomoController(transport: .unix(path: unixPath), secret: normalizedSecret)
        }
        return nil
    }

    /// `127.0.0.1:9090`、`:9090`、`0.0.0.0:9090`、`[::1]:9090`。通配地址改连本机回环。
    static func tcpEndpoint(_ address: String) -> (host: String, port: UInt16)? {
        var value = address.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("http://") { value.removeFirst("http://".count) }
        guard let colon = value.lastIndex(of: ":"),
              let port = UInt16(value[value.index(after: colon)...]),
              port > 0 else {
            return nil
        }
        var host = String(value[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.isEmpty || host == "0.0.0.0" || host == "::" || host == "*" {
            host = "127.0.0.1"
        }
        return (host, port)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// 只解析不缩进的 `key: value` 行，足够读取控制器配置；不引入 YAML 依赖。
    static func topLevelValues(in yaml: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in yaml.split(whereSeparator: \.isNewline) {
            guard let first = line.first, !first.isWhitespace, first != "#",
                  let colon = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") {
                value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if value.count >= 2,
               let quote = value.first, quote == "\"" || quote == "'",
               value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            if values[key] == nil {
                values[key] = value
            }
        }
        return values
    }

    /// 读取进程命令行参数（`KERN_PROCARGS2`）。无权限或进程已退出时返回 nil。
    public static func processArguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // 跳过可执行文件路径及其后的 NUL 填充。
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while index < size, arguments.count < Int(argc) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(argc) ? arguments : nil
    }
}
