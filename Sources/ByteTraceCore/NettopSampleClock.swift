import Foundation

/// nettop 的 `time` 列只有时钟没有日期（`HH:MM:SS.ffffff`），这里把它嫁接到 `now` 所在日期。
/// 零点前采样、零点后才处理的帧会被嫁接成「今天 23:59」，即未来约 24 小时，
/// 因此结果比 `now` 晚超过 1 小时时回退一天，落回昨天的日汇总。
public enum NettopSampleClock {
    static let futureTolerance: TimeInterval = 60 * 60

    public static func date(
        for rawValue: String,
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let timeParts = rawValue.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let clockPart = timeParts.first else { return now }
        let clock = clockPart.split(separator: ":")
        guard clock.count == 3,
              let hour = Int(clock[0]),
              let minute = Int(clock[1]),
              let second = Int(clock[2]),
              (0..<24).contains(hour),
              (0..<60).contains(minute),
              (0..<60).contains(second) else {
            return now
        }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = second
        if timeParts.count == 2 {
            let fractional = String(timeParts[1].prefix(9)).padding(
                toLength: 9,
                withPad: "0",
                startingAt: 0
            )
            components.nanosecond = Int(fractional) ?? 0
        }
        guard let date = calendar.date(from: components) else { return now }
        if date.timeIntervalSince(now) > futureTolerance,
           let previousDay = calendar.date(byAdding: .day, value: -1, to: date) {
            return previousDay
        }
        return date
    }
}
