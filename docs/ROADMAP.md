# ByteTrace 待办规划（ROADMAP）

> 更新：2026-09-30
> 代码基线：v0.1.29（HEAD `add24fb`）
> 本文档取代 `docs/NEXT_MAJOR_VERSION_PLAN.md` 与 `docs/PERFORMANCE_AND_POWER_OPTIMIZATION_PLAN.md`，两份原文档保留为历史存档、不再维护。
> 硬约束：无 Apple 付费开发者身份；不加 root；不启用 Network Extension；不引入第三方依赖；ad-hoc 签名分发。

## 0. 判断依据

### 0.1 真实数据快照（本机 `usage.sqlite3`，2026-09-30）

| 项 | 数值 |
| --- | --- |
| 数据库大小 | 68 MB |
| `daily_usage` | 50 天（2026-08-10 ~ 2026-09-30）、6,631 行、380 个 `appKey` |
| `usage_buckets` | 476,656 行、25,179 个分钟桶（约 17.5 天份）、380 个 `appKey` |
| `collector_events` | 1,005 条（30 天保留） |

同一份数据里的采集中断事件：

| 事件 | 次数 |
| --- | --- |
| `system_proxy_enabled` / `system_proxy_disabled` | 204 / 186 |
| `network_path_lost` | 130 |
| `network_path_changed` | 102 |
| `collector_started` / `loopback_collector_started` | 89 / 89 |
| `collector_exited` | 88 |
| `sample_gap`（system_sleep） | 60 |
| `usage_buckets_purged` | 28 |
| `collector_backoff` / `loopback_collector_backoff` | 14 / 14 |
| `loopback_collector_exited` | 1 |

两条结论：

1. `daily_usage` 已积累 50 天、380 个应用，而界面最远只到「本月」，更早的历史没有任何入口。
2. `collector_events` 在全库没有 SELECT 调用方（只有 `recordCollectorEvent` 的 INSERT 与保留策略的 DELETE）。平均每天 2.6 次网络丢失、近 2 次通道退出，而界面上分不出「今天没怎么上网」和「今天有一小时没采集到」。

### 0.2 已落地、不再重复列举的优化

`PERFORMANCE_AND_POWER_OPTIMIZATION_PLAN.md` 的阶段 1A/1B、2A–2F、3A–3D、4 已全部实施，代码位置：

| 项 | 位置 |
| --- | --- |
| 一次事务只 prepare 3 条 UPSERT 并复用 | `UsageStore.apply` |
| 每批每个 `appKey` 只 upsert 一次 `apps` | `UsageStore.AppAggregate.merging` |
| 分面刷新：菜单栏不读分钟桶 | `ByteTraceViewModel.observedUsageSurfaces` / `refreshIfNeeded` |
| `today` 范围不重复查询日汇总 | `loadRange(cachedToday:)` |
| SQL 端聚合（排行、总趋势、单应用趋势） | `bucketUsageSummary` / `bucketTimeline` |
| 应用详情按需查询 | `loadDetailTimeline(appKey:)` |
| 保留清理串行 + in-flight 门控 + 待重跑 | `retentionQueue` / `retentionCleanupInProgress` / `retentionCleanupNeedsRerun` |
| 不再自动全库 VACUUM | `vacuum()` 无自动调用方 |
| 分批删除（5,000 行/批，批间让步 2ms） | `purgeBuckets` / `purgeBucketBatch` |
| pending 上限 10,000 | `UsageAggregator.maxPendingEntries` |
| 图表数据缓存 + 二分查找最近点 | `UsageTimelineChart.makeChartData` / `nearestPoint` |

未补：性能文档 §9.1 的未实测项（休眠、网络切换 A/B、唤醒数与 SQLite I/O 采样）。

## 1. 待办总表

| # | 事项 | 来源 | 优先级 | 成本 |
| --- | --- | --- | --- | --- |
| 1 | 历史日期查询与周期对比 | NEXT §2 | 高 | 中 |
| 2 | 采集缺口可解释（轻量版） | NEXT §3 | 高 | 低–中 |
| 3 | CSV 导出 | NEXT §6 | 中 | 低 |
| 4 | 完整备份与恢复 | NEXT §6 | 中 | 中 |
| 5 | 低风险小修（4 项，见 3.2） | 性能 §5D + 本次审查 | 中 | 低 |
| 6 | 用量提醒 | NEXT §8.2 | 低 | 中 |
| 7 | 通道状态区间表（采集完整性完整版） | NEXT §3/§5.1 | 低，待 1、2 落地后重估 | 高 |
| 8 | 后台执行架构重构 | NEXT §4 | 不做，见 §4 | 极高 |
| 9 | 进程归属异步化 / parser 微调 | 性能 §5/§6 | 不做，见 §4 | 高 |
| 10 | 最近带宽 / 分组别名 / 小时汇总 | NEXT §8.1/§8.3 | 不做，见 §4 | 中 |

## 2. 值得做

### 2.1 历史日期查询与周期对比

**现状**：存储层已经就绪，缺的只有视图层与查询参数的表达方式。

- `UsageStore.dailyUsage(from:through:)` 已支持任意日范围，`bucketTimeline(from:to:appKey:excludingProxyTransport:)` 已支持任意时间范围。
- `UsageTimeRange` 是 5 个 case 的纯枚举（`last10Minutes` / `lastHour` / `today` / `thisWeek` / `thisMonth`），引用共 25 处，集中在 `ByteTraceViewModel`、`MainWindowView`、`SettingsView`。
- `aggregateRecords` 已能把多天同应用合并，`makeTimeline(from: [DailyUsageRecord])` 已支持日粒度趋势。也就是说「跨日范围」的汇总与趋势两条路径都已存在，只是没有被任何范围选到。

**要做什么**

1. 把范围选择从「枚举」改成「选择类型」：保留 5 个快捷档，新增「昨天」「上周」「上月」「指定某一天」「自定义起止日期」「上一周期 / 下一周期」。日期粒度，不支持任意分钟或秒。
2. 内部区间统一 `[start, end)`，避免相邻范围在边界重复计算。
3. 周期对比：完整周期对比（昨天 vs 前天、上周 vs 上上周）始终可用；同进度对比（今天截至 15:00 vs 昨天截至 15:00）仅在分钟桶仍覆盖对照区间时可用，否则禁用并说明原因。
4. 应用排行增加三个排序入口：本期总量、增加最多、减少最多。展示本期、对照期、字节差值与变化率；对照期为 0 时显示「新增流量」，不显示无穷大百分比。
5. 趋势图沿用现有两条路径：跨日范围走日汇总，单日范围走分钟桶。

**不变量**

- 代理流量（`category != .proxyTransport`）不计入应用总量，也不参与对比。
- `appKey` 派生规则不改（改动会切断历史连续性）。
- 查询带请求版本号，快速切换日期时旧结果不得覆盖新结果；一个页面的总量、排行、趋势来自同一次查询结果。
- 90 天 × 380 应用约 1.2 万行 `daily_usage`。先在现有主线程查询路径上实现，实测超过约 50ms 再考虑 SQL 端聚合或后台执行器。

**验收**：跨月、跨年、周起始日、夏令时；只有日汇总或部分明细缺失时仍展示有依据的结果并提示明细不可用；快速切换日期不被旧结果覆盖；代理流量规则不变。

### 2.2 采集缺口可解释（轻量版）

**现状**：趋势图已经会断开（`timelinePoints` 对相邻间隔超过 2.5 倍的采样点切换 `segmentID`），但用户看不出断开的原因和时长。诊断数据 `collector_events` 已在积累，却没有任何读取方。

**要做什么**：不新建表，直接用 `collector_events` 配对出中断区间。

配对规则：

| 起点事件 | 终点事件 |
| --- | --- |
| `network_path_lost` | `network_path_changed` / `collector_started` |
| `collector_exited` | `collector_started` |
| `sample_gap`（system_sleep） | `collector_started` |
| `parse_schema_changed` | 无终点（持续到格式恢复或用户干预） |

其余事件（`collector_backoff`、`system_proxy_enabled/disabled` 等）只作为原因标注，不单独构成区间。

展示：主窗口增加「采集完整性」区块，显示所选范围内中断次数、累计时长、按原因分组；趋势图把中断区间画成底纹。明细已清理与未采集分开解释。

**不变量**

- 中断区间只解释缺口，不参与流量统计；不得把缺口当作 0 流量，也不得由邻近数据推断流量。
- 不把「正常运行时间占比」表述成「流量准确率」。

**已知局限**（写进界面文案）

- `collector_events` 只有 30 天保留，更早的范围只能显示「未记录采集状态」，不得回填为正常。
- 极端情形（进程被强杀、断电）下区间不闭合，需要标注「区间未闭合」，不能假设一直中断到下一次启动。

**升级路径**：轻量版不够用（需要精确区间列表、需要超过 30 天的解释）时，再上 NEXT §5.1 的通道状态区间表，schema 版本 +1，旧区间一律标「未记录」。

### 2.3 CSV 导出

**现状**：只有 `exportCurrentRange(to:)` 输出的 JSON（`formatVersion: 3`），无 CSV。

**要做什么**：同一范围另出一条 CSV 导出路径。要点：

- 字段按 RFC 4180 转义（逗号、引号、换行）。
- 防表格公式前缀：单元格以 `=`、`+`、`-`、`@` 开头时前置 `'`。
- 表头固定，含统计范围与口径（`accountingVersion`）和上下行字节、应用身份、分类。
- 代理行按当前过滤规则处理，导出内容与界面显示口径一致。

**验收**：Excel / Numbers 打开不乱码、不串列；含逗号与引号的应用名正确；空范围导出为空表而非报错。

## 3. 看需求定

### 3.1 完整备份与恢复

现状：无。`SQLiteDatabase` 只封装了 `execute` / `prepare` / `bind` / `stepDone` / `reset` / `changes`，没有 `sqlite3_backup`。WAL 模式下直接拷主库文件不安全。

要做的：用 SQLite Backup API 生成一致快照；恢复走固定流程——校验文件与版本 → 展示备份时间与数据范围 → 用户确认 → 暂停采集并排空 → 自动备份当前数据 → 替换并校验、失败回滚原数据 → 恢复采集。首版只做替换恢复，不做合并（累计模型没有跨备份去重依据）。

验收：采集中备份、损坏文件、较新版本备份、磁盘空间不足、恢复中断、覆盖前自动备份可用。

### 3.2 低风险小修

1. **`ProcessAttributionCache` 命中路径 O(n)**：`attribute` 命中时执行 `accessOrder.firstIndex` + `remove(at:)`，上限 2,000 项。改为访问序号或链表实现，缓存优化不得降低 PID 复用安全性（`(pid, processStartTime)` 键与 start time 校验必须保留）。
2. **`shutdown()` 靠固定时长赌末帧**：现在用 `RunLoop.main.run(until: Date() + 0.05)` 排空主队列。改成明确的末帧确认（等待两个采集通道已投递的批次处理完成），保留「先 ingest、再 flush」的顺序，不改变 5 秒落库目标。
3. **刷新节流与宣传不一致**：`refreshIfNeeded` 对每种界面有 10 秒节流，而 flush 是 5 秒、README 写的是「秒级反馈」。二选一：刷新跟随 flush 周期，或改 README 措辞与实现一致。
4. **跨午夜日期归属**：`sampleDate(for:)` 把「当前」年月日嫁接到 nettop 的时钟上，23:59:5x 的帧若在 00:00:0x 被解析会归到次日。影响面为每天 1 个采样周期的量级（外部 5 秒 / 补充 1 秒），属于正确性打磨。修法：记录上一帧接收时间，时钟大幅回退时减一天。

### 3.3 用量提醒

依赖需求。先做每日应用阈值，再考虑持续大量上传（需要冷却时间、最小持续时长、采集缺口处理）。本地通知需用户授权，并在正式 ad-hoc 安装包上验证；不引入远程推送服务。

## 4. 不建议现在做

| 项 | 理由 | 复查条件 |
| --- | --- | --- |
| 后台执行架构重构（NEXT §4） | 成本极高（`ByteTraceViewModel` 已 1,460 行，涉及统一 persistence queue、运行代次、退出 barrier）；当前实测基线平均 CPU 0.248%、峰值 1.3%、RSS 80.3MB，没有证据支持 | 主线程出现可复现卡顿，或 flush P95 超过 16ms |
| 进程归属异步化（性能 §5） | 同上。另外 §5A「帧内重复解析」在现状下收益很小：补充通道 `SupplementalTrafficReducer` 已按 `(processName, source)` 合并，一帧内同一进程最多 2 条 delta；外部通道 `-P` 是一进程一行。`SystemProcessIdentityResolver` 每次 `resolve` 的一次 `proc_pidinfo` 是 PID 复用校验，属有意保留 | 主线程采样中确实出现逐条完整归属链 |
| parser / nettop 字段微调（性能 §6） | 直接改 `-J` 列与生产解析路径，风险最高、收益最低 | 有明确热点证据，且能完成完整 A/B |
| 最近带宽（NEXT §8.1） | 「最近 10 分钟」已覆盖大部分需要 | 明确要求秒级速率 |
| 分组与别名（NEXT §8.3） | 需要额外维护一份映射，现无需求 | 明确要求自定义展示名 |
| 小时汇总（NEXT §8.3） | 分钟桶实测只覆盖 17.5 天，日汇总已够用 | 保留策略收紧到 30 天以内且需要日内长期趋势 |

## 5. 实施纪律（沿用，仍然有效）

- 每个阶段独立提交，采集变化、数据迁移、界面变化分开，不合并后再验证。
- 数据等价门槛：固定 CSV 回放，每应用、每方向、每时间桶字节完全一致，不接受百分比误差。
- 不修改：`appKey` 派生规则、`accountingVersion = 3`、5 秒落库目标、双通道参数（`-c`、`-P`、`-s 1/5`、`NSUnbufferedIO=YES`、POSIX `read()`、父进程持有的空 stdin Pipe）、首帧丢弃规则。
- 代理流量始终单独展示、不反向抵扣、不计入应用总量。
- schema 变更走累加迁移（`PRAGMA user_version`，当前 6），同步 `UsageStore.schemaVersion`。
- 诊断与验证结束后检查无残留 `nettop` 子进程；Probe 使用 `:memory:` 数据库。
- 发布前：现有测试通过、新增测试通过、双通道真实场景验证、一次覆盖休眠唤醒与网络切换的长时间运行。

## 6. 待拍板的产品决策

1. 自定义范围是否只到日期粒度（建议：是）。
2. 历史是否继续按「采集时本地日期」保留、跨时区不重算（建议：是）。
3. 恢复是否只做覆盖恢复（建议：是）。

## 7. 历史文档

- [NEXT_MAJOR_VERSION_PLAN.md](NEXT_MAJOR_VERSION_PLAN.md)：2026-09-08，下一大版本方案，未实施。设计与验收细节仍可参考。
- [PERFORMANCE_AND_POWER_OPTIMIZATION_PLAN.md](PERFORMANCE_AND_POWER_OPTIMIZATION_PLAN.md)：2026-08-13，第一轮优化已实施，含 §9.1 验收记录。
