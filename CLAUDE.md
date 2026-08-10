# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目定位

ByteTrace 是常驻 macOS 菜单栏的应用级流量统计工具（Swift 6 / SPM / macOS 14+）。唯一数据源是系统只读命令 `/usr/bin/nettop`，数据写入本机 SQLite。不使用 Network Extension、不需要 root、不解析报文内容。

## 常用命令

```bash
swift build                                  # 构建
swift test                                   # 全部测试（XCTest）
swift test --filter UsageAggregatorTests     # 单个测试类
swift test --filter UsageAggregatorTests/testSamplesAcrossMidnightUseDifferentLocalDays  # 单个测试方法
swift run ByteTraceApp                       # 开发模式运行菜单栏应用
./Scripts/package_app.sh                     # 打包 dist/ 下的 .app / .dmg / .zip
```

调试探针（用 `:memory:` 数据库，**不写入正式 SQLite**）：

```bash
swift run ByteTraceProbe --duration 15 # 应用级采集
```

`package_app.sh` 环境变量：`BYTE_TRACE_SIGNING_IDENTITY`（默认 `-`，ad-hoc）、`BYTE_TRACE_SWIFT_TRIPLE`（交叉构建目标）。

## 架构：按接口拆分的双通道采集管线

ByteTrace 按接口拆分采集，避免高功耗的全接口连接级采集：外部通道始终运行；只有检测到已启用的本机系统代理端点时才运行回环通道，代理关闭后由系统通知立即停掉第二个子进程。

- 外部通道：`nettop -n -P -d -x -L 0 -s 5 -t external -J time,interface,state,bytes_in,bytes_out`。`-P` 按进程汇总，覆盖直连、TUN 和代理进程的外层连接。
- 回环通道：`nettop -n -d -x -L 0 -s 1 -t loopback -J time,interface,state,bytes_in,bytes_out`。连接级解析只用于补齐应用到 macOS 系统代理的流量；1 秒采样用于减少短连接在两个 5 秒采样点之间结束造成的漏记，落库和 UI 刷新仍保持低频。

系统代理端点通过 `SCDynamicStoreCopyProxies` 首次读取，并监听 `State:/Network/Global/Proxies` 变化；只接受启用的 HTTP／HTTPS／SOCKS 本机回环端点，因此不写死 `7890`、不轮询 Mihomo API。回环通道仅保留“远端端点精确等于当前系统代理”的应用侧连接，代理服务端连接和其他本地 IPC 全部丢弃。外部通道中的 `proxy:` 流量仍单独展示、不反向抵扣、不计入应用总量。端点仅参与内存过滤，不落库、不展示。

### 数据流（正式管线）

```
external nettop stdout (-P, external) ─┐
                                       ├→ NettopDelta（进程名 + 上下行字节）
loopback nettop stdout (connections) ──┘  → 精确匹配当前系统代理端点 → 按进程合并
  → ByteTraceViewModel.ingest()          NettopProcessToken 拆 pid → SystemProcessIdentityResolver
                                         → ProcessAttributionCache → AttributedProcess（appKey/分类）
  → UsageAggregator.ingest()             内存中按 (day, 分钟桶, appKey) 合并
  → UsageAggregator.flush()              每 5 秒定时器触发，一个事务写入 SQLite
  → ByteTraceViewModel.refresh()         回读 SQLite 刷新 UI
```

### 帧与基线

- nettop 每个采样周期重复输出一次以 `time` 开头的表头行；解析器**靠下一个表头到来才结束上一帧**（`beginFrame` 内先调 `completeCurrentFrame`）。因此流中最后一帧只会在 `stop()` / `finish()` 时才吐出。
- **两个通道分别丢弃首帧**（`deltas = []`，仅置 `hasBaseline = true`）：`-d` 模式下首帧携带的是启动时刻的累计值而非增量。每次重启 nettop（重连、唤醒、网络切换）都会重新经历一次基线帧，这个间隙的流量必然丢失，属于已知取舍。
- 外部通道表头缺少 `time` / `bytes_in` / `bytes_out` / 进程列 → 全部采集停止且不再自动重连，避免写入脏数据。回环通道还要求 `interface`；仅回环格式不兼容时，外部通道继续工作并提示系统代理流量暂不可统计。
- 两个子进程都设置 `NSUnbufferedIO=YES`：`-L 0` 输出到普通 Pipe 时默认会整块缓冲，精简 `-J` 列后低流量场景可能长时间收不到完整帧；禁用子进程 stdio 缓冲可按各自采样周期逐帧交付。
- 父进程读取 stdout 使用 POSIX `read()`；不要改回 `FileHandle.read(upToCount: 64KB)`，后者在低输出的 `-P` 通道上可能等到大块数据或 EOF 才返回，导致 UI 长时间收不到帧。
- **两个子进程的 stdin 都必须是父进程持有的空 `Pipe`**（`T0` 修复，勿改回 `/dev/null`）：nettop 是 curses 交互程序，会 poll stdin 等按键；`/dev/null` 永远立即可读并 EOF，导致 poll 死循环、子进程空转占满一个多核心（实测 124%–139% CPU）。空 pipe 写端被父进程持有且永不写入，stdin 永远不就绪。

## 进程归属（Attribution）

`ProcessAttributor.attribute()` 按固定优先级派生 `appKey`：

```
proxy:<rule>  →  bundle:<bundleID>  →  app:<bundlePath>  →  exec:<路径>  →  process:<名称>  →  unknown:<FNV哈希>
```

`appKey` 是 SQLite 的主键，**改动派生规则会切断历史数据的连续性**（老数据变成孤儿行）。

- `hostCandidate()` 会沿父进程链（最多 8 层）向上找「可执行文件位于其 `.app/Contents/` 内、且 bundlePath 最短」的祖先。这是 helper 进程（如浏览器子进程）能归属到主应用的原因。
- `ProcessAttributionCache` 以 `(pid, processStartTime)` 为键，规避 pid 复用。
- 分类 `AppCategory`：`userApp` / `systemProcess`（可执行文件位于 `/System/`、`/usr/bin/` 等前缀）/ `proxyTransport` / `unclassified`。
- 新增代理进程：在 `ProxyClassifier.defaultClassifier` 加一条 `ProxyRule`（可按 bundleID / 可执行路径 / 进程名匹配）。代理流量**单独展示、不做反向抵扣、不计入应用总量**——UI 各处统一用 `category != .proxyTransport` 过滤，新增汇总逻辑时必须沿用。

## 存储

自己封装的 `SQLiteDatabase`（直接调 SQLite3 C API，无第三方依赖），WAL + `busy_timeout=5000` + `foreign_keys=ON`。路径：`~/Library/Application Support/com.nanvon.ByteTrace/usage.sqlite3`。

四张表：`apps`、`daily_usage`（键 `accounting_version`+`day`+`app_key`）、`usage_buckets`（键 `accounting_version`+`bucket_start`+`app_key`，分钟粒度）、`collector_events`。

**迁移**：`UsageStore.migrate()` 用 `PRAGMA user_version`（当前 `schemaVersion = 6`）做累加式 `if currentVersion <= N` 分支。新增表/列时追加一个分支、在块内 `PRAGMA user_version = N+1`，并同步 `UsageStore.schemaVersion`。版本 5 会删除已废弃的 `host_usage_buckets` 实验表；版本 6 为日汇总和分钟桶加入 `accounting_version`。旧口径标为 1 并保留，当前双通道口径为 2，查询只返回当前口径，避免新旧数据直接相加。

**写入是累加而非幂等**：所有 upsert 都是 `ON CONFLICT ... DO UPDATE SET x = x + excluded.x`。同一批聚合重复 flush 会双计。`flush()` 成功后必须清空 pending（现有代码已如此）。

**时间口径混用，改动前先确认字段类型**：`daily_usage.day` 是本地日历的 `yyyy-MM-dd` 字符串；`usage_buckets.bucket_start` 是 epoch 秒 `INTEGER`；`apps.first_seen_at` / `last_seen_at` 是 `String(format: "%.6f")` 的文本。

**保留策略**只删分钟桶表（`purgeBuckets`）并按 30 天上限清理 `collector_events`（`purgeCollectorEvents`），`daily_usage` 与 `apps` 不受影响；`clearAll()` 才清空全部四张表。大量删除后按需 `VACUUM`（阻塞操作，在后台队列执行，绝不在主线程）。

## 应用层

`ByteTraceApp` 用 `MenuBarExtra` + `.menuBarExtraStyle(.window)`，纯菜单栏形态由 `Info.plist` 的 `LSUIElement` 与 AppDelegate 里的 `setActivationPolicy(.accessory)` 共同保证。主窗口是独立的 `Window(id: "main")`。退出时 `applicationWillTerminate` → `ByteTraceViewModel.shutdown()` 落盘并只回收自己创建的子进程。

`ByteTraceViewModel`（`@MainActor`、`ObservableObject`）是唯一的编排者，持有应用级采集器、`UsageStore`、聚合器、定时器与生命周期监听。需要留意：

- **并发约定**：`NettopCollector` / `UsageStore` / `UsageAggregator` / `ProcessAttributionCache` / `SystemProxyEndpointMonitor` 都是 `@unchecked Sendable` + `NSLock`；两个采集器分别在串行队列解析，回调经 `Task { @MainActor }` 跳回主线程。`SystemProcessIdentityResolver` 读 `NSRunningApplication` 时若不在主线程会 `DispatchQueue.main.sync`——不要从任何会阻塞主线程的路径调用它。
- **两个通道独立重连**，退避均为 `[1, 2, 5, 10, 30]` 秒；睡眠/唤醒（`NSWorkspace` 通知）与网络路径切换（`NWPathMonitor`）都会先停两个采集器 + `flushNow()` 再走重连。
- **UI 刷新由 5 秒 flush 定时器驱动**（`flushNow()` 内部调 `refresh()`），没有独立的轮询。
- **「今天」是双数据源**：汇总数字来自 `daily_usage`，趋势图来自 `usage_buckets`（`usesBucketSummary` 与 `usesFineGrainedTimeline` 两个开关分别控制）。「最近 10 分钟 / 1 小时」两者都用分钟桶，「本周 / 本月」两者都用日汇总。
- **nettop 的时间字段只有时钟没有日期**，`sampleDate(for:)` 把「今天」的年月日嫁接上去，跨零点存在已知误差。
- 设置持久化：`UserDefaults` 键 `ByteTrace.showSystemProcesses`、`ByteTrace.usageRetentionPolicy`（默认 90 天）；登录时启动用 `SMAppService.mainApp`。
- 导出 `formatVersion` 硬编码在 `exportCurrentRange(to:)`，结构变更时需同步 bump。

## 代码风格约定

- **所有面向用户的文案、错误消息、`displayName` 兜底值都是中文**（如 `"未知进程"`、`"无法识别/其他"`）。
- **字节累加一律饱和处理**：`addingReportingOverflow` 溢出时取 `Int64.max`，仓库里有多处同名 `saturatingAdd` 私有辅助方法，沿用就近的那个而不是新造。
- `ByteTraceCore` 的 public 类型显式书写 `public init`，模型一律 `Equatable, Sendable`。
- 不引入第三方依赖（`Package.swift` 当前零依赖）。

## 发布

版本号真值在 `Packaging/Info.plist` 的 `CFBundleShortVersionString`。发布时 git tag 必须是 `v<版本号>`，由 `Scripts/check-release-version.py` 在 CI 与 release 流程中强制校验；README 顶部的 version badge 需手动同步。

- `ci.yml`：push main / PR 时在 Apple Silicon + Intel runner 上跑 `swift build`、`swift test`、plist 校验与 ad-hoc 打包校验。
- `release.yml`：推 `v*` tag 触发，先校验版本再构建双架构产物、生成 DMG / ZIP / SHA-256 并建 Release。
- 全程 ad-hoc 签名，不使用 Developer ID 证书、不公证。

## 边缘目录

- `NetworkExtensionLab/` — **已冻结的研究工程**，独立 Xcode 项目（XcodeGen 生成），不在 `Package.swift` 里，不属于产品链路。除非明确要求，不要改动或尝试把它接入主应用。

图标资源的真实生产路径是 `Packaging/Resources/Brand/` 下的设计稿 PNG（`ByteTraceAppIconCentered.png` 1024x1024、`ByteTraceMenuBarIconSource.png` 199x199），经人工处理后手动导出为 `ByteTrace.iconset/` / `ByteTrace.icns` / `MenuBar/*.png|pdf`，不经任何脚本自动生成。曾存在的 `Sources/ByteTraceIconLab/` 图标生成工具与这条路径已脱钩（导出结果与实际图标资源存在几何差异），于 2026-08-03 移除，不要再新增或恢复。
