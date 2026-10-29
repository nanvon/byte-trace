import ByteTraceCore
import SwiftUI

/// 菜单栏面板与主窗口共用的应用图标；无可用路径时显示占位符号。
struct AppIconView: View {
    let record: DailyUsageRecord
    let size: CGFloat

    var body: some View {
        if let path = record.bundlePath ?? record.executablePath {
            Image(nsImage: AppIconCache.icon(forPath: path))
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
