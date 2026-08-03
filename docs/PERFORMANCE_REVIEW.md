# ByteTrace 性能与文档一致性审查

状态：审查完成。**本文只记录发现、证据与建议，未对代码做任何改动**，所有条目均未实施。

日期：2026-08-02
审查对象：`d6defbf`（ByteTrace 0.1.5）
审查方式：逐文件精读 22 个 Swift 源文件 + 三份项目文档交叉核对

> **2026-08-02 合并记录**：另有一次独立静态审查（覆盖 12 个源文件，范围为本文子集）产出的报告已并入本文，重复结论未重复收录。合并新增：`M13`、`P1-9`、`P2-10`、`P2-11`、`P2-12`，以及 `M2` / `H4` 的补充说明和第十一节第 10 项。该次审查对 `S1` 的严重度判定为「严重」，依据是估算而非实测，**已按第九节的实机数据否决，此处不采纳**。

---

## 审查范围与方法

### 已覆盖

| 范围 | 文件 |
| --- | --- |
| 采集层 | `NettopCollector.swift`、`NettopConnectionCollector.swift` |
| 解析层 | `NettopCSVParser.swift`、`NettopConnectionCSVParser.swift`、`CSVLineParser.swift`、`NettopEndpoint.swift` |
| 归属层 | `ProcessIdentity.swift`、`ProcessAttributor.swift`、`ProxyClassifier.swift` |
| 存储层 | `UsageStore.swift`、`UsageAggregator.swift`、`SQLiteDatabase.swift`、`UsageModels.swift`（部分） |
| 主机名实验 | `NettopHostUsage.swift`、`NettopHostUsageQuery.swift`、`NettopReconciliation.swift` |
| 应用层 | `ByteTraceViewModel.swift`、`ByteTraceApp.swift`、`MainWindowView.swift`、`MenuBarView.swift`、`HostUsageView.swift`、`SettingsView.swift` |
| 文档 | `README.md`、`docs/DOMAIN_TRAFFIC_EXPERIMENT.md`、`docs/DOMAIN_TRAFFIC_DECISION.md` |

### 未覆盖（须知悉，避免误认为已审）

- `Sources/ByteTraceProbe/main.swift`、`Sources/ByteTraceConnectionProbe/main.swift` —— **未读**。因此 README 与需求文档中的探针命令行参数（`--duration` / `--numeric` / `--process` / `--runs`）**未经核实**。
- `NetworkExtensionLab/` —— 独立 Xcode 实验工程，按文档已冻结，不在本次范围。
- `Sources/ByteTraceIconLab/` —— 图标工具，非生产路径。
- `Packaging/` 目录文件清单 —— **未列出**，因此无法核实「没有 `.entitlements` 文件」这一文档声明。
- `UsageModels.swift` 仅读前 60 行（确认模型为 `Equatable`）。

### 方法限制

**所有标记为【需实测】的条目在本次审查中均未实际测量。** 审查期间 Bash 工具不可用，无法运行 `nettop` 采样、`sample`、`fs_usage`、`sqlite3 EXPLAIN QUERY PLAN` 等验证命令。第十一节给出的验证方案**尚未执行**。

定量校准（第九节）使用的是 `docs/DOMAIN_TRAFFIC_EXPERIMENT.md` 中已有的 2026-08-02 实机探针数据，非本次新测。

---

## 摘要

功能完整，口径隔离与正确性纪律扎实。问题集中在「每帧数据 → 进程归属 → 入库」这条每秒执行数百次的链路上，且**全部运行在主线程**（`ByteTraceViewModel` 标注 `@MainActor`）。

核心判断：

> **这是一个正确性纪律很强、性能纪律缺位的项目。**
>
> 凡是文档立过验收门的地方（口径隔离、不展示 IP、覆盖率透明、时间一致），代码执行得相当到位；凡是文档没提过要求的地方（CPU、内存、主线程占用、长期增长），就出现了会随运行时长恶化的缺陷。
>
> **三份文档无一处提及资源开销** —— 这不是巧合，而是根因。

---

## 一、严重

### S2 · 进程归属完全无缓存，且在主线程做磁盘 I/O

> 本次审查的**头号问题**。编号保留 S2 以与下文校准说明对应。

**调用链**：`ByteTraceViewModel.swift:750-753`（`ingest`）与 `:806-808`（`ingestHostUsage`）

```swift
let identity = resolver.resolve(token)                 // ← 无任何缓存
let attributed = attributionCache.attribute(identity)  // ← 缓存在这一层，为时已晚
```

`SystemProcessIdentityResolver.resolve()`（`ProcessIdentity.swift:101-144`）每次调用执行 **1 + 最多 8 层祖先 = 最多 9 次** `snapshot(for:)`（`:155-179`）。每次 snapshot 包含：

| 调用 | 位置 | 开销 |
| --- | --- | --- |
| `NSRunningApplication(processIdentifier:)` | `ProcessIdentity.swift:189` | LaunchServices 跨进程查询 |
| `proc_pidpath` | `:232-243` | syscall + 两次 4096 字节数组分配 |
| `canonicalPath` → `resolvingSymlinksInPath()` | `:258-264` | **realpath(3) 文件系统 syscall** |
| `Bundle.init(url:)` | `:161` | **读取 Info.plist，磁盘 I/O** |
| `object(forInfoDictionaryKey:)` ×2 | `:165-166` | plist 查询 |
| `proc_pidinfo` | `:211-230` | syscall |

**根因是缓存层次放错位置**：`ProcessAttributionCache` 的 key 是 `(pid, processStartTime)`（`ProcessAttributor.swift:202-205`），而 `processStartTime` **只能从 `resolve()` 的返回值里取得**。即：必须先付完整的 resolve 代价，才能拿到缓存键。缓存只挡住了相对便宜的 `attribute()`，昂贵部分完全没挡住。

**线程**：`ByteTraceViewModel` 标注 `@MainActor`（`:135`），`handle → ingest → resolve` 全链路在主线程。旁证：`ProcessIdentity.swift:197-204` 的 `runningApplicationSnapshot` 中 `DispatchQueue.main.sync` 分支永远走不到，实际是死代码。

- **风险**：严重
- **定性**：【已确认】（调用链与 `@MainActor` 标注可直接证明）；单次耗时与总占比【需实测】
- **量级**：约 225–585 次 snapshot/秒（校准依据见第九节）
- **最小修复**：在 `resolve()` 内加 `pid → identity` 缓存，先用便宜的 `proc_pidinfo` 取 `startTime` 作校验键，命中则跳过 `NSRunningApplication` / `Bundle` / `realpath`

---

### S3 · `ProcessAttributionCache` 永不淘汰，长期运行内存单调增长

**证据**：`ProcessAttributor.swift:209`

```swift
private var cache: [CacheKey: AttributedProcess] = [:]
```

清理方法 `removeAll()`（`:236`）经 grep 确认**在 App 中从未被调用** —— 仅 `hostAggregator.removeAll()` 被调用（`ByteTraceViewModel.swift:424`、`:453`）。

key 含 `processStartTime`，因此每个短命进程（shell、xpc helper、更新器）都会占用一个**永久**条目，每条含 6 个 String。

- **风险**：高
- **定性**：【已确认】；增长速率【需实测】
- **最小修复**：加 LRU 上限（如 2000 条），或在 flush 时按「最近 N 分钟未见」淘汰

---

## 二、高风险

### H1 · 两个 nettop 进程重复采集，连接级已含进程级汇总却被丢弃

```text
NettopCollector:           nettop -n -P -d -x -L 0 -s 1   （进程级）
NettopConnectionCollector: nettop    -d -x -L 0 -s 1      （连接级）
```

两个进程各自每秒遍历全部 socket，采集开销翻倍。

**关键**：`NettopConnectionCSVParser` **已经解析出进程级汇总** `processSummaries`（`:296-302`），但被丢弃：

```swift
// ByteTraceViewModel.swift:778
case let .frameCompleted(_, _, deltas, isBaseline):  // 第 2 个 _ 就是 processSummaries
```

**可行性经文档数据交叉验证**（详见第八节）：

- 文档证明连接**明细**无法覆盖所有进程（Dia 三轮全部 `summary_only`，明细恒为 0）；
- 但 Dia 的**进程摘要行本身存在**（6,672 / 6,672 / 70,058 bytes）。合并方案要用的正是摘要行 ⇒ **原理上可行**；
- 文档确认 `-n` 只影响地址呈现、不影响字节记账 ⇒ 记账口径不受影响。

- **风险**：高（收益最大，但改动最大、风险最高）
- **定性**：代码事实【已确认】；合并等价性【需实测】
- **最小修复**：合并为单个连接级 nettop，进程级总量改用 `processSummaries`。**项目已自建验证工具**（`NettopReconciliation` + `ByteTraceConnectionProbe --runs`），建议复用来做「非 `-P` 摘要行 vs `-P` 输出」的等价性对账后再动

---

### H2 · 连接级 nettop 缺 `-n`，触发 DNS 反解与自我观测回环

`NettopConnectionCollector.swift:15` 的参数不含 `-n`，即主动请求系统做名称解析。

后果：① 每个新 IP 触发 DNS PTR 查询；② **这些查询自身产生的流量又被 ByteTrace 采集**，形成观测回环；③ 解析延迟可能拖慢出帧节奏。

**已由项目自身实测数据证实**（`docs/DOMAIN_TRAFFIC_EXPERIMENT.md:69-73`）：

| 模式 | hostname 连接 | IP 连接 | 未知 |
| --- | ---: | ---: | ---: |
| 默认（无 `-n`） | **9** | 33 | 13 |
| `--numeric`（有 `-n`） | **0** | 43 | 9 |

hostname 从 9 → 0、IP 从 33 → 43，直接证实名称解析确实在发生，且整个「可见主机名」功能完全依赖它。

- **风险**：高
- **定性**：机制【已确认】；DNS 查询绝对量【需实测】
- **说明**：这是功能与开销的权衡，**不能简单加 `-n`**，否则主机名功能归零

---

### H3 · `bucketStats()` 每 5 秒全表 `COUNT(*)` 扫描

`UsageStore.swift:263-285`：

```sql
SELECT COUNT(*), MIN(bucket_start), MAX(bucket_start) FROM usage_buckets;
```

调用链：`flushTimer`（5 秒，`ByteTraceViewModel.swift:830`）→ `flushNow()` → `refresh()`（`:359`）

无 WHERE 的 `COUNT(*)` 必须扫全表/全索引，**随表增长线性变慢**。而默认保留策略是 `.never`（`:224`），表无上限。`MIN/MAX` 可命中 `idx_usage_buckets_start`，`COUNT(*)` 不能。

- **风险**：高
- **定性**：【已确认】；实际耗时【需实测】
- **最小修复**：移出 5 秒周期，改为打开设置页时按需查询（该值仅在设置页显示）

---

### H4 · 每 5 秒主线程同步执行 4–5 个查询 + 5 个 `@Published` 全量赋值

`refresh()`（`ByteTraceViewModel.swift:344-365`）依次**同步**执行：

1. `store.dailyUsage(for: dayKey)`
2. `store.bucketStats()`（全表扫描，见 H3）
3. `loadRange()` → `bucketUsage` 或 `dailyUsage`；`.today` 分支还会**再查一次** `bucketUsage`（`:1060`）
4. `loadHostUsage()` → `store.hostUsage(from:to:)`

随后 `records` / `rangeRecords` / `rangeTimeline` / `bucketStats` / `hostUsageResult` **无条件全量赋值** → 每 5 秒触发 5 次 `objectWillChange`。`MainWindowView` 与 `MenuBarView` 均用 `@ObservedObject`，无粒度隔离 ⇒ SwiftUI 整树 diff。

- **风险**：高
- **定性**：【已确认】
- **最小修复**：把「写入」与「刷新」解耦 —— `flushNow()`（`:979-992`）不再无条件调用 `refresh()`。数据落库保持 5 秒，UI 刷新降频（如 30 秒）或仅在主窗口可见时执行。配合 M11 的差异守卫可进一步减少 `objectWillChange`
- **补充**：`hostUsage(from:to:)`（`UsageStore.swift:198-209`）**无 LIMIT、无 SQL 层聚合**，`.thisMonth` 范围下会把整月 `host_usage_buckets` 全量载入内存，再由 `summarize` 重新聚合排序。可把聚合下推为 `GROUP BY hostname` + `SUM` 并加 LIMIT（见 P2-11）

---

### H5 · 主线程阻塞最长约 2 秒，且存在嵌套 RunLoop 重入风险

`NettopCollector.terminate()`（`:225-238`）：

```swift
let deadline = Date().addingTimeInterval(2)
while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
process.waitUntilExit()
```

加上 `stop()` 中的 `readGroup?.wait()`（`:136`）。该 `stop()` 在 **4 处主线程调用点**被调用：`ByteTraceViewModel.swift:313`、`:636`、`:691`、`:866`。

更棘手的是紧随其后的 `RunLoop.main.run(until: Date().addingTimeInterval(0.05))`（`:315`、`:693`、`:868`、`:928`）—— **嵌套 RunLoop 会在这 50ms 内重入处理其他事件**，包括另一个 collector 的 `main.async` 回调，可能与正在执行的状态机交错。

- **风险**：高
- **定性**：阻塞【已确认】；重入实际后果【需实测复现】

---

### H6 · `host_usage_buckets` 增长最快且默认永不清理

主键 `(bucket_start, app_key, endpoint_kind, hostname)`（`UsageStore.swift:396`）—— **每分钟 × 每 app × 每个不同 hostname/IP 一行**。

- 默认 `usageRetentionPolicy = .never`（`ByteTraceViewModel.swift:224`）
- `purgeBuckets` 每天最多执行一次（`lastRetentionCleanupDay` 守卫，`:998`）
- **全仓库无 `VACUUM`**，WAL 下 DELETE 后文件不收缩

- **风险**：高
- **定性**：【已确认】；增速【需实测】

---

## 三、中风险

| # | 问题 | 位置 | 定性 |
| --- | --- | --- | --- |
| M1 | 查询 `ORDER BY (download_bytes + upload_bytes)` 是**表达式**，无法命中索引，强制临时 B-tree 排序；而结果在 ViewModel 里又被 `aggregateRecords` / `summarize` 重新聚合排序 ⇒ **DB 排序纯属浪费** | `UsageStore.swift:91,137,192-194,205-207` | 【已确认】 |
| M2 | 所有 SQL **每次调用都 prepare + finalize**，无 statement 缓存。`apply()` 循环内每个 aggregate 都 prepare 3 次。另：`apply()` 对 `aggregates` 与 `bucketAggregates` **各调用一次 `upsertApp`**，同一 app 跨多个分钟桶时会被重复 upsert 多次，可先按 `appKey` 去重 | `UsageStore.swift:27-42,447,476,500` | 【已确认】 |
| M3 | **未设 `PRAGMA synchronous`**，WAL 下默认 FULL ⇒ 每次 COMMIT 都 fsync。含每次 `recordCollectorEvent` 的独立自动提交事务 | `SQLiteDatabase.swift:57-59` | 【已确认】 |
| M4 | `SQLITE_OPEN_FULLMUTEX` 对实际单线程（`@MainActor`）访问是无谓序列化开销 | `SQLiteDatabase.swift:44` | 【已确认】 |
| M5 | `NSWorkspace.shared.icon(forFile:)` 写在 SwiftUI **body 内**，每次重渲染每行调用一次，且每次返回新 NSImage 实例导致 diff 判定为变更 | `MenuBarView.swift:327`、`MainWindowView.swift:415` | 【已确认】 |
| M6 | `formatBytes` **每次调用新建 `ByteCountFormatter`**，每行调用 3–4 次 | `ByteTraceViewModel.swift:552-558` | 【已确认】 |
| M7 | `formattedDate` 每次新建 `DateFormatter`（比 `ByteCountFormatter` 更贵），仅设置页 2 处 | `SettingsView.swift:188-194` | 【已确认】 |
| M8 | 解析缓冲**逐行 `removeSubrange` 前删** ⇒ 每行一次 memmove 剩余数据，单 chunk 内 O(n²) | `NettopCSVParser.swift:69-73`、`NettopConnectionCSVParser.swift:119-123` | 【已确认】 |
| M9 | `CSVLineParser` 逐 unicodeScalar append，每字段一个 String；`parseRow` 又对字段做 `trimmingCharacters` 再分配一次 | `CSVLineParser.swift:4-34`、`NettopCSVParser.swift:172-173` | 【已确认】 |
| M10 | `emitParserEvent` 每事件一次 `main.async`，ViewModel 再包一层 `Task { @MainActor }`（双重派发）。schema 不匹配时每行一个 `.malformedRow` | `NettopCollector.swift:205-210` → `ByteTraceViewModel.swift:603-613` | 【已确认】 |
| M11 | `refresh()` 中 5 个 `@Published` 无条件赋值，模型均为 `Equatable`，可加差异守卫 | `ByteTraceViewModel.swift:358-360` | 【已确认】 |
| M12 | 首次启用保留策略时，`purgeBuckets` 在**主线程同步删除**可能数百万行 | `ByteTraceViewModel.swift:1002` | 【已确认】 |
| M13 | **SwiftUI body 内执行 O(n) 过滤与排序**：`model.hostUsage(for:)`（`MainWindowView.swift:227`）→ `ByteTraceViewModel.swift:401-415` 做两次 `filter` 再调 `summarize`（内含排序）；`model.timeline(for:)`（`:320`）→ `:385-399` 再 filter 一次。另有 `visibleRecords`（`MainWindowView.swift:46-51`）、`record`（`:203`）及 ViewModel 的 4 个计算属性（`:258-276`）。全部无记忆化，SwiftUI 单次渲染可能多次求值 body ⇒ 每次都重算。与 H4 的 5 秒全量刷新叠加 | `MainWindowView.swift:227,320` + `ByteTraceViewModel.swift:258-276,385-415` | 【已确认】 |

### S1 · `hostAggregator` CoW 深拷贝（已下调，原列严重）

**证据**：`ByteTraceViewModel.swift:803-826`

```swift
guard var hostAggregator else { return }   // ① 局部拷贝，pending buffer 引用计数 = 2
try hostAggregator.ingest(...)             // ② mutating → CoW 触发，深拷贝整个字典
self.hostAggregator = hostAggregator       // ③ 写回
```

`NettopHostUsageAggregator` 是 **struct**（`NettopHostUsage.swift:88`），内含 `pending: [Key: NettopHostUsageRecord]`（`:97`）。`self.hostAggregator` 与局部变量同时持有 buffer，任何 mutating 调用都必然触发 Copy-on-Write 全量复制。

**严重度已按实测数据下调至中**，理由见第九节。仍建议修复 —— 这是真实的 O(n²) 缺陷，且修复成本极低。

- **风险**：中
- **定性**：【已确认】（Swift CoW 语义确定，非推测）
- **最小修复**：`NettopHostUsageAggregator` 改为 `final class`；或改用 `self.hostAggregator?.ingest(...)` 原地 mutate，避免产生第二个引用

---

## 四、边界情况

| # | 场景 | 问题 | 定性 |
| --- | --- | --- | --- |
| E1 | **睡眠** | `handleWillSleep`（`:857`）在主线程**串行** stop 两个 collector，最坏约 4 秒阻塞 + 2 次嵌套 RunLoop。系统睡眠前窗口有限，可能来不及 flush | 【已确认】 |
| E2 | **跨午夜 / 唤醒** | nettop `time` 列只有 `HH:MM:SS`，无日期。`sampleDate`（`:1163-1190`）用 `Date()` 的年月日拼接 ⇒ 23:59:59 的帧若在 00:00:01 被处理会**记错日期**；唤醒后处理积压旧帧同理 | 逻辑【已确认】；概率【需实测】 |
| E3 | **网络切换 / 代理开关** | `handleNetworkPathUpdate`（`:672-711`）对**任何接口签名变化**都重启两个 collector。签名 = `path.availableInterfaces.map(\.name).sorted()`，VPN 开关、Wi-Fi 漫游、Docker/UTM/Parallels 虚拟网卡启停都会改变它。**目标用户正是代理重度用户**（内置识别 3 个代理客户端） | 逻辑【已确认】；频率【需实测】 |
| E4 | **重启数据缺口** | 每次重启 `hasBaseline=false`，首帧被丢弃（`NettopCSVParser.swift:151-152`）。`-d` 增量模式下该帧承载真实流量 ⇒ 与 E3 叠加产生累计缺口 | 【已确认】 |
| E5 | **权限失败** | 运行期 stderr 只累积到 `stderrData`，**仅在 `stop()` 时才上报**（`NettopCollector.swift:152-154`）。nettop 若持续报错但不退出，用户看不到原因 | 【已确认】 |
| E6 | **数据库损坏** | `UsageStore.init` 失败即 `store = nil` 永久降级，**无重试、无备份、无重建路径**（`ByteTraceViewModel.swift:227-238`）。且 `migrate()`（`UsageStore.swift:315-408`）的多语句 DDL + `PRAGMA user_version` **不在事务中** ⇒ 迁移中断会留下半迁移 schema | 【已确认】 |
| E7 | **表清理不全** | `purgeBuckets` 只清 2 张 bucket 表。`collector_events` **每次事件 INSERT 且永不清理**（与 E3 的频繁重启叠加会加速膨胀）；`apps` 表同样只增不减 | 【已确认】 |
| E8 | **背压** | 超过 10000 条 pending 时 throw（`UsageAggregator.swift:79-81`），ViewModel catch 后**静默丢弃该样本**，并且每个超限样本都写一次 `collector_events` ⇒ **高负载时反而放大 DB 写入** | 【已确认】 |

---

## 五、线程安全

| # | 问题 | 位置 | 定性 |
| --- | --- | --- | --- |
| T1 | `NettopCollector.onEvent` 无锁保护：主线程写、读线程/终止回调线程读。形式上是数据竞争，`@unchecked Sendable` 掩盖了它。实践风险低（启动前只写一次） | `NettopCollector.swift:38` | 【已确认】 |
| T2 | `stderrData` 有锁保护但无上限，长期不重启时可无界增长 | `NettopCollector.swift:164-168` | 【已确认】 |
| T3 | `handle(.exited)` 在事件回调中调用 `collector.stop()`，而 `stop()` 会 `readGroup?.wait()` ⇒ 在回调里等待产生该回调的线程链 | `ByteTraceViewModel.swift:636` | 【已确认】 |
| T4 | `stop()` 内 `handleParserEvents(finalEvents)` 派发的 `main.async` 块，可能在紧随其后的嵌套 `RunLoop.main.run(until:)` 中被执行 ⇒ 状态机重入 | `NettopCollector.swift:138-141` + `ByteTraceViewModel.swift:315` | 【推测】需实测复现 |

---

## 六、确认无问题的部分

- **PID 复用防护**：`ProcessAttributionCache` 的 key 含 `processStartTime`（`ProcessAttributor.swift:202-205`），能正确防止 PID 复用误归属。**设计正确**。
- **溢出防护**：全代码一致使用 `addingReportingOverflow` + 饱和加，覆盖完整。
- **事务正确性**：`apply()` / `applyHostUsage()` / `purgeBuckets()` 均使用 `BEGIN IMMEDIATE` + `ROLLBACK` 错误路径（`UsageStore.swift:27-42`、`:47-57`、`:288-305`），批量写入策略本身正确。
- **退避策略**：`restartDelays = [1,2,5,10,30]`（`ByteTraceViewModel.swift:205`）指数退避 + 定时器去重守卫（`:959`）实现正确。
- **索引存在性**：`usage_buckets` / `host_usage_buckets` 均建了 `bucket_start` 索引，时间范围 WHERE 可命中（问题仅在 ORDER BY 表达式，见 M1）。
- **子进程回收克制**：`terminate()` 只对自身 `Process` 实例操作，无 `pkill nettop` 之类的粗暴清理。
- **口径隔离**：连接级数据仅写 `host_usage_buckets`，无任何路径回写正式聚合表。**本次审查重点验证，隔离干净彻底。**

---

## 七、文档审查

### 7.1 `README.md`

面向用户的产品说明。质量高，**诚实度显著高于同类项目** —— 专门用「能做 / 不做」对照表列出不做什么，并主动声明「许可条款待定，请勿默认可自由分发」。

**经代码核对为真的声明**：数据源唯一性、五张表结构、退避序列、代理不计入总量、内置识别 3 个代理、退出只回收自身子进程、不上传不解析报文。**时间范围取数表逐格吻合**，包括「今天＝日汇总＋分钟级趋势」这个易错组合（`ByteTraceViewModel.swift:1053-1067`）。

**需修订三处**：

| # | 问题 | 优先级 |
| --- | --- | --- |
| R-1 | FAQ「数据库会无限增长吗？」回答不完整。`purgeBuckets` 只删 2 张 bucket 表，而 `collector_events` 永不清理、`apps` 只增不减、无 `VACUUM` 故文件不收缩。**该 FAQ 的提问正是增长问题，当前措辞给出「已解决」的错误印象** | P0 |
| R-2 | 隐私章节未披露 DNS 反解副作用。「不上传、不联网回传任何统计结果」就统计结果而言属实，但连接级采集器主动请求名称解析 ⇒ 间接触发出站 DNS 查询。**项目内部已知**（需求文档 `:47` 写明），用户侧未告知 | P2 |
| R-3 | 项目结构（`:204-211`）漏列 `ByteTraceIconLab`，而 `Package.swift:15,23` 中它是第 5 个 product 且为独立 SwiftUI 应用 | P2 |

### 7.2 `docs/DOMAIN_TRAFFIC_EXPERIMENT.md`

**三份文档中工程价值最高的一份** —— 记录了带数字的负面结果，而非只记成功。

**8 条验收门逐条核验**：

| # | 验收门 | 代码证据 | 判定 |
| --- | --- | --- | --- |
| 1 | 不展示 IP | `NettopEndpointClassifier.info:35-37` 对 IP 返回 `.ipAddress` 且 **`hostname` 恒为 nil**；`NettopHostUsageRank.label:18` = `hostname ?? "无法识别/其他"` | ✅ **结构性保证** —— IP 在类型层面无法到达 UI |
| 2 | 应用内排行只收可归属连接 | `hostUsage(for:):401-415` 先 `filter { $0.appKey == appKey }` | ✅ |
| 3 | 覆盖率透明 | `NettopHostUsageCoverage.formalVisibilityRatio:64`；`HostUsageView:87` 显示覆盖率、`:51` 显示「实验数据 · 部分可见」 | ✅ |
| 4 | **口径隔离** | `ingestHostUsage:803` → `hostAggregator` → `applyHostUsage:44` → **仅写 `host_usage_buckets`** | ✅ **隔离干净彻底** |
| 5 | 时间一致 | 正式与实验同用 `Calendar.autoupdatingCurrent`，`loadHostUsage:1071` 复用同一 start/end | ✅（但见 D-2） |
| 6 | 事实边界（不从 IP 反查） | 代码自身从不反查，只消费 nettop 已呈现的字符串 | ✅ |
| 7 | 生命周期可控 | 每次重启 `hasBaseline=false`，首帧丢弃 | ⚠️ 见 D-1 |
| 8 | 本地隐私、独立清理 | `clearHostUsage():259` 独立清空 | ✅ |

**8 条中 7 条完全通过**，第 1、4 条是本次审查中实现质量最高的部分 —— 验收门真的落到了代码结构里，而非写完就忘。

**两处未覆盖的代价**：

- **D-1**（P1）：验收门 7 强调重建基线保证「不污染下一轮」—— 正确，但未写代价。`-d` 增量模式下被丢弃的首帧承载真实流量，丢弃即永久丢失（对应 E4）。叠加 E3 的接口抖动会显著放大。
- **D-2**（P1）：验收门 5「时间一致」成立，但 `sampleDate` 的跨午夜归日错误（E2）会让正式与实验**一致地错**。文档未涉及。

### 7.3 `docs/DOMAIN_TRAFFIC_DECISION.md`

**优点**：

- Apple 能力边界考证准确 —— 正确识别 `NEFilterFlow.sourceAppIdentifier` 在 macOS 不可用、`remoteHostname` 仅在按 hostname 建连时提供、`NEFilterFlow.URL` 仅对 WebKit flow 可能非空、`NEFilterReport` 字节数仅在 flow 关闭时非零。四条都是 NE 经典坑且均附出处。
- 门禁记录可复现 —— `security find-identity -v -p codesigning` 返回 `0 valid identities found`，**结论建立在可重跑的检查上**。
- 费用结论有据 —— 明确区分「¥688 是 NE 授权前置条件，不是 nettop 排行的前置条件」。
- 与代码一致 —— 三条最终决定（正式源 `-P`、口径隔离、不显示 IP）逐条落实。

**两处措辞不准**（均 P2）：

- **S-1**：「当前仓库是 Swift Package，包含单一 `ByteTraceApp`」—— `Package.swift` 有 5 个 product，其中 `ByteTraceIconLab` 同样是 SwiftUI GUI 应用。上下文想表达「无 Extension target」（属实），但字面不准。
- **S-2**：「没有 `.entitlements` 文件」—— **本次未核实**（未列出 `Packaging/` 文件清单），不做判断。

---

## 八、文档 / 代码一致性核对

**一致性**：三篇对核心边界的表述**完全自洽，无相互矛盾** —— 正式源 `nettop -P`、实验排行隔离、不显示 IP、不做 NE 运行化、不承诺完整 URL。多文档项目中不常见。

**分工清晰**：DECISION（为什么选它）→ REQUIREMENTS（边界与验收）→ README（用户怎么用）。互相引用且链接有效。

**共同盲区**：三篇**都只讨论「能不能做、准不准」，完全没有讨论「代价是多少」** —— 无一处提及 CPU、内存、电量、主线程占用或长期运行开销。

`docs/DOMAIN_TRAFFIC_DECISION.md:101` 称「剩余工作只包括…长跑验收」，但从 S2 / S3 的存在看，该长跑验收验的是**功能存活**（还在跑吗），不是**资源代价**（跑一天花多少）。

---

## 九、严重度校准说明

初版审查基于「每秒数百行」的假设推导。`docs/DOMAIN_TRAFFIC_EXPERIMENT.md` 提供了这台机器的真实测量值，据此**下调两处估算**，记录于此以免后续误用初版数字。

**校准依据**（`docs/DOMAIN_TRAFFIC_EXPERIMENT.md:78-83`，45 秒受控浏览器基线）：

```text
45 帧采集，1 帧基线，0 条 malformed row
hostname 连接 182 + IP 连接 355 + 未知连接 47 = 584 条
⇒ 约 13 行/帧
```

| 项 | 初版估算 | 校准后 | 修正幅度 |
| --- | --- | --- | --- |
| 连接级行数/帧 | ~500 | **~13** | 高估约 38× |
| **S1** CoW 拷贝量 | 十万级条目/秒 | 13 × 约 65 ≈ **850 条目/秒** | **严重 → 中** |
| **S2** snapshot 次数 | 最多 6300 次/秒 | 约 25–65 次 resolve × 最多 9 ≈ **225–585 次/秒** | **仍为严重** |

**结论**：**S2（归属层无缓存）是本项目真正的头号性能问题**；S1 降级为中风险，但因修复成本极低（改 `final class` 或原地 mutate），仍建议一并处理。

**另一处校准** —— H1 的可行性：文档数据既部分推翻又部分支持初版判断。连接**明细**确实无法覆盖所有进程（Dia 三轮全 `summary_only`），但**摘要行存在**，而合并方案要用的正是摘要行 ⇒ 合并在原理上可行。详见 H1。

---

## 十、P0 / P1 / P2

### P0 — 建议优先处理

| ID | 事项 | 类型 | 对应条目 |
| --- | --- | --- | --- |
| P0-1 | `SystemProcessIdentityResolver.resolve()` 加 pid→identity 缓存 | 代码 | S2 |
| P0-2 | `ProcessAttributionCache` 加容量上限 / 淘汰策略 | 代码 | S3 |
| P0-3 | README FAQ「数据库会无限增长吗」补充 `collector_events` / `apps` 无保留策略 + 无 VACUUM | 文档 | R-1 |

### P1 — 应处理

| ID | 事项 | 类型 | 对应条目 |
| --- | --- | --- | --- |
| P1-1 | `bucketStats()` 移出 5 秒周期，改设置页按需查询 | 代码 | H3 |
| P1-2 | `NettopHostUsageAggregator` 改 `final class`，消除 CoW 深拷贝 | 代码 | S1 |
| P1-3 | 网络接口签名变化加防抖窗口 | 代码 | E3 |
| P1-4 | `collector.stop()` 改异步 + 移除 4 处嵌套 `RunLoop.main.run(until:)` | 代码 | H5 / E1 / T4 |
| P1-5 | 加 `PRAGMA synchronous = NORMAL` | 代码 | M3 |
| P1-6 | `sampleDate` 跨午夜归日错误 —— 加单元测试固化预期 | 代码 | E2 |
| P1-7 | REQUIREMENTS 验收门 7 补注「重建基线 = 丢弃该窗口增量」 | 文档 | D-1 |
| P1-8 | `collector_events` 加保留 / 上限策略 | 代码 | E7 |
| P1-9 | 「写入」与「UI 刷新」解耦：`flushNow()` 不再无条件 `refresh()`，落库保持 5 秒、刷新降频或仅主窗口可见时执行 | 代码 | H4 |

### P2 — 可延后

| ID | 事项 | 类型 | 对应条目 |
| --- | --- | --- | --- |
| P2-1 | README 隐私章节披露连接级采集触发 DNS 反解 | 文档 | R-2 / H2 |
| P2-2 | `ByteCountFormatter` 改 `static let`；图标结果加缓存 | 代码 | M5 / M6 |
| P2-3 | 去掉 SQL 中表达式 `ORDER BY` | 代码 | M1 |
| P2-4 | `apply()` 循环内复用 prepared statement | 代码 | M2 |
| P2-5 | 解析缓冲改游标扫描，消除 O(n²) memmove | 代码 | M8 |
| P2-6 | 生产路径引入 `NettopReconciliation` 自检 | 代码 | — |
| P2-7 | README 补 `ByteTraceIconLab`；DECISION 修正「单一 ByteTraceApp」 | 文档 | R-3 / S-1 |
| P2-8 | DB 损坏恢复路径 + `migrate()` 包进事务 | 代码 | E6 |
| P2-9 | 核实 `Packaging/` 下是否存在 `.entitlements`，据此确认或修正 DECISION 的声明 | 文档 | S-2 |
| P2-10 | `hostUsage(for:)` / `timeline(for:)` 结果移出 body：在 ViewModel 侧预先按 `appKey` 建索引字典，或在详情页用 `@State` 缓存 | 代码 | M13 |
| P2-11 | `hostUsage` 查询加 LIMIT，聚合下推为 `GROUP BY` + `SUM`，避免整月数据进内存 | 代码 | H4 / M1 |
| P2-12 | **补性能基准测试** —— 现有测试全为正确性测试，无一个 measure 用例，导致任何优化都无法量化验证（详见第十一节第 10 项） | 测试 | S1 / S2 / M2 / M8 |

### 建议实施顺序

`P0-1` → `P0-2` → `P1-1` → `P1-2`

前四项均为局部小改动，按第九节的量级估算，预计可拿下绝大部分性能收益。`H1`（合并采集器）收益最大但风险最高，建议在完成上述四项并跑通对账验证后再单独评估。

---

## 十一、验证方案（**尚未执行**）

> 本节全部命令在本次审查中均未运行。所有【需实测】条目仍待验证。

**1. 量化数据规模**（最优先，决定后续所有优化的收益估算）

```bash
/usr/bin/nettop -n -P -d -x -L 2 -s 1 > /tmp/pl.csv
/usr/bin/nettop    -d -x -L 2 -s 1 > /tmp/cl.csv
awk -F, '$1=="time"{f++} {c[f]++} END{for(i in c) print "frame "i": "c[i]" lines"}' /tmp/cl.csv
grep -c "<->" /tmp/cl.csv
```

**2. 验证 S2（主线程 syscall 风暴）**

```bash
sample ByteTrace 10 -f /tmp/bt.sample
grep -E "resolve|Bundle|realpath|NSRunningApp" /tmp/bt.sample
sudo fs_usage -w -f filesys ByteTrace | head -100
```

**3. 验证 S1（CoW 深拷贝）**

Instruments **Allocations** 模板，过滤 `NettopHostUsageRecord`，观察瞬时分配速率是否远超实际记录数。

**4. 验证 H2（DNS 回环）**

```bash
sudo tcpdump -i any -n port 53 -c 200   # 对比 App 启停前后的 DNS 请求速率
```

**5. 验证 H3 / H6（数据库增长与查询计划）**

```bash
DB=~/Library/Application\ Support/com.nanvon.ByteTrace/usage.sqlite3
sqlite3 "$DB" "SELECT 'usage',COUNT(*) FROM usage_buckets UNION ALL SELECT 'host',COUNT(*) FROM host_usage_buckets UNION ALL SELECT 'events',COUNT(*) FROM collector_events;"
sqlite3 "$DB" "EXPLAIN QUERY PLAN SELECT COUNT(*) FROM usage_buckets;"
ls -lh "$DB"*
```

**6. 验证 E2（跨午夜）**

新增单元测试：构造 `sampleDate(for: "23:59:59.999", fallback: <次日 00:00:01>)`，断言返回**前一天**。当前实现会返回次日，测试应失败。

**7. 验证 E3（网络抖动重启频率）**

```bash
sqlite3 "$DB" "SELECT kind,COUNT(*) FROM collector_events GROUP BY kind ORDER BY 2 DESC;"
# 重点看 network_path_changed / collector_backoff 计数
```

**8. 验证 H5 / E1（主线程阻塞）**

Instruments **Time Profiler** + **Hangs**，在触发睡眠 / 网络切换时观察主线程 hang 时长。

**9. 验证 H1（合并采集器的等价性）**

复用 `ByteTraceConnectionProbe --runs` 与 `NettopReconciliation`，对账「非 `-P` 摘要行」与「`-P` 输出」的字节一致性。这是合并方案的前置门槛。

**10. 建立性能回归基准（当前完全缺失）**

`Tests/ByteTraceCoreTests/` 下 8 个测试文件**全部是正确性测试，没有任何 `measure` 用例**。这意味着 P0/P1 各项优化改完之后，无法量化证明收益，也无法防止后续回归。建议补充：

| 建议用例 | 覆盖条目 |
| --- | --- |
| 对 1000 个不同 hostname 样本调用 `NettopHostUsageAggregator.ingest` | S1（CoW 深拷贝） |
| 对 1000 个不同 pid 调用 `SystemProcessIdentityResolver.resolve` + `ProcessAttributionCache.attribute` | S2（归属层无缓存） |
| 对 500 条聚合调用 `UsageStore.apply`（内存库） | M2（prepare 开销） |
| 用 10 万行 fixture 调用 `NettopCSVParser.consume` | M8（memmove O(n²)） |
| 对 5 万条记录调用 `NettopHostUsageQuery.summarize` | H4 / M1 |

每项优化前后各跑一次对比，才能把「预计可拿下绝大部分性能收益」从估算变成结论。

---

## 十二、结论

| 对象 | 结论 |
| --- | --- |
| `README.md` | **通过**，需 1 处 P0 修订（R-1）。功能与口径描述经代码逐条核对基本属实，时间范围取数表逐格吻合 |
| `docs/DOMAIN_TRAFFIC_EXPERIMENT.md` | **通过**，工程价值最高。8 条验收门 7 条经代码验证落实，其中「不展示 IP」「口径隔离」是结构性保证而非约定俗成 |
| `docs/DOMAIN_TRAFFIC_DECISION.md` | **通过**。Apple 能力边界考证准确，决策建立在可复现检查上。2 处措辞不准（P2），1 处未核实 |
| 代码 | **正确性通过，性能不通过**。S2 / S3 为需优先处理的缺陷 |

**总体判断**：正确性纪律很强、性能纪律缺位。凡文档立过验收门的地方代码执行到位；凡文档未提要求的地方（CPU、内存、主线程、长期增长）就出现随时间恶化的缺陷。**三份文档无一处提及资源开销是根因。**

**建议的结构性改进**：把「资源开销」补成第 9 条验收门，给出可测阈值，例如：

- 稳态 CPU 占用上限（空闲桌面场景）
- 24 小时驻留内存增长上限
- 主线程单次阻塞上限
- 30 天连续运行后的数据库体积上限

有了可测阈值，S2 / S3 这类缺陷才会在下一次「长跑验收」中被自动拦住，而不是依赖人工代码审查发现。
