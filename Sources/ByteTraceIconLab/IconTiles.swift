import SwiftUI

enum IconMode: String, CaseIterable, Identifiable {
    case menuBar = "菜单栏模板"
    case appIcon = "应用图标"

    var id: String { rawValue }
}

enum TracePalette {
    /// 近黑石墨，不用纯黑：纯黑在 Retina 上会显得比周围图标“陷下去”。
    static let graphiteTop = Color(red: 0.153, green: 0.149, blue: 0.141)
    static let graphiteBottom = Color(red: 0.086, green: 0.082, blue: 0.078)
    static let amber = Color(red: 0.910, green: 0.639, blue: 0.239)
    static let amberBright = Color(red: 0.965, green: 0.788, blue: 0.435)
}

/// 应用图标里图形不满格，留出系统圆角壳体的呼吸区。
struct AppIconTile: View {
    var spec: TraceMarkSpec
    var showGrid: Bool
    var size: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TracePalette.graphiteTop, TracePalette.graphiteBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            TraceMarkView(
                spec: spec,
                color: TracePalette.amber,
                padColor: TracePalette.amberBright,
                showGrid: showGrid
            )
            .padding(size * 0.19)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
    }
}

/// 菜单栏图标：只有 alpha 通道有意义，颜色交给系统按明暗自动反转。
struct MenuBarTile: View {
    var spec: TraceMarkSpec
    var showGrid: Bool
    var size: CGFloat
    var tint: Color

    var body: some View {
        TraceMarkView(
            spec: spec,
            color: tint,
            padColor: tint,
            showGrid: showGrid
        )
        .frame(width: size, height: size)
    }
}

/// 导出用：无外框、无背景、纯前景色，供 ImageRenderer 直接吃。
struct TemplateExportTile: View {
    var spec: TraceMarkSpec
    var size: CGFloat

    var body: some View {
        TraceMarkView(spec: spec, color: .black, padColor: .black)
            .frame(width: size, height: size)
    }
}
