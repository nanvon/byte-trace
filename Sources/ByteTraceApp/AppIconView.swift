import ByteTraceCore
import SwiftUI

/// 菜单栏面板与主窗口共用的应用图标；自身没有图标时借用相近应用的图标，
/// 对应不到具体应用的 Apple 系统服务显示苹果标志，都找不到时显示占位符号。
struct AppIconView: View {
    let record: DailyUsageRecord
    let size: CGFloat

    var body: some View {
        switch AppIconCache.source(for: record) {
        case .app(let path):
            Image(nsImage: AppIconCache.icon(forPath: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        case .appleLogo:
            symbol("apple.logo")
        case nil:
            symbol("app.dashed")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(size > 28 ? .title3 : .body)
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }
}
