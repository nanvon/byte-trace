import AppKit
import SwiftUI

/// 菜单栏面板与主窗口共用的卡片底：浅色模式白底，深色模式随系统控件底色，配 0.5pt 描边与轻阴影。
struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

extension View {
    func cardSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }
}

/// 下行与上行在面板和主窗口里固定用这两种颜色。
enum TrafficColor {
    static let download = Color.blue
    static let upload = Color.orange
    static let proxy = Color.purple
}
