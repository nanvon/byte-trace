import AppKit
import SwiftUI

/// macOS 的普通按钮默认仍使用箭头光标；ByteTrace 的自定义操作控件明确提示可点击。
struct PointingHandCursorModifier: ViewModifier {
    @State private var cursorIsPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                updateCursor(isHovering)
            }
            .onDisappear {
                if cursorIsPushed {
                    NSCursor.pop()
                    cursorIsPushed = false
                }
            }
    }

    private func updateCursor(_ isHovering: Bool) {
        guard isHovering != cursorIsPushed else { return }

        if isHovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
        cursorIsPushed = isHovering
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

/// 在行内容背后画一条相对最大值的占比条，让用户一眼比出大小而不必逐行读数字。
struct UsageBarBackground: ViewModifier {
    let fraction: Double
    let tint: Color

    func body(content: Content) -> some View {
        content.background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.1))
                    .frame(width: proxy.size.width * max(0, min(1, fraction)))
            }
        }
    }
}

extension View {
    func usageBarBackground(fraction: Double, tint: Color = .accentColor) -> some View {
        modifier(UsageBarBackground(fraction: fraction, tint: tint))
    }
}

/// 鼠标悬停时给列表行加一层淡背景，弥补菜单栏/列表缺失的原生 hover 反馈。
struct RowHoverHighlight: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.05 : 0))
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    func rowHoverHighlight() -> some View {
        modifier(RowHoverHighlight())
    }
}

/// 保留 plain button 的轻量外观，同时在按下瞬间给出直接反馈。
struct ByteTraceActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.58 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
