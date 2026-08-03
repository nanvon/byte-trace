import AppKit
import SwiftUI

/// 菜单栏图标：把打包的 1x/2x/3x PNG 组装成多 representation 的模板图，
/// 交给 AppKit 按屏幕 backing scale 选择。直接运行裸可执行文件时回退到 SF Symbol。
@MainActor
struct ByteTraceMenuBarIcon: View {
    private static let pointSize: CGFloat = 18

    var body: some View {
        if let icon = Self.bundledIcon {
            // 不加 .resizable()：NSImage 已是 18pt 逻辑尺寸，
            // 重采样会绕开 AppKit 按 scale 选 representation 的逻辑。
            Image(nsImage: icon)
                .renderingMode(.template)
                .accessibilityLabel("ByteTrace 流量")
        } else {
            Image(systemName: "arrow.up.arrow.down.circle")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.pointSize, height: Self.pointSize)
                .accessibilityLabel("ByteTrace 流量")
        }
    }

    /// 打包资源在运行期不变，只在首次访问时读盘。
    @MainActor
    private static let bundledIcon: NSImage? = {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size)

        // url(forResource:) 不做 @2x 变体匹配，三档必须逐个显式加载。
        for suffix in ["", "@2x", "@3x"] {
            guard let url = Bundle.main.url(
                forResource: "MenuBarIcon\(suffix)",
                withExtension: "png"
            ), let rep = NSImageRep(contentsOf: url) else { continue }

            // 像素尺寸保持 18/36/54 不变，逻辑尺寸统一成 18pt，
            // AppKit 由两者的比值推断出每个 representation 的 scale。
            rep.size = size
            image.addRepresentation(rep)
        }

        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        return image
    }()
}
