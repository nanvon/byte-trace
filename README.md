# ByteTrace

ByteTrace 是面向个人 macOS 的菜单栏应用，应用级流量统计 MVP 使用系统 `/usr/bin/nettop` 作为只读数据源。

当前完成：阶段 4/5 正式应用级采集、CSV 解析、进程归属、SQLite 日聚合、分钟级时间桶、菜单栏 UI，以及主窗口概览、可见主机名实验、设置和应用详情页面；连接级 `nettop` 数据已进入独立的 `host_usage_buckets` 实验表，不写回正式应用统计。

域名/主机流量评估结论已收敛：正式产品不实现通用的完整 URL、HTTP 请求解析或 Network Extension 系统级采集；允许进入后续开发的是基于连接级 `nettop` 的“可见网站/主机名排行”实验能力。该能力只展示能观察到的 hostname，IP-only 和无法归属的流量统一归入“无法识别/其他”，不改变正式应用级统计口径。[Network Extension Lab](NetworkExtensionLab/README.md) 仍仅保留为编译、SDK API 和数据模型研究记录。

在“只在自己的 Mac 上使用、不购买 Apple Developer Program”的前提下，这个粗略排行仍然可以开发，因为它只读取系统自带的 `/usr/bin/nettop`，不依赖 Network Extension entitlement；因此不需要每年 ¥688。需要付费开发者计划的是 Network Extension Provider 的授权、签名、安装和启用，不是普通 `nettop` 采集。[Apple 会员资格对比](https://developer.apple.com/cn/support/compare-memberships/)、[Apple 中国大陆注册与续订说明](https://developer.apple.com/cn/help/account/membership/enrolling-in-the-app/)、[Apple DTS：免费 Personal Team 不支持 Network Extension Provider](https://developer.apple.com/forums/thread/128767)

```bash
swift build
swift test
swift run ByteTraceProbe --duration 15
# 连接级 hostname 实验探针，不写入正式数据库
swift run ByteTraceConnectionProbe --duration 5
# 多轮稳定性验证，每轮独立建立基线
swift run ByteTraceConnectionProbe --duration 5 --runs 3 --process mihomo
# macOS 菜单栏应用（开发运行）
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
- SQLite 本地存储：`apps`、`daily_usage`、`usage_buckets`、`host_usage_buckets`、`collector_events` 五张表，WAL、外键约束、忙等待与 schema version；hostname 实验表支持独立查询、清理和保留周期；
- 日聚合与分钟级时间桶：按系统当前本地日历归档，分钟桶用于最近 10 分钟、最近 1 小时和趋势查询，日汇总继续用于今天、本周、本月；内存队列有上限，停止时批量 flush。

真实探针会使用内存 SQLite 做端到端验证；正式应用默认数据库路径为：

```text
~/Library/Application Support/<bundle identifier>/usage.sqlite3
```

`ByteTraceApp` 已提供 SwiftUI `MenuBarExtra` 和独立主窗口：popover 提供今日下载/上传/总量、应用排序列表、代理运输与系统进程折叠区、采集状态和刷新入口；主窗口提供“概览 / 可见主机名 / 设置”导航、时间范围选择、趋势图、全局 hostname 排行、覆盖率、应用详情和应用内 hostname 排行。设置页支持数据库位置、登录时启动、正式统计与 hostname 实验数据的独立清理、分钟级保留策略和当前范围 JSON 导出。`Scripts/package_app.sh` 可生成带 `ByteTrace.icns` 的 ad-hoc 签名 `.app`、`ByteTrace.dmg` 和 `ByteTrace.zip`；本机 release 构建、资源复制和签名校验已通过，真实 Finder/菜单栏启动仍需在有 WindowServer 的 macOS 桌面会话验收。

## 界面架构约定

ByteTrace 采用“菜单栏 popover + 主窗口 + 主窗口内页面”的桌面结构：

- 菜单栏 popover：提供今日流量、采集状态、刷新等快速查看和操作，并作为打开主窗口的入口；
- 主窗口：作为可持续存在的完整应用容器；
- 主窗口页面：包含“概览”“可见主机名”和“设置”，应用详情作为概览内的导航目的地。

设置页属于主窗口内的页面，不作为长期独立的设置窗口维护。打开主窗口后，菜单栏 popover 正常消失是预期行为；主窗口及其内部页面不应再依赖 popover 的生命周期，也不应通过挂在 `MenuBarExtra` 临时窗口上的 `.sheet` 承载最终设置流程。`ByteTraceViewModel` 作为共享模型，由 popover 和主窗口共同使用。

## 流量展示与产品边界

ByteTrace 的目标分为两层：“在什么时间段、由哪个应用、以什么粒度产生了多少流量”是正式能力；“可见网站/主机名排行”是有限的实验能力；通用域名、完整 URL 和 HTTP 请求明细不属于当前产品范围。

### 1. 应用级时间范围查询（已接入初版）

主窗口的概览页应支持预设时间范围：

- 最近 10 分钟；
- 最近 1 小时；
- 今天；
- 本周；
- 本月。

这些定义为查询范围，而不是强制的采样周期。主窗口初版已展示下载、上传、总量、应用排行、流量趋势和应用详情；时间口径使用系统本地时区和本地日历。

数据层现在保留 `daily_usage` 日汇总和 `usage_buckets` 分钟级时间桶：短时间范围从分钟桶查询，今天/本周/本月从日汇总查询。旧版本已有的日汇总不会被伪造分摊到历史分钟桶；分钟趋势从新版本开始积累。设置页默认永不自动清理分钟桶，也可选择保留 7/30/90 天；启用后会在同一事务中删除超过周期的 `usage_buckets` 和 `host_usage_buckets`，不会影响 `daily_usage` 日汇总。后续仍需补充长时间运行和真实数据下的趋势验收。

### 2. 可见网站/主机名排行（有限实验能力）

“应用访问了哪些网址”需要先区分主机名、域名、完整 URL 和 HTTP 请求。基于当前“不购买 Apple Developer Program、只在自己的 Mac 上使用”的前提，允许实现一个粗略排行：

- 不需要购买开发者计划或支付 ¥688 年费；这是普通 macOS App 使用系统 `nettop` 连接级输出的本地能力，不是 Network Extension 方案；
- 当前 `/usr/bin/nettop` 解析链只提供时间、进程、入站字节和出站字节，没有域名或 URL 字段，因此正式应用级统计不能直接补出访问网址；
- 连接级 `nettop` 在部分连接中可以提供 hostname、远端端口、协议和字节，适合做“可见网站/主机名排行”；
- 排行可以按全部应用汇总，也可以在应用详情中按应用汇总；但只纳入能关联到 hostname 和应用的可见连接；
- IP-only、hostname 缺失或无法归属的流量不在界面展示原始 IP，统一放到“无法识别/其他”，并显示可识别流量覆盖率；
- 连接级数据存在应用差异、代理转发、连接复用和生命周期缺口，因此排行必须标注为“实验数据/部分可见”，不能替代应用级总量；
- DNS 观察和用户手动配置的代理只能作为未来诊断辅助，不作为当前排行的主数据源；浏览器或单应用扩展也不作为通用依赖；
- HTTPS 下的完整 URL 路径、查询参数和请求内容不作为通用能力；
- macOS Network Extension 可以作为技术路线参考，但当前免费账号不能完成 Provider 的授权、安装和启用，因此不纳入正式产品。

这里的 `hostname` 是系统在连接级观察中实际暴露或解析出的主机名，不等于已经确认的网页 URL。`nettop` 的连接/地址名称解析、socket 字节和进程汇总存在天然差异；因此排行必须标记为“实验数据/部分可见”，不能对所有 App 承诺完整覆盖。[nettop 手册](https://keith.github.io/xcode-man-pages/nettop.1.html)

详细的数据源评估和历史验证记录见 [DOMAIN_TRAFFIC_REQUIREMENTS.md](DOMAIN_TRAFFIC_REQUIREMENTS.md)；Network Extension 的冻结记录见 [DOMAIN_TRAFFIC_SOURCE_DECISION.md](DOMAIN_TRAFFIC_SOURCE_DECISION.md)。

### 3. 当前正式产品承诺

- 使用 `/usr/bin/nettop -P` 采集进程级应用流量；
- 按应用展示上传、下载和总流量；
- 支持最近 10 分钟、最近 1 小时、今天、本周和本月；
- 支持趋势图、应用排行、应用详情、历史查询和本地数据管理；
- 支持导出当前时间范围 JSON，正式应用汇总与 hostname 实验排行/覆盖率分块保存；
- 数据默认保存在本机，不上传网络内容；
- 连接级 hostname 排行作为独立的实验能力，不修改应用级总量；原始 IP、DNS、代理和浏览器扩展结果不作为通用正式数据。

ByteTrace 的产品定位是“本地 macOS 应用级流量统计工具，并提供有限的可见网站/主机名排行实验能力”，不是“通用的应用内 URL 监控工具”。

### 4. 剩余验收顺序

1. 在有 WindowServer 的 macOS 桌面会话中从 Finder 启动 `.app`，验收菜单栏 popover、主窗口三页、应用详情和设置交互；
2. 验收网络切换、睡眠唤醒、正式 collector 与 hostname collector 的独立退出重启和 flush；
3. 用已知大小流量对账正式应用总量与 hostname 实验覆盖率，确认实验数据不重复计入正式总量；
4. 完成 24 小时连续运行、数据库增长和保留策略验收；
5. release 版本检查和 `.app/.zip/.dmg` 产物核对已完成；当前版本为 `0.1.4`，尚未创建或推送 release tag，待明确发布时再执行。

以上顺序只使用现有 `nettop` 采集链。完整 URL、HTTP 请求解析、Network Extension、系统级代理和限速扩展不作为后续开发任务。

`Scripts/package_app.sh` 会将 Release 可执行文件封装为 `dist/ByteTrace.app`，写入菜单栏应用所需的 `Info.plist`，完成严格签名校验后同时生成 `dist/ByteTrace.dmg` 和 `dist/ByteTrace.zip`。DMG 内含 `/Applications` 拖拽快捷方式。默认使用 ad-hoc 签名；GitHub Release 固定使用 `-` 身份，不读取 Apple 证书或签名 Secrets。

GitHub Actions 已按 CI / Release 分离：

- `.github/workflows/ci.yml`：在 macOS Apple Silicon 与 Intel runner 上执行 Swift build、Swift tests、打包输入校验和本地 ad-hoc 包构建；
- `.github/workflows/release.yml`：推送与版本一致的 `v*` tag 后，构建两个 macOS 架构，使用 ad-hoc 签名，生成 DMG、ZIP 和 SHA-256 checksums，再创建 GitHub Release；
- `Scripts/check-release-version.py`：要求 tag 必须等于 `Packaging/Info.plist` 的 `CFBundleShortVersionString`，例如当前版本 `0.1.4` 必须推送 `v0.1.4`。

与 `cc-trace` 一致，ByteTrace Release 不使用 Apple Developer ID 证书，也不执行 Apple 公证。macOS 产物首次打开可能需要在系统设置中手动放行；这属于 ad-hoc 签名的预期行为。

阶段 5 的基础生命周期已实现：正式 collector 和 hostname collector 都按 `1/2/5/10/30` 秒独立退避重启，网络路径变化时安全停止并 flush、恢复后重建基线，睡眠前 flush、唤醒后重新建立基线，正常退出会回收自己创建的 `nettop`。当前核心测试 43/43 通过，正式与连接级 120 秒真实探针均通过；连接级对账结果按实际情况标记为 `partially_visible`，不把实验数据冒充正式总量。网络切换、真实睡眠唤醒、已知大小流量对账和 24 小时连续运行仍待有 WindowServer 的 macOS 实机验证。
