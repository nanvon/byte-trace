# ByteTrace

ByteTrace 是面向个人 macOS 的菜单栏应用，应用级流量统计 MVP 使用系统 `/usr/bin/nettop` 作为只读数据源。

当前完成：阶段 4 采集、CSV 解析、进程归属、SQLite 日聚合、分钟级时间桶、菜单栏 UI，以及主窗口概览/设置导航和应用级流量详情初版；连接级 `nettop` CSV 解析目前仅作为域名路线的只读原型，尚未接入正式统计。

```bash
swift build
swift test
swift run ByteTraceProbe --duration 15
# 连接级只读原型，不写入正式数据库
swift run ByteTraceConnectionProbe --duration 5
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
- SQLite 本地存储：`apps`、`daily_usage`、`usage_buckets`、`collector_events` 四张表，WAL、外键约束、忙等待与 schema version；
- 日聚合与分钟级时间桶：按系统当前本地日历归档，分钟桶用于最近 10 分钟、最近 1 小时和趋势查询，日汇总继续用于今天、本周、本月；内存队列有上限，停止时批量 flush。

真实探针会使用内存 SQLite 做端到端验证；正式应用默认数据库路径为：

```text
~/Library/Application Support/<bundle identifier>/usage.sqlite3
```

`ByteTraceApp` 已提供 SwiftUI `MenuBarExtra` 和独立主窗口：popover 提供今日下载/上传/总量、应用排序列表、代理运输与系统进程折叠区、采集状态和刷新入口；主窗口提供“概览 / 设置”导航、时间范围选择、趋势图和应用详情初版。数据库位置、登录时启动、清空统计、分钟级数据积累状态和可选保留策略均已接入。`Scripts/package_app.sh` 可生成 ad-hoc 签名的 `.app` 和 `ByteTrace.zip`，并已完成本机 LaunchServices 启动验证。

## 界面架构约定

ByteTrace 采用“菜单栏 popover + 主窗口 + 主窗口内页面”的桌面结构：

- 菜单栏 popover：提供今日流量、采集状态、刷新等快速查看和操作，并作为打开主窗口的入口；
- 主窗口：作为可持续存在的完整应用容器；
- 主窗口页面：至少包含“概览”和“设置”，后续页面继续纳入主窗口导航。

设置页属于主窗口内的页面，不作为长期独立的设置窗口维护。打开主窗口后，菜单栏 popover 正常消失是预期行为；主窗口及其内部页面不应再依赖 popover 的生命周期，也不应通过挂在 `MenuBarExtra` 临时窗口上的 `.sheet` 承载最终设置流程。`ByteTraceViewModel` 作为共享模型，由 popover 和主窗口共同使用。

## 流量展示与访问明细路线

ByteTrace 将“看到了多少流量”扩展为“在什么时间段、由哪个应用、以什么粒度产生了多少流量”。应用级时间范围、趋势和应用详情已经接入初版；域名/URL 明细仍作为独立的后续探索路线。

### 1. 应用级时间范围查询（已接入初版）

主窗口的概览页应支持预设时间范围：

- 最近 10 分钟；
- 最近 1 小时；
- 今天；
- 本周；
- 本月。

这些定义为查询范围，而不是强制的采样周期。主窗口初版已展示下载、上传、总量、应用排行、流量趋势和应用详情；时间口径使用系统本地时区和本地日历。

数据层现在保留 `daily_usage` 日汇总和 `usage_buckets` 分钟级时间桶：短时间范围从分钟桶查询，今天/本周/本月从日汇总查询。旧版本已有的日汇总不会被伪造分摊到历史分钟桶；分钟趋势从新版本开始积累。设置页默认永不自动清理分钟桶，也可选择保留 7/30/90 天；启用后只删除超过周期的 `usage_buckets`，不会影响 `daily_usage` 日汇总。后续仍需补充长时间运行和真实数据下的趋势验收。

### 2. 应用内访问明细（后续探索）

“应用访问了哪些网址”需要先区分域名/主机和完整 URL：

- 当前 `/usr/bin/nettop` 解析链只提供时间、进程、入站字节和出站字节，没有域名或 URL 字段，因此现有采集数据不能直接补出访问网址；
- 域名级流量需要新的网络数据源，并且必须能把连接或流量与应用、域名关联；仅依赖 DNS 记录不能准确证明某个域名消耗了多少字节；
- HTTPS 下的完整 URL 路径通常不可见，若要支持只能针对特定浏览器/应用做扩展，或在用户明确授权下接入代理/TLS 检查等方案，不能承诺对所有应用通用支持；
- 首个可行目标应是“应用 → 域名/主机 → 流量”的尽力而为明细，并保留“未知域名/无法识别”分类，不从 IP 反向猜测域名。

访问明细涉及更高的隐私、权限、存储量和性能成本，应作为独立的可选能力评估，默认本地保存、明确告知采集范围，并在数据源和权限方案确定后再实现。详细的数据源评估、验收门和原型步骤见 [DOMAIN_TRAFFIC_REQUIREMENTS.md](DOMAIN_TRAFFIC_REQUIREMENTS.md)。当前继续以 `nettop` 的应用级统计作为稳定基线，不在本阶段接入域名采集。

`Scripts/package_app.sh` 会将 Release 可执行文件封装为 `dist/ByteTrace.app`，写入菜单栏应用所需的 `Info.plist`，完成严格签名校验后生成 `dist/ByteTrace.zip`。默认使用 ad-hoc 签名；GitHub Release 固定使用 `-` 身份，不读取 Apple 证书或签名 Secrets。

GitHub Actions 已按 CI / Release 分离：

- `.github/workflows/ci.yml`：在 macOS Apple Silicon 与 Intel runner 上执行 Swift build、Swift tests、打包输入校验和本地 ad-hoc 包构建；
- `.github/workflows/release.yml`：推送与版本一致的 `v*` tag 后，构建两个 macOS 架构，使用 ad-hoc 签名，生成 zip 和 SHA-256 checksums，再创建 GitHub Release；
- `Scripts/check-release-version.py`：要求 tag 必须等于 `Packaging/Info.plist` 的 `CFBundleShortVersionString`，例如当前版本 `0.1.3` 必须推送 `v0.1.3`。

与 `cc-trace` 一致，ByteTrace Release 不使用 Apple Developer ID 证书，也不执行 Apple 公证。macOS 产物首次打开可能需要在系统设置中手动放行；这属于 ad-hoc 签名的预期行为。

阶段 5 的基础生命周期已实现：异常退出按 `1/2/5/10/30` 秒退避重启，网络路径变化时安全停止并 flush、恢复后重建基线，睡眠前 flush、唤醒后重新建立基线，正常退出会回收自己创建的 `nettop`。网络切换、真实睡眠唤醒、已知大小流量对账和 24 小时连续运行仍待 macOS 实机验证。
