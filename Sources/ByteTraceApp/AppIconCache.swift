import AppKit
import ByteTraceCore

/// 应用图标缓存。
///
/// `NSWorkspace.icon(forFile:)` 会走 IconServices IPC 与磁盘 I/O。直接写在 SwiftUI 的
/// `body` 里意味着每次列表刷新都要为每一行重新取一次图标——今日榜单常有近百个进程，
/// 采样中能看到明显的 IconServices 开销。图标在应用生命周期内基本不变，缓存即可。
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    /// 超过上限整体清空而不是做 LRU：图标数量本就有限，命中率高，
    /// 极端情况下重建一次的成本远低于维护淘汰顺序。
    private static let maxCount = 512
    /// 列表行 → 借用图标的应用路径；路径变化（应用升级、移动）时键随之变化。
    private static var resolvedPaths: [String: String?] = [:]

    static func icon(for record: DailyUsageRecord) -> NSImage? {
        let key = [record.appKey, record.bundlePath ?? "", record.executablePath ?? ""].joined(separator: "\u{1F}")
        let path: String?
        if let cached = resolvedPaths[key] {
            path = cached
        } else {
            path = AppIconResolver.iconPath(for: record)
            if resolvedPaths.count >= maxCount {
                resolvedPaths.removeAll(keepingCapacity: true)
            }
            resolvedPaths[key] = path
        }
        return path.map(icon(forPath:))
    }

    static func icon(forPath path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if cache.count >= maxCount {
            cache.removeAll(keepingCapacity: true)
        }
        cache[path] = icon
        return icon
    }
}
