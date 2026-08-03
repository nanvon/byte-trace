import SwiftUI

/// 图标在 24×24 设计网格上定义，App Icon 与菜单栏共用同一条几何路径。
enum TraceGeometry {
    static let grid: CGFloat = 24

    static let upLeftX: CGFloat = 5.0
    static let upRightX: CGFloat = 16.0
    static let downLeftX: CGFloat = 7.0
    static let downRightX: CGFloat = 18.0
    static let upTipY: CGFloat = 1.6
    static let downTipY: CGFloat = 22.4
}

struct TraceMarkSpec: Equatable {
    var strokeWidth: CGFloat
    var arrowScale: CGFloat

    static let menuBar = TraceMarkSpec(
        strokeWidth: 2.6,
        arrowScale: 1.02
    )

    static let appIcon = TraceMarkSpec(
        strokeWidth: 2.75,
        arrowScale: 1.0
    )
}

enum TraceDirection {
    case up
    case down
}

enum TraceMark {
    /// 蓝色上行路径：左下进入，经过两段柔和转折后向右上离开。
    static func upPath(_ spec: TraceMarkSpec) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: TraceGeometry.upLeftX, y: 18.4))
        path.addLine(to: CGPoint(x: TraceGeometry.upLeftX, y: 14.0))
        path.addCurve(
            to: CGPoint(x: 8.5, y: 10.2),
            control1: CGPoint(x: TraceGeometry.upLeftX, y: 12.3),
            control2: CGPoint(x: 7.0, y: 10.2)
        )
        path.addLine(to: CGPoint(x: 12.8, y: 10.2))
        path.addCurve(
            to: CGPoint(x: TraceGeometry.upRightX, y: 6.8),
            control1: CGPoint(x: 14.8, y: 10.2),
            control2: CGPoint(x: TraceGeometry.upRightX, y: 8.8)
        )
        path.addLine(to: CGPoint(x: TraceGeometry.upRightX, y: 5.1))
        return path
    }

    /// 白色下行路径：右上进入，经过两段柔和转折后向左下离开。
    static func downPath(_ spec: TraceMarkSpec) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: TraceGeometry.downRightX, y: 7.0))
        path.addLine(to: CGPoint(x: TraceGeometry.downRightX, y: 9.4))
        path.addCurve(
            to: CGPoint(x: 14.5, y: 14.0),
            control1: CGPoint(x: TraceGeometry.downRightX, y: 12.2),
            control2: CGPoint(x: 16.0, y: 14.0)
        )
        path.addLine(to: CGPoint(x: 10.0, y: 14.0))
        path.addCurve(
            to: CGPoint(x: TraceGeometry.downLeftX, y: 16.8),
            control1: CGPoint(x: 8.5, y: 14.0),
            control2: CGPoint(x: TraceGeometry.downLeftX, y: 15.1)
        )
        path.addLine(to: CGPoint(x: TraceGeometry.downLeftX, y: 18.9))
        return path
    }

    static func arrowhead(
        tip: CGPoint,
        direction: TraceDirection,
        scale: CGFloat
    ) -> Path {
        let length = 3.8 * scale
        let width = 4.8 * scale
        let stemWidth = 1.45 * scale
        let halfWidth = width / 2
        let halfStem = stemWidth / 2

        var path = Path()
        switch direction {
        case .up:
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x - halfWidth, y: tip.y + length * 0.72))
            path.addLine(to: CGPoint(x: tip.x - halfStem, y: tip.y + length * 0.72))
            path.addLine(to: CGPoint(x: tip.x - halfStem, y: tip.y + length))
            path.addLine(to: CGPoint(x: tip.x + halfStem, y: tip.y + length))
            path.addLine(to: CGPoint(x: tip.x + halfStem, y: tip.y + length * 0.72))
            path.addLine(to: CGPoint(x: tip.x + halfWidth, y: tip.y + length * 0.72))
        case .down:
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x - halfWidth, y: tip.y - length * 0.72))
            path.addLine(to: CGPoint(x: tip.x - halfStem, y: tip.y - length * 0.72))
            path.addLine(to: CGPoint(x: tip.x - halfStem, y: tip.y - length))
            path.addLine(to: CGPoint(x: tip.x + halfStem, y: tip.y - length))
            path.addLine(to: CGPoint(x: tip.x + halfStem, y: tip.y - length * 0.72))
            path.addLine(to: CGPoint(x: tip.x + halfWidth, y: tip.y - length * 0.72))
        }
        path.closeSubpath()
        return path
    }
}

struct TraceMarkView: View {
    var spec: TraceMarkSpec
    var upColor: Color
    var downColor: Color
    var showGrid: Bool = false

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let scale = min(size.width, size.height) / TraceGeometry.grid
            context.scaleBy(x: scale, y: scale)

            if showGrid {
                drawGrid(in: &context)
            }

            let style = StrokeStyle(
                lineWidth: spec.strokeWidth,
                lineCap: .round,
                lineJoin: .round
            )

            context.stroke(TraceMark.upPath(spec), with: .color(upColor), style: style)
            context.fill(
                TraceMark.arrowhead(
                    tip: CGPoint(x: TraceGeometry.upRightX, y: TraceGeometry.upTipY),
                    direction: .up,
                    scale: spec.arrowScale
                ),
                with: .color(upColor)
            )

            context.stroke(TraceMark.downPath(spec), with: .color(downColor), style: style)
            context.fill(
                TraceMark.arrowhead(
                    tip: CGPoint(x: TraceGeometry.downLeftX, y: TraceGeometry.downTipY),
                    direction: .down,
                    scale: spec.arrowScale
                ),
                with: .color(downColor)
            )
        }
    }

    private func drawGrid(in context: inout GraphicsContext) {
        var grid = Path()
        for step in stride(from: 0, through: TraceGeometry.grid, by: 1) {
            grid.move(to: CGPoint(x: step, y: 0))
            grid.addLine(to: CGPoint(x: step, y: TraceGeometry.grid))
            grid.move(to: CGPoint(x: 0, y: step))
            grid.addLine(to: CGPoint(x: TraceGeometry.grid, y: step))
        }
        context.stroke(grid, with: .color(.gray.opacity(0.18)), lineWidth: 0.08)
    }
}
