# 应用更新

ByteTrace 使用 Sparkle 2.10.0 检查、验证和安装更新。设置页当前版本旁与应用菜单提供「检查更新」入口；仅在发现新版本后，菜单栏面板底部显示版本号与「下载」按钮，点击只打开已有更新窗口，不重新检查。各入口共用一个更新器和独立窗口；窗口关闭后下载继续，再次打开可查看进度。自动检查默认开启，可在设置中关闭；下载与安装必须由用户确认。

更新日志使用原生 SwiftUI 文本显示。发布时合并 `release-notes/v*.md`，客户端只显示当前安装版本之后的变化。日志读取失败不阻止安装，可打开发布页查看。更新包、更新日志和 appcast 均需签名；ZIP 解压前校验签名。安装退出前停止采集并保存最终样本，写入失败时取消退出并提供重试。

## 本地开发与版本

`swift run ByteTraceApp` 缺少应用 bundle 元数据，更新窗口会提示改用已打包应用。Xcode 工程引用 Sparkle，可用于运行 `.app`；框架嵌入及更新行为应在实际构建后验证。正式打包仍使用 `./Scripts/package_app.sh`，脚本复制框架并由内向外签名安装助手、XPC 服务、框架和外层应用。

`Packaging/Info.plist` 的 `CFBundleShortVersionString` 仍是发布版本真值。打包时 `CFBundleVersion` 自动同步为该值，appcast 使用相同版本进行比较。直接用 Xcode 运行时，plist 内的 `CFBundleVersion` 也应与显示版本同步。更新功能首次随正式版本发布后生效；此前版本需要手动安装一次。首次包含更新功能的版本仍需等待后续更高版本，才能验收实际替换安装。

## 更新签名配置

`Packaging/Info.plist` 保存 ByteTrace 独立 Ed25519 公钥；对应私钥保存在登录钥匙串的 Sparkle 账户 `com.nanvon.ByteTrace`，以及仓库 `nanvon/byte-trace` 的 GitHub Actions Secret：

- Variable：`SPARKLE_PUBLIC_ED_KEY`，必须与 plist 中的 `SUPublicEDKey` 一致
- Secret：`SPARKLE_PRIVATE_ED_KEY`，仅用于发布时签名

私钥不写入源码、应用包或构建日志。请保留钥匙串备份，后续版本必须使用同一签名身份。更换开发机时，可用 Sparkle 官方 `generate_keys --account com.nanvon.ByteTrace -x <私密路径>` 导出，再在新机器用 `-f` 导入；导出文件不能提交到 Git。

## 发布流程

按既有流程更新版本、编写本版更新说明并推送对应 tag。发布 workflow 会检查签名配置，打包并签名 ZIP，生成 `appcast.xml` 和 `release-notes.md`，与 DMG、校验文件一起上传到草稿 Release，全部完成后再公开，避免更新源提前引用尚未上传的包。

更新源固定为 `https://github.com/nanvon/byte-trace/releases/latest/download/appcast.xml`。公钥或私钥配置缺失、密钥不匹配、版本或架构不一致时发布失败。

## 验收

本地可执行 `swift build --product ByteTraceApp` 检查编译，`./Scripts/package_app.sh` 验证框架嵌入和签名。手动打开生成的应用，从应用菜单或设置中检查更新，核对仅在发现新版本后出现的面板底部入口，以及日志、取消下载、关闭并重开窗口、跳过版本、断网重试和安装重启后的统计连续性。完整安装验收需要更新源中有更高版本的真实签名包。

参考：[Sparkle 自定义界面](https://sparkle-project.org/documentation/custom-user-interfaces/)、[签名与更新配置](https://sparkle-project.org/documentation/customization/)。
