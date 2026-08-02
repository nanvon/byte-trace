# ByteTrace Network Extension Lab

这是与正式 ByteTrace App 隔离的 macOS Network Extension 原型工程。当前阶段只验证工程边界、SDK API、Provider 生命周期和 flow-close 数据模型，不安装或启用系统扩展，也不写入正式 SQLite。

## 当前路线

- 宿主：`NEFilterManager`，仅提供显式的保存“禁用配置”命令；默认 `--describe` 不改变系统状态；
- Provider：`NEFilterDataProvider`，对新 flow 和数据回调一律 pass-through；
- 统计：给新 flow 返回 `shouldReport = true`，只在 `flowClosed` report 上取入站/出站字节，避免把周期性 report 重复计数；同时生成版本化 `flow_closed` JSON 事件，供后续与 `nettop` 对账；
- 元数据：记录 flow ID、开始/关闭时间、方向、audit token、可选 hostname、可选 WebKit URL；当前 macOS SDK 不提供 `sourceAppIdentifier`，因此还没有稳定的 Bundle ID 归属；
- 隐私：不保存请求内容、Header、Cookie、查询参数或响应正文；结构化事件只进入 private OSLog，且不包含原始 audit token；Provider 尚未接入正式存储。

`NEFilterControlProvider` 没有作为 macOS target 创建：当前 macOS SDK 将它标记为 macOS unavailable，macOS 原型采用 `NEFilterDataProvider + NEFilterManager`。

## 生成和验证

需要 Xcode、macOS SDK 和 XcodeGen：

```bash
cd NetworkExtensionLab
xcodegen
xcodebuild -project ByteTraceNetworkExtensionLab.xcodeproj \
  -scheme ByteTraceNetworkExtensionLab \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

运行前置检查（只读，不安装或启用扩展）：

```bash
zsh Scripts/preflight.sh
```

也可以传入已构建的 `.app` 路径，额外检查签名类型：

```bash
zsh Scripts/preflight.sh \
  /path/to/ByteTraceNetworkExtensionLab.app
```

纯数据模型测试：

```bash
xcodebuild -project ByteTraceNetworkExtensionLab.xcodeproj \
  -scheme ByteTraceNetworkExtensionLabTests \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/byte-trace-ne-lab-tests-derived \
  build-for-testing

xcrun xctest \
  /tmp/byte-trace-ne-lab-tests-derived/Build/Products/Debug/ByteTraceNetworkExtensionLabTests.xctest
```

如果本机的 `xcodebuild test` 能访问 `testmanagerd`，也可以直接使用 `test`；在受限执行环境中，`xcrun xctest` 可以绕过测试管理服务完成这组纯模型测试。

显式执行 `--save-disabled-config` 才会调用 `NEFilterManager.saveToPreferences`，保存一个保持 disabled 的配置；本阶段不运行这个命令。真正安装、签名、用户授权、启用和网络对账需要 Apple Developer entitlement 与后续实机验收，不能由当前 ad-hoc 正式 App 打包流程代替。
