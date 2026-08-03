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

    private var image: Image {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon@3x", withExtension: "png"),
              let nsImage = NSImage(contentsOf: url) else {
            return Image(systemName: "arrow.up.arrow.down.circle")
        }

        nsImage.isTemplate = true
        return Image(nsImage: nsImage)
    }
}
