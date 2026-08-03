import SwiftUI

enum IconMode: String, CaseIterable, Identifiable {
    case menuBar = "菜单栏模板"
    case appIcon = "应用图标"

    var id: String { rawValue }
}

enum TracePalette {
    /// 深石墨底，配蓝色上行与柔白下行，菜单栏则统一交给系统着色。
    static let graphiteTop = Color(red: 0.094, green: 0.133, blue: 0.176)
    static let graphiteBottom = Color(red: 0.043, green: 0.063, blue: 0.082)
    static let cobalt = Color(red: 0.306, green: 0.471, blue: 1.0)
    static let cloud = Color(red: 0.949, green: 0.961, blue: 0.969)
    static let slate = Color(red: 0.490, green: 0.537, blue: 0.588)
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
                upColor: TracePalette.cobalt,
                downColor: TracePalette.cloud,
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
            upColor: tint,
            downColor: tint,
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
        TraceMarkView(spec: spec, upColor: .black, downColor: .black)
            .frame(width: size, height: size)
    }
}
