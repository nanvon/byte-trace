# ByteTrace

ByteTrace 是面向个人 macOS 的菜单栏应用，应用级流量统计 MVP 使用系统 `/usr/bin/nettop` 作为只读数据源。

当前完成：阶段 4 采集、CSV 解析、进程归属、SQLite 日聚合与菜单栏 UI。

```bash
swift build
swift test
swift run ByteTraceProbe --duration 15
# macOS 菜单栏原型
swift run ByteTraceApp
# 生成可从 Finder 启动的 ad-hoc 签名包
./Scripts/package_app.sh
```

探针固定启动：

```text
/usr/bin/nettop -n -P -d -x -L 0 -s 1
```

默认运行 15 秒，忽略第一帧基线，输出后续非零增量，并在退出时只回收自己创建的 `nettop` 子进程。

`ByteTraceCore` 当前包含：

- 流式 CSV 解析：按字段名读取、支持重复表头与分块输入，遇到坏行跳过并记录事件；
- PID / Bundle / 父进程链归属：按 PID + 启动时间缓存，Helper 仅在位于 `.app/Contents/` 内时合并到外层应用；
- 精确代理分类：`mihomo`、`ClashBar`、`CCBar` 作为 `proxy_transport` 单独记录，不对应用流量做反向抵扣；
- SQLite 本地存储：`apps`、`daily_usage`、`collector_events` 三张表，WAL、外键约束、忙等待与 schema version；
- 日聚合：按系统当前自然日归档，内存队列有上限，停止时批量 flush。

真实探针会使用内存 SQLite 做端到端验证；正式应用默认数据库路径为：

```text
~/Library/Application Support/<bundle identifier>/usage.sqlite3
```

`ByteTraceApp` 已提供 SwiftUI `MenuBarExtra` 应用：今日下载/上传/总量、应用排序列表、代理运输与系统进程折叠区、采集状态、数据库位置、登录时启动和清空统计设置均已接入。`Scripts/package_app.sh` 可生成 ad-hoc 签名的 `.app`，并已完成本机 LaunchServices 启动验证；Developer ID 签名、公证和 Gatekeeper 验收仍属于后续工作。

`Scripts/package_app.sh` 会将 Release 可执行文件封装为 `dist/ByteTrace.app`，写入菜单栏应用所需的 `Info.plist`，默认使用 ad-hoc 签名。若有 Developer ID，可通过 `BYTE_TRACE_SIGNING_IDENTITY` 指定签名身份。

GitHub Actions 已按 CI / Release 分离：

- `.github/workflows/ci.yml`：在 macOS Apple Silicon 与 Intel runner 上执行 Swift build、Swift tests、打包输入校验和本地 ad-hoc 包构建；
- `.github/workflows/release.yml`：推送与版本一致的 `v*` tag 后，构建两个 macOS 架构，导入 Developer ID 证书，签名、提交 Apple 公证、staple ticket、生成 zip 和 SHA-256 checksums，再创建 GitHub Release；
- `Scripts/check-release-version.py`：要求 tag 必须等于 `Packaging/Info.plist` 的 `CFBundleShortVersionString`，例如版本 `0.1.0` 必须推送 `v0.1.0`。

正式 Release 需要在 GitHub Actions Secrets 配置以下值；证书、私钥和 `.p8` 内容只以 Base64 Secret 注入 runner，不进入仓库：

```text
MACOS_CERTIFICATE_P12_BASE64
MACOS_CERTIFICATE_PASSWORD
MACOS_KEYCHAIN_PASSWORD
APPLE_DEVELOPER_ID_APPLICATION
APPLE_API_KEY_ID
APPLE_API_ISSUER
APPLE_API_KEY_BASE64
```

其中 `APPLE_DEVELOPER_ID_APPLICATION` 应是完整的 `Developer ID Application: ... (TEAMID)` 身份；`APPLE_API_KEY_BASE64` 是 App Store Connect API Key 的 `.p8` 文件内容。当前本机只有 Apple Development 证书，所以本地和未配置 Secrets 的环境只使用 ad-hoc 路径，不能代替正式 Developer ID 公证发布。

阶段 5 的基础生命周期已实现：异常退出按 `1/2/5/10/30` 秒退避重启，睡眠前 flush、唤醒后重新建立基线，正常退出会回收自己创建的 `nettop`。仍待网络切换、真实睡眠唤醒、已知大小流量对账、24 小时运行，以及 Developer ID 签名后的 Gatekeeper 验收。
