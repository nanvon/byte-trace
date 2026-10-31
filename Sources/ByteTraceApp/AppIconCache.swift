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
    /// 列表行 → 图标来源；路径变化（应用升级、移动）时键随之变化。
    private static var resolvedSources: [String: AppIconSource?] = [:]

    static func source(for record: DailyUsageRecord) -> AppIconSource? {
        let key = [record.appKey, record.bundlePath ?? "", record.executablePath ?? ""].joined(separator: "\u{1F}")
        if let cached = resolvedSources[key] { return cached }
        let source = AppIconResolver.source(for: record)
        if resolvedSources.count >= maxCount {
            resolvedSources.removeAll(keepingCapacity: true)
        }
        resolvedSources[key] = source
        return source
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
