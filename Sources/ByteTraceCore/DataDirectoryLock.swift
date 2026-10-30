import Darwin
import Foundation

/// 数据目录独占锁：同一个 SQLite 只允许一个 ByteTrace 实例采集。
/// 已安装版本与 Xcode 运行版本共用 bundle ID 和数据库，同时采集会把每个字节记两次。
/// 使用 `flock`，进程退出（含崩溃）时内核自动释放，不会留下需要手动清理的陈旧锁。
public final class DataDirectoryLock: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    public init(url: URL) {
        self.url = url
    }

    public static func defaultLockURL(bundleIdentifier: String) -> URL {
        UsageStore.defaultDatabaseURL(bundleIdentifier: bundleIdentifier)
            .deletingLastPathComponent()
            .appendingPathComponent("collector.lock")
    }

    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0
    }

    /// 非阻塞获取；已持有时直接返回 true。
    public func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 { return true }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }

        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        descriptor = fd
        return true
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}
