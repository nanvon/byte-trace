import ByteTraceCore
import SwiftUI

/// 菜单栏面板与主窗口共用的应用图标；自身没有图标时借用相近应用的图标，都找不到时显示占位符号。
struct AppIconView: View {
    let record: DailyUsageRecord
    let size: CGFloat

    var body: some View {
        if let icon = AppIconCache.icon(for: record) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(size > 28 ? .title3 : .body)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
