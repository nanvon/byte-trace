import SwiftUI

/// 列表行内的占比条：轨道用系统分隔色，填充用强调色，浅色与深色模式自动适配。
struct UsageShareBar: View {
    /// 0...1，超出范围会被截断。
    let fraction: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * clampedFraction)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var clampedFraction: Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}
