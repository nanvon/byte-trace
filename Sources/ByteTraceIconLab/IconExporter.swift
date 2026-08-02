import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum IconExporter {
    /// macOS .iconset 要求的固定文件名与像素尺寸。
    private static let iconsetEntries: [(name: String, points: CGFloat, scale: CGFloat)] = [
        ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
        ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
        ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
        ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
        ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2)
    ]

    static func exportAll(spec appSpec: TraceMarkSpec, menuBarSpec: TraceMarkSpec) throws -> URL {
        let root = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/ByteTraceIcon", isDirectory: true)

        let iconset = root.appendingPathComponent("ByteTrace.iconset", isDirectory: true)
        let menuBar = root.appendingPathComponent("MenuBar", isDirectory: true)

        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: menuBar, withIntermediateDirectories: true)

        for entry in iconsetEntries {
            let view = AppIconTile(spec: appSpec, showGrid: false, size: entry.points)
            try writePNG(view, size: entry.points, scale: entry.scale,
                         to: iconset.appendingPathComponent("\(entry.name).png"))
        }

        // 菜单栏用矢量 PDF，系统按需渲染，比位图更稳。
        try writePDF(TemplateExportTile(spec: menuBarSpec, size: 18), size: 18,
                     to: menuBar.appendingPathComponent("MenuBarIcon.pdf"))

        for scale in [CGFloat(1), 2, 3] {
            let suffix = scale == 1 ? "" : "@\(Int(scale))x"
            try writePNG(TemplateExportTile(spec: menuBarSpec, size: 18), size: 18, scale: scale,
                         to: menuBar.appendingPathComponent("MenuBarIcon\(suffix).png"))
        }

        runIconUtil(iconset: iconset, output: root.appendingPathComponent("ByteTrace.icns"))
        return root
    }

    private static func writePNG<V: View>(_ view: V, size: CGFloat, scale: CGFloat, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: size, height: size))
        renderer.scale = scale
        renderer.isOpaque = false

        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
              ) else {
            throw ExportError.renderFailed(url.lastPathComponent)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.renderFailed(url.lastPathComponent)
        }
    }

    private static func writePDF<V: View>(_ view: V, size: CGFloat, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: size, height: size))
        var failure: Error?

        renderer.render { _, draw in
            var box = CGRect(x: 0, y: 0, width: size, height: size)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                failure = ExportError.renderFailed(url.lastPathComponent)
                return
            }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }

        if let failure { throw failure }
    }

    /// iconutil 是系统自带命令行工具，仅本地转换，失败不影响已导出的 PNG。
    private static func runIconUtil(iconset: URL, output: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    enum ExportError: LocalizedError {
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .renderFailed(let name): "渲染失败：\(name)"
            }
        }
    }
}
