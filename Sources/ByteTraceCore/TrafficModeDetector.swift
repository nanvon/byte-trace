import Darwin
import Foundation

/// 采集模式：由本机是否存在隧道接口（utun*）决定。
/// 存在 utun → 走 TUN 类代理，用「干净模式」（丢弃回环目标流量）；
/// 不存在 → 无 TUN 代理（无代理或系统代理），用「兼容模式」（不过滤）。
public enum TrafficMode: Equatable, Sendable {
    case clean
    case compatible
}

/// 通过 getifaddrs() 枚举本机接口名检测隧道接口。
/// utun 是 macOS 系统通用的隧道接口前缀（TUN 代理、VPN 均使用），
/// 不绑定任何具体代理工具；接口存在性变化由调用方定时轮询。
public struct TrafficModeDetector: Sendable {
    public init() {}

    /// 当前本机是否存在 utun* 隧道接口。
    public func hasTunnelInterface() -> Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return false }
        defer { freeifaddrs(addresses) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = addresses
        while let current = cursor {
            if let name = current.pointee.ifa_name {
                let interfaceName = String(cString: name)
                if interfaceName.hasPrefix("utun") {
                    return true
                }
            }
            cursor = current.pointee.ifa_next
        }
        return false
    }

    /// 根据当前系统状态返回采集模式。
    public func currentMode() -> TrafficMode {
        hasTunnelInterface() ? .clean : .compatible
    }
}
