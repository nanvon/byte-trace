import SwiftUI

/// 替代系统 DisclosureGroup 的分组容器:整行(标题、数量、chevron)都是展开/收起的点击区域,
/// 避免 macOS 上只有小箭头可点的问题。
struct CollapsibleUsageSection<Content: View>: View {
    let title: String
    let count: Int
    let symbolName: String
    let tint: Color
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .interactiveHoverHighlight()
            .pointingHandCursor()
            .accessibilityLabel("\(title),\(isExpanded ? "收起" : "展开")")

            if isExpanded {
                content()
            }
        }
    }
}
