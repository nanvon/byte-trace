import Foundation

/// 外部通道（`-P`）重启间隙补偿。
///
/// 每次重启 nettop 都要丢弃一帧基线，停止到新基线之间的流量原本会丢失。`-P` 的基线是
/// 进程生命周期累计值，且不同 nettop 实例之间一致（同时运行两个实例实测差异只在采样时刻的
/// 秒内误差），因此「新基线 − (旧基线 + 期间增量)」就是漏记的字节。
///
/// 保守约束：
/// - 只补偿上一轮会话见过的进程令牌（`名称.pid`），间隙内新启动的进程不补；
/// - 停止到新基线超过 `maximumGap` 不补（睡眠、长时间断网）；
/// - 差值为负按 0 处理，单个进程按 `maximumBytesPerSecond` 设上限；
/// - `arm()` 之后要先收到一帧基线才开始记录，`reset()` 后不再记录，
///   避免另一个实例接管期间的流量被重复补记。
public struct NettopRestartGapRecovery: Sendable {
    public static let maximumGap: TimeInterval = 60
    /// 单进程单方向的速率上限（10 Gbps），只用于排除异常值。
    public static let maximumBytesPerSecond: Double = 1_250_000_000
    static let staleEntryAge: TimeInterval = 60 * 60

    private struct Counter: Sendable {
        var download: Int64
        var upload: Int64
        var lastSeenAt: Date
    }

    private var isArmed = false
    private var hasBaseline = false
    private var counters: [String: Counter] = [:]
    private var lastFrameAt: Date?
    private var framesSincePrune = 0

    public init() {}

    /// 开始一轮采集会话（应用开始采集时调用）。
    public mutating func arm() {
        reset()
        isArmed = true
    }

    /// 结束会话并清空状态（停止采集、释放数据目录锁时调用）。
    public mutating func reset() {
        isArmed = false
        hasBaseline = false
        counters.removeAll()
        lastFrameAt = nil
        framesSincePrune = 0
    }

    /// 处理新的基线帧，返回可补记的间隙流量（`sampledAt` 取基线行的时间）。
    public mutating func recover(fromBaseline rows: [NettopDelta], at date: Date) -> [NettopDelta] {
        guard isArmed else { return [] }

        var recovered: [NettopDelta] = []
        if hasBaseline, let lastFrameAt {
            let elapsed = date.timeIntervalSince(lastFrameAt)
            if elapsed >= 0, elapsed <= Self.maximumGap {
                let limit = Int64(max(elapsed, 1) * Self.maximumBytesPerSecond)
                for row in rows {
                    guard let previous = counters[row.processName] else { continue }
                    let download = min(max(row.downloadBytes - previous.download, 0), limit)
                    let upload = min(max(row.uploadBytes - previous.upload, 0), limit)
                    guard download > 0 || upload > 0 else { continue }
                    recovered.append(
                        NettopDelta(
                            sampledAt: row.sampledAt,
                            processName: row.processName,
                            downloadBytes: download,
                            uploadBytes: upload
                        )
                    )
                }
            }
        }

        counters.removeAll(keepingCapacity: true)
        for row in rows {
            counters[row.processName] = Counter(
                download: row.downloadBytes,
                upload: row.uploadBytes,
                lastSeenAt: date
            )
        }
        hasBaseline = true
        lastFrameAt = date
        framesSincePrune = 0
        return recovered
    }

    /// 记录一帧增量（非基线帧，包括 `stop()` 时吐出的最后一帧）。
    public mutating func record(_ deltas: [NettopDelta], at date: Date) {
        guard isArmed, hasBaseline else { return }
        for delta in deltas {
            var counter = counters[delta.processName] ?? Counter(download: 0, upload: 0, lastSeenAt: date)
            counter.download = saturatingAdd(counter.download, delta.downloadBytes)
            counter.upload = saturatingAdd(counter.upload, delta.uploadBytes)
            counter.lastSeenAt = date
            counters[delta.processName] = counter
        }
        lastFrameAt = date

        framesSincePrune += 1
        if framesSincePrune >= 120 {
            framesSincePrune = 0
            // 长时间没有流量的条目多半已退出；删掉只会让它下次不被补偿，不会多计。
            counters = counters.filter { date.timeIntervalSince($0.value.lastSeenAt) <= Self.staleEntryAge }
        }
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}
