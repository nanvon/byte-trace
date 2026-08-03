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
swift run ByteTraceProbe --duration 15                                    # 应用级采集
swift run ByteTraceConnectionProbe --duration 5                           # 连接级主机名采集
swift run ByteTraceConnectionProbe --duration 5 --runs 3 --process mihomo # 多轮，每轮独立建立基线
```

`package_app.sh` 环境变量：`BYTE_TRACE_SIGNING_IDENTITY`（默认 `-`，ad-hoc）、`BYTE_TRACE_SWIFT_TRIPLE`（交叉构建目标）。

## 架构：两条互不干扰的采集管线

这是理解本仓库最关键的一点。两条管线各自启动一个 `nettop` 子进程、各自解析、各自入库，**永远不能互相修正或合并**：

| | 正式应用级 | 实验连接级 |
| --- | --- | --- |
| 采集器 | `NettopCollector` | `NettopConnectionCollector` |
| nettop 参数 | `-n -P -d -x -L 0 -s 1` | `-d -x -L 0 -s 1` |
| 解析器 | `NettopCSVParser` | `NettopConnectionCSVParser` |
| 落库 | `UsageAggregator` → `daily_usage` + `usage_buckets` | `NettopHostUsageAggregator` → `host_usage_buckets` |
| 用途 | 应用流量总量（产品的正式口径） | 「可见主机名」实验排行 |

参数差异是刻意的：`-P` 让 nettop 按进程汇总；`-n` 关闭名称解析，所以正式管线拿不到也不需要主机名，而连接级管线**省略 `-n` 正是为了让 nettop 暴露部分主机名**。

连接级数据是「部分可见」的，覆盖率远低于 100%。任何改动都不得用它去修正、抵扣或补全应用级总量——这条边界在 `docs/DOMAIN_TRAFFIC_DECISION.md` 中已作为最终决策记录。

### 数据流（正式管线）

```
nettop stdout
  → NettopCSVParser.consume()            解析出 NettopDelta（进程名 + 上下行字节）
  → ByteTraceViewModel.ingest()          NettopProcessToken 拆 pid → SystemProcessIdentityResolver
                                         → ProcessAttributionCache → AttributedProcess（appKey/分类）
  → UsageAggregator.ingest()             内存中按 (day, 分钟桶, appKey) 合并
  → UsageAggregator.flush()              每 5 秒定时器触发，一个事务写入 SQLite
  → ByteTraceViewModel.refresh()         回读 SQLite 刷新 UI
```

### 帧与基线

- nettop 每个采样周期重复输出一次以 `time` 开头的表头行；解析器**靠下一个表头到来才结束上一帧**（`beginFrame` 内先调 `completeCurrentFrame`）。因此流中最后一帧只会在 `stop()` / `finish()` 时才吐出。
- **首帧整帧丢弃**（`deltas = []`，仅置 `hasBaseline = true`）：`-d` 模式下首帧携带的是启动时刻的累计值而非增量。每次重启 nettop（重连、唤醒、网络切换）都会重新经历一次基线帧，这个间隙的流量必然丢失，属于已知取舍。
- 表头缺少 `time` / `bytes_in` / `bytes_out` / 进程列 → `incompatibleSchema`，采集**停止且不再自动重连**，避免写入脏数据。

### 连接级解析的行内状态

`NettopConnectionCSVParser` 的输入是两级结构：进程汇总行会写入 `currentProcessName`，随后含 `<->` 的连接行**继承这个进程名**。解析强依赖行顺序，改动 `parseLine` / `consumeLine` 时必须保持这个状态机。

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

五张表：`apps`、`daily_usage`（键 `day`+`app_key`）、`usage_buckets`（键 `bucket_start`+`app_key`，分钟粒度）、`host_usage_buckets`（键 `bucket_start`+`app_key`+`endpoint_kind`+`hostname`）、`collector_events`。

**迁移**：`UsageStore.migrate()` 用 `PRAGMA user_version`（当前 `schemaVersion = 3`）做累加式 `if currentVersion <= N` 分支。新增表/列时追加一个分支、在块内 `PRAGMA user_version = N+1`，并同步 `UsageStore.schemaVersion`。

**写入是累加而非幂等**：所有 upsert 都是 `ON CONFLICT ... DO UPDATE SET x = x + excluded.x`。同一批聚合重复 flush 会双计。`flush()` 成功后必须清空 pending（现有代码已如此）。

**时间口径混用，改动前先确认字段类型**：`daily_usage.day` 是本地日历的 `yyyy-MM-dd` 字符串；`*_buckets.bucket_start` 是 epoch 秒 `INTEGER`；`first_seen_at` / `last_seen_at` 是 `String(format: "%.6f")` 的**文本**（`host_usage_buckets` 的 upsert 直接对其做 SQL `MIN`/`MAX`，依赖定宽零填充下字典序等于数值序）。

**保留策略**只删两张分钟桶表（`purgeBuckets`），`daily_usage` 与 `apps` 不受影响；`clearAll()` 才清空全部五张表。

## 应用层

`ByteTraceApp` 用 `MenuBarExtra` + `.menuBarExtraStyle(.window)`，纯菜单栏形态由 `Info.plist` 的 `LSUIElement` 与 AppDelegate 里的 `setActivationPolicy(.accessory)` 共同保证。主窗口是独立的 `Window(id: "main")`。退出时 `applicationWillTerminate` → `ByteTraceViewModel.shutdown()` 落盘并只回收自己创建的子进程。

`ByteTraceViewModel`（`@MainActor`、`ObservableObject`、1200+ 行）是唯一的编排者，持有两个采集器、`UsageStore`、两个聚合器、所有定时器与生命周期监听。需要留意：

- **并发约定**：`NettopCollector` / `UsageStore` / `UsageAggregator` / `ProcessAttributionCache` 都是 `@unchecked Sendable` + `NSLock`；采集器回调经 `Task { @MainActor }` 跳回主线程。`SystemProcessIdentityResolver` 读 `NSRunningApplication` 时若不在主线程会 `DispatchQueue.main.sync`——不要从任何会阻塞主线程的路径调用它。
- **`hostAggregator` 是 struct 存成可选属性**，代码里是 `if var hostAggregator { ...; self.hostAggregator = hostAggregator }` 的取出—改—写回模式。忘记写回等于丢数据。
- **重连退避** `[1, 2, 5, 10, 30]` 秒，两条管线各有独立的 timer 与 attempt 计数；睡眠/唤醒（`NSWorkspace` 通知）与网络路径切换（`NWPathMonitor`）都会先停采集 + `flushNow()` 再走重连。
- **UI 刷新由 5 秒 flush 定时器驱动**（`flushNow()` 内部调 `refresh()`），没有独立的轮询。
- **「今天」是双数据源**：汇总数字来自 `daily_usage`，趋势图来自 `usage_buckets`（`usesBucketSummary` 与 `usesFineGrainedTimeline` 两个开关分别控制）。「最近 10 分钟 / 1 小时」两者都用分钟桶，「本周 / 本月」两者都用日汇总。
- **nettop 的时间字段只有时钟没有日期**，`sampleDate(for:)` 把「今天」的年月日嫁接上去，跨零点存在已知误差。
- 设置持久化：`UserDefaults` 键 `ByteTrace.showSystemProcesses`、`ByteTrace.usageRetentionPolicy`；登录时启动用 `SMAppService.mainApp`。
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
- `Sources/ByteTraceIconLab/` — 独立的图标生成工具（不依赖 `ByteTraceCore`），仅在需要重新导出 `Packaging/Resources/` 下的图标资源时使用。
- `docs/DOMAIN_TRAFFIC_EXPERIMENT.md` / `docs/DOMAIN_TRAFFIC_DECISION.md` — 域名流量数据源的调研、hostname 实验和最终决策，涉及主机名能力边界的改动前应先读结论部分。
