import SwiftUI

/// 图标在 24×24 设计网格上定义，所有坐标与线宽都是网格单位。
enum TraceGeometry {
    static let grid: CGFloat = 24
    static let baseY: CGFloat = 13
    static let entryX: CGFloat = 2.6
    static let upperForkX: CGFloat = 10
    static let lowerForkX: CGFloat = 13.4
    static let rightX: CGFloat = 21.2
}

struct TraceMarkSpec: Equatable {
    var strokeWidth: CGFloat = 2.0
    var branchCount: Int = 3
    var spread: CGFloat = 4.0
    var padScale: CGFloat = 1.0
    var trunkBoost: CGFloat = 1.0

    static let menuBar = TraceMarkSpec(
        strokeWidth: 2.4,
        branchCount: 2,
        spread: 4.8,
        padScale: 1.05,
        trunkBoost: 1.0
    )

    static let appIcon = TraceMarkSpec(
        strokeWidth: 2.0,
        branchCount: 3,
        spread: 4.0,
        padScale: 1.0,
        trunkBoost: 1.25
    )
}

extension TraceMarkSpec {
    /// 下支比上支略短、略缓，避免上下对称。
    var upperSpread: CGFloat { spread }
    var lowerSpread: CGFloat { spread * 0.88 }
}

enum TraceMark {
    /// 主干：入口焊盘一路直达最右侧，是唯一贯穿全宽的线。
    static func trunk(_ spec: TraceMarkSpec) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: TraceGeometry.entryX, y: TraceGeometry.baseY))
        path.addLine(to: CGPoint(x: TraceGeometry.rightX, y: TraceGeometry.baseY))
        return path
    }

    /// 分支：从主干上引出，各走一段 45° 斜切后转回水平。
    static func branches(_ spec: TraceMarkSpec) -> Path {
        var path = Path()
        let up = spec.upperSpread
        let down = spec.lowerSpread

        path.move(to: CGPoint(x: TraceGeometry.upperForkX, y: TraceGeometry.baseY))
        path.addLine(to: CGPoint(x: TraceGeometry.upperForkX + up, y: TraceGeometry.baseY - up))
        path.addLine(to: CGPoint(x: TraceGeometry.rightX, y: TraceGeometry.baseY - up))

        if spec.branchCount >= 3 {
            path.move(to: CGPoint(x: TraceGeometry.lowerForkX, y: TraceGeometry.baseY))
            path.addLine(to: CGPoint(x: TraceGeometry.lowerForkX + down, y: TraceGeometry.baseY + down))
            path.addLine(to: CGPoint(x: TraceGeometry.rightX, y: TraceGeometry.baseY + down))
        }
        return path
    }

    /// 焊盘半径依次递减，读作“同一入口分给不同应用的流量排行”。
    static func pads(_ spec: TraceMarkSpec) -> [(center: CGPoint, radius: CGFloat)] {
        var list: [(CGPoint, CGFloat)] = [
            (CGPoint(x: TraceGeometry.entryX, y: TraceGeometry.baseY), 1.55),
            (CGPoint(x: TraceGeometry.rightX, y: TraceGeometry.baseY - spec.upperSpread), 2.25),
            (CGPoint(x: TraceGeometry.rightX, y: TraceGeometry.baseY), 1.5)
        ]
        if spec.branchCount >= 3 {
            list.append((CGPoint(x: TraceGeometry.rightX, y: TraceGeometry.baseY + spec.lowerSpread), 1.05))
        }
        return list.map { (center: $0.0, radius: $0.1 * spec.padScale) }
    }
}

struct TraceMarkView: View {
    var spec: TraceMarkSpec
    var color: Color
    var padColor: Color
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

            context.stroke(
                TraceMark.trunk(spec),
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: spec.strokeWidth * spec.trunkBoost,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            context.stroke(TraceMark.branches(spec), with: .color(color), style: style)

            for pad in TraceMark.pads(spec) {
                let rect = CGRect(
                    x: pad.center.x - pad.radius,
                    y: pad.center.y - pad.radius,
                    width: pad.radius * 2,
                    height: pad.radius * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(padColor))
            }
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
