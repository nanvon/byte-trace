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

/// 给自定义交互区域提供轻量的鼠标悬停背景。
struct InteractiveHoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    let opacity: Double
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? opacity : 0))
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

extension View {
    func interactiveHoverHighlight(
        cornerRadius: CGFloat = 8,
        opacity: Double = 0.05
    ) -> some View {
        modifier(
            InteractiveHoverHighlight(
                cornerRadius: cornerRadius,
                opacity: opacity
            )
        )
    }
}

/// 保留 plain button 的轻量外观，同时提供悬停和按下反馈。
struct ByteTraceActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ButtonLabel(configuration: configuration)
    }

    private struct ButtonLabel: View {
        let configuration: ButtonStyle.Configuration

        var body: some View {
            configuration.label
                .interactiveHoverHighlight(opacity: 0.06)
                .opacity(configuration.isPressed ? 0.58 : 1)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}
