import ByteTraceCore
import SwiftUI

enum RouteColor {
    static let direct = Color.green
    static let proxy = Color.indigo
    /// 未读到 mihomo 连接表、无法分摊出口的经代理流量。
    static let unknown = Color.gray
}

/// 直连 / 代理拆分卡片：标题行带代理占比，下面一条分段条和一行图例。
struct RouteSplitCard: View {
    let title: String
    let split: RouteSplit
    /// 显示在卡片底部的必要说明。
    var note: String?
    /// 悬停时显示的口径说明。
    var help: String?
    var showsProxyShare = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                if showsProxyShare, split.isRepresentative {
                    Text("\(split.isPartial ? "已区分部分中" : "")代理 \(percent(split.proxyFraction))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            RouteSegmentBar(split: split, height: 8)

            HStack(spacing: 20) {
                legend(color: RouteColor.direct, title: "直连", bytes: split.directBytes)
                legend(color: RouteColor.proxy, title: "代理流量", bytes: split.proxyBytes)
                if split.unknownBytes > 0 {
                    legend(color: RouteColor.unknown, title: "出口未知", bytes: split.unknownBytes)
                }
                Spacer(minLength: 0)
            }

            if let note = combinedNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .cardSurface()
        .help(help ?? "")
    }

    private func legend(color: Color, title: String, bytes: Int64) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
            Text(ByteTraceViewModel.formatBytes(bytes))
                .fontWeight(.semibold)
            Text(percent(split.fraction(of: bytes)))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private var combinedNote: String? {
        var parts: [String] = []
        if let note { parts.append(note) }
        if split.isPartial, split.unattributedBytes > 0 {
            parts.append("另有 \(ByteTraceViewModel.formatBytes(split.unattributedBytes)) 发生在路径统计启用前，未区分直连 / 代理。")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// 菜单栏、主窗口共用的口径说明。
    static func help(for split: RouteSplit) -> String {
        var text = "代理流量：经代理节点（机场）转发的应用流量；进了代理内核但命中直连规则的算直连。"
        text += "出口未确认的短连接按同一应用已确认的比例估算。不含加密协议开销，机场计费通常略高。"
        if split.unknownBytes > 0 {
            text += "未读到 mihomo 连接表的经代理流量无法区分出口，记为「出口未知」，不计入代理流量。"
        }
        if split.isPartial, split.unattributedBytes > 0 {
            text += "路径统计启用前的 \(ByteTraceViewModel.formatBytes(split.unattributedBytes)) 没有路径记录，不计入。"
        }
        return text
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }
}

struct RouteSegmentBar: View {
    let split: RouteSplit
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments, id: \.title) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, geometry.size.width * split.fraction(of: segment.bytes) - 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private var segments: [(title: String, color: Color, bytes: Int64)] {
        [
            ("直连", RouteColor.direct, split.directBytes),
            ("代理", RouteColor.proxy, split.proxyBytes),
            ("出口未知", RouteColor.unknown, split.unknownBytes)
        ].filter { $0.bytes > 0 }
    }
}
