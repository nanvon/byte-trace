import Foundation
import SystemConfiguration

public enum SystemProxyEndpointParser {
    public static func loopbackEndpoints(from dictionary: [String: Any]) -> Set<NettopEndpoint> {
        var endpoints: Set<NettopEndpoint> = []
        appendEndpoint(
            enableKey: kSCPropNetProxiesHTTPEnable as String,
            hostKey: kSCPropNetProxiesHTTPProxy as String,
            portKey: kSCPropNetProxiesHTTPPort as String,
            from: dictionary,
            into: &endpoints
        )
        appendEndpoint(
            enableKey: kSCPropNetProxiesHTTPSEnable as String,
            hostKey: kSCPropNetProxiesHTTPSProxy as String,
            portKey: kSCPropNetProxiesHTTPSPort as String,
            from: dictionary,
            into: &endpoints
        )
        appendEndpoint(
            enableKey: kSCPropNetProxiesSOCKSEnable as String,
            hostKey: kSCPropNetProxiesSOCKSProxy as String,
            portKey: kSCPropNetProxiesSOCKSPort as String,
            from: dictionary,
            into: &endpoints
        )
        return endpoints
    }

    private static func appendEndpoint(
        enableKey: String,
        hostKey: String,
        portKey: String,
        from dictionary: [String: Any],
        into endpoints: inout Set<NettopEndpoint>
    ) {
        guard number(dictionary[enableKey]) == 1,
              let host = dictionary[hostKey] as? String,
              let portNumber = number(dictionary[portKey]),
              let port = UInt16(exactly: portNumber),
              port > 0 else {
            return
        }

        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedHost == "localhost" {
            endpoints.insert(NettopEndpoint(host: "127.0.0.1", port: port))
            endpoints.insert(NettopEndpoint(host: "::1", port: port))
            return
        }

        let endpoint = NettopEndpoint(host: normalizedHost, port: port)
        guard endpoint.isLoopback else { return }
        endpoints.insert(endpoint)
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }
}

public final class SystemProxyEndpointMonitor: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable (Set<NettopEndpoint>) -> Void

    private let lock = NSLock()
    private var endpoints: Set<NettopEndpoint> = []
    private var changeHandler: ChangeHandler?
    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?

    public init() {}

    public var currentLoopbackEndpoints: Set<NettopEndpoint> {
        lock.lock()
        defer { lock.unlock() }
        return endpoints
    }

    public func setChangeHandler(_ handler: ChangeHandler?) {
        lock.lock()
        changeHandler = handler
        lock.unlock()
    }

    /// 必须从拥有活跃 RunLoop 的线程调用；ByteTrace 在主线程启动和停止监听。
    public func start() {
        guard store == nil else {
            refresh()
            return
        }

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            nil,
            "com.nanvon.ByteTrace.system-proxy" as CFString,
            systemProxyDidChange,
            &context
        ) else {
            refresh()
            return
        }

        let keys = ["State:/Network/Global/Proxies"] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, keys, nil),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            refresh(using: store)
            return
        }

        self.store = store
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        refresh(using: store)
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        store = nil
    }

    fileprivate func refresh() {
        refresh(using: store)
    }

    private func refresh(using store: SCDynamicStore?) {
        guard let dictionary = SCDynamicStoreCopyProxies(store) as? [String: Any] else {
            updateEndpoints([])
            return
        }
        updateEndpoints(SystemProxyEndpointParser.loopbackEndpoints(from: dictionary))
    }

    private func updateEndpoints(_ next: Set<NettopEndpoint>) {
        lock.lock()
        let didChange = endpoints != next
        endpoints = next
        let handler = changeHandler
        lock.unlock()
        if didChange {
            handler?(next)
        }
    }
}

private func systemProxyDidChange(
    _ store: SCDynamicStore,
    _ changedKeys: CFArray,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    let monitor = Unmanaged<SystemProxyEndpointMonitor>.fromOpaque(info).takeUnretainedValue()
    monitor.refresh()
}
