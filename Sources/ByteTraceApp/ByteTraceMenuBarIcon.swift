import AppKit
import SwiftUI

/// 已打包的高分辨率 PNG 是菜单栏的 Template 资源；直接运行裸可执行文件时保留 SF Symbol 回退。
@MainActor
struct ByteTraceMenuBarIcon: View {
    var body: some View {
        image
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
            .accessibilityLabel("ByteTrace 流量")
    }

    /// 打包资源在运行期不变，缓存 NSImage 避免每次 body 重算时重复读盘。
    @MainActor
    private static var cachedIconImage: NSImage?

    private var image: Image {
        if let cached = Self.cachedIconImage {
            return Image(nsImage: cached)
        }
        guard let url = Bundle.main.url(forResource: "MenuBarIcon@3x", withExtension: "png"),
              let nsImage = NSImage(contentsOf: url) else {
            return Image(systemName: "arrow.up.arrow.down.circle")
        }

        nsImage.isTemplate = true
        Self.cachedIconImage = nsImage
        return Image(nsImage: nsImage)
    }
}
