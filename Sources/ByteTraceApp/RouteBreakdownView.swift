import ByteTraceCore
import SwiftUI

enum RouteColor {
    static func color(for route: TrafficRoute?) -> Color {
        switch route {
        case .direct: return .green
        case .proxied: return .purple
        case .proxyNode: return .indigo
        case .proxyRuleDirect: return .teal
        case nil: return Color.primary.opacity(0.18)
        }
    }
}

/// 流量路径卡片：一条分段条加逐项明细。
struct RouteBreakdownCard: View {
    let title: String
    let breakdown: RouteBreakdown
    let footnote: String?
    var showsProxiedShare = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if showsProxiedShare, breakdown.hasKnownRoute {
                    Text("经代理 \(percent(breakdown.fraction(of: breakdown.proxiedBytes)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            RouteSegmentBar(breakdown: breakdown, height: 8)

            VStack(spacing: 6) {
                ForEach(breakdown.items) { item in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(RouteColor.color(for: item.route))
                            .frame(width: 8, height: 8)
                        Text(item.title)
                        Spacer()
                        Text(ByteTraceViewModel.formatBytes(item.bytes))
                            .foregroundStyle(.secondary)
                        Text(percent(breakdown.fraction(of: item.bytes)))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            }

            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .cardSurface()
    }

    static func footnote(usesToday: Bool) -> String {
        var text = "直连：没有经过本机代理或 TUN。经代理：通过系统代理或 TUN 交给本机代理 / VPN 转发。"
        if usesToday {
            text += "「最近 1 小时」的路径按今天的数据统计。"
        }
        return text
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }
}

struct RouteSegmentBar: View {
    let breakdown: RouteBreakdown
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(breakdown.items) { item in
                    Rectangle()
                        .fill(RouteColor.color(for: item.route))
                        .frame(width: max(0, geometry.size.width * breakdown.fraction(of: item.bytes) - 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}
