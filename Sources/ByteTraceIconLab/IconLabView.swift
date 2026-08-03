import SwiftUI

struct IconLabView: View {
    @State private var mode: IconMode = .menuBar
    @State private var menuBarSpec = TraceMarkSpec.menuBar
    @State private var appSpec = TraceMarkSpec.appIcon
    @State private var showGrid = false
    @State private var exportMessage: String?

    private var spec: Binding<TraceMarkSpec> {
        mode == .menuBar ? $menuBarSpec : $appSpec
    }

    var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 360)
            preview
                .frame(minWidth: 520)
        }
        .frame(minWidth: 880, minHeight: 620)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("", selection: $mode) {
                    ForEach(IconMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                slider("线宽", value: spec.strokeWidth, range: 1.2...3.6)
                slider("箭头倍率", value: spec.arrowScale, range: 0.78...1.2)

                Toggle("显示 24 网格", isOn: $showGrid)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Button("导出到桌面 ByteTraceIcon/") { export() }
                        .controlSize(.large)

                    Button("恢复默认值") {
                        menuBarSpec = .menuBar
                        appSpec = .appIcon
                    }
                    .buttonStyle(.link)

                    if let exportMessage {
                        Text(exportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                Text("先把 16 / 18pt 那一档调到能认出来，再看大图。反过来一定翻车。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    @ViewBuilder
    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if mode == .menuBar {
                    menuBarPreview
                } else {
                    appIconPreview
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var menuBarPreview: some View {
        Group {
            section("真实尺寸 · 浅色菜单栏") {
                HStack(spacing: 22) {
                    ForEach([CGFloat(16), 18, 20, 22], id: \.self) { size in
                        labeled(size) {
                            MenuBarTile(spec: menuBarSpec, showGrid: showGrid, size: size, tint: .black)
                                .padding(6)
                                .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }

            section("真实尺寸 · 深色菜单栏") {
                HStack(spacing: 22) {
                    ForEach([CGFloat(16), 18, 20, 22], id: \.self) { size in
                        labeled(size) {
                            MenuBarTile(spec: menuBarSpec, showGrid: showGrid, size: size, tint: .white)
                                .padding(6)
                                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }

            section("菜单栏实景 · 18pt 夹在系统图标之间") {
                HStack(spacing: 16) {
                    Image(systemName: "wifi").frame(width: 18, height: 18)
                    Image(systemName: "battery.75").frame(width: 18, height: 18)
                    MenuBarTile(spec: menuBarSpec, showGrid: false, size: 18, tint: .primary)
                    Image(systemName: "magnifyingglass").frame(width: 18, height: 18)
                    Image(systemName: "switch.2").frame(width: 18, height: 18)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            }

            section("放大校对") {
                MenuBarTile(spec: menuBarSpec, showGrid: showGrid, size: 260, tint: .primary)
                    .padding(18)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var appIconPreview: some View {
        Group {
            section("真实尺寸") {
                HStack(alignment: .bottom, spacing: 22) {
                    ForEach([CGFloat(16), 32, 64, 128], id: \.self) { size in
                        labeled(size) {
                            AppIconTile(spec: appSpec, showGrid: showGrid, size: size)
                        }
                    }
                }
            }

            section("放大校对") {
                AppIconTile(spec: appSpec, showGrid: showGrid, size: 320)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func labeled<Content: View>(_ size: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            content()
            Text("\(Int(size))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func export() {
        do {
            let url = try IconExporter.exportAll(spec: appSpec, menuBarSpec: menuBarSpec)
            exportMessage = "已导出到 \(url.path)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportMessage = error.localizedDescription
        }
    }
}
