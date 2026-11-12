# ByteTrace 功能与稳定性待办（2026-11-12）

> 代码基线：`8ae3281`（v0.1.41 之后），与 [REVIEW_2026-11.md](REVIEW_2026-11.md) 相同
> 前提不变：不使用 Apple 付费开发者身份，不加 root，不启用 Network Extension，ad-hoc 签名，不引入第三方依赖
> 状态：方案，均未实施。本文只收录 REVIEW、ROADMAP、NEXT 三份文档都没有覆盖的事项。交付时从 §6 的任务清单开始读。

本文的「读代码」指基线 `8ae3281` 的静态阅读，行号是该基线下的位置。没有运行构建、测试、探针或应用，没有读取正式数据库。标了「未验证」的地方，实施时要先确认再写代码。

## 0. 实施者守则

1. 一次只做 §6 的一个任务，做完停下来给用户看 diff。提交要等用户说。
2. 动手前按当前代码复核本文引用的行号与事实；与本文不符时停下来报告，不要按自己的理解继续。
3. 只改任务表「允许改动的文件」一栏列出的文件。需要多改时先说明范围，等用户同意。
4. 写完只运行 `swift build` 做编译检查。`swift test`、探针、打包都要先说明原因再运行。不做界面自动化。
5. 遇到标为「需用户决定」的事项时停下来问。本文替用户选了默认值的地方都写明了「用户可以改」。
6. 沿用仓库约定（见 `CLAUDE.md`）：面向用户的文案用中文；字节累加用就近的 `saturatingAdd`；`ByteTraceCore` 的 public 类型显式写 `public init`，模型 `Equatable, Sendable`；新增按钮与可点击行加 `.focusable(false)`，需要键盘输入的控件用 `.focusEffectDisabled()`；汇总逻辑一律排除 `category == .proxyTransport`；schema 变更追加迁移分支并同步 `UsageStore.schemaVersion` 与 `CLAUDE.md`。
7. 纯逻辑放进 `ByteTraceCore` 并写单元测试。测试 target 只依赖 Core，应用 target 没有测试，放在应用层的逻辑无法被测试覆盖。
8. 界面改动无法由执行者运行验证。每个带界面的任务完成时，列出「未经运行验证」的界面行为，交给用户手动检查。

## 1. 总览

| 编号 | 事项 | 用户能看到的变化 | 改 schema | 成本 |
| --- | --- | --- | --- | --- |
| F1a | 代理用量周期与额度 | 主窗口显示「本周期代理已用 X / 额度 Y」 | 否 | 低–中 |
| F1b | 按代理节点统计 | 展开后列出各节点用量 | 是，新增一张表 | 中 |
| F2a | 数据库损坏时隔离并重建 | 数据库损坏后应用仍能启动并继续采集 | 否 | 中 |
| F2b | 后台完整性检查 | 损坏在下次启动时被处理，不会长期带病运行 | 否 | 低 |
| F3 | 新出现的应用与程序 | 列表里标出本期首次联网的应用和程序 | 否 | 低 |
| F4 | 隐藏、置顶与右键菜单 | 列表可整理；行上可直接打开访达、拷贝路径 | 否 | 低–中 |

与 REVIEW 任务的关系：F1b 与 REVIEW 的 T4 都改 `MihomoRouteTracker`，先做 T4。REVIEW 的 T1 占用 schema 版本 14；F1b 的迁移使用实施时的 `UsageStore.schemaVersion + 1`，不要写死版本号。其余互不依赖。

## 2. F1：代理用量周期与节点统计

### 2.1 现状（读代码）

- mihomo 连接表的 `chains[0]` 是实际出口。`MihomoConnectionsParser.route(forChains:)`（`MihomoConnections.swift:78`）把它归成 `.proxyRuleDirect`（`DIRECT`）、`.proxied`（空、`REJECT`、`REJECT-DROP`、`PASS`）或 `.proxyNode`（其余），节点名称随后被丢弃。
- `MihomoRouteTracker`（同文件 95 行起）以应用侧本地端点为键缓存 `TrafficRoute`，`ByteTraceViewModel.supplementalRoute(for:)`（1399 行）查询它。
- 路径按 `(day, app_key, program_key, route)` 累加在 `daily_route_usage`。代理传输进程的 `route` 为 `nil`，不写这张表（`ByteTraceViewModel.swift:1565`）。
- `UsageStore.routeUsage(from:through:)`（263 行）已能按日期范围取出每个应用每条路径的字节。

所以「一个结算周期内走节点的流量合计」现在就能从 `daily_route_usage` 算出，不需要新数据。按节点拆分才需要新表。分成两步做。

### 2.2 F1a：周期与额度（不改 schema）

**设置项**（`UserDefaults`）：

| 键 | 类型 | 默认 | 含义 |
| --- | --- | --- | --- |
| `ByteTrace.proxyQuotaResetDay` | Int | 1 | 每月结算日，1–31。当月没有这一天时取当月最后一天 |
| `ByteTrace.proxyQuotaBytes` | Int64 | 0 | 周期额度，字节。0 表示未设置 |

**周期计算**。在 Core 新增纯函数（建议文件 `Sources/ByteTraceCore/Storage/ProxyBillingPeriod.swift`）：

```swift
public struct ProxyBillingPeriod: Equatable, Sendable {
    public let start: Date        // 周期第一天 00:00（本地日历）
    public let nextReset: Date    // 下一个结算日 00:00
    public let startDay: String   // yyyy-MM-dd，与 daily_route_usage.day 同格式
    public let endDay: String     // nextReset 前一天，闭区间
    public static func current(resetDay: Int, now: Date, calendar: Calendar) -> ProxyBillingPeriod
}
```

规则：`resetDay` 先限制到 1–31。某个月的结算日 = `min(resetDay, 该月天数)`。周期起点是不晚于今天的最近一个结算日，`nextReset` 是其后一个月的结算日。日期字符串的格式与 `UsageAggregator.dayKey(for:)`（244 行）一致。

单元测试（传入固定时区的 `Calendar`）：

| `resetDay` | `now` | `startDay` | `endDay` |
| --- | --- | --- | --- |
| 1 | 2026-11-12 | 2026-11-01 | 2026-11-30 |
| 15 | 2027-01-03 | 2026-12-15 | 2027-01-14 |
| 31 | 2026-02-15 | 2026-01-31 | 2026-02-27 |
| 31 | 2026-02-28 | 2026-02-28 | 2026-03-30 |
| 31 | 2028-02-29（闰年） | 2028-02-29 | 2028-03-30 |
| 0 或 40 | 任意 | 按 1 或 31 处理 | |

**查询**。在 `UsageStore` 新增：

```swift
public func routeTotals(from startDay: String, through endDay: String) throws -> [TrafficRoute: Int64]
```

`daily_route_usage` JOIN `apps`，条件 `accounting_version = ?`、日期范围、`apps.category != ?`（绑定 `AppCategory.proxyTransport.rawValue`），按 `route` 分组，上下行相加。写法参照 `routeUsage`，加 `lock`。结果用 `saturatingAdd` 合并。测试加在 `RouteUsageTests.swift`：跨两天累加、范围外的日期不计、代理传输应用的行不计。

**口径**：

- 「已用」= 周期内 `.proxyNode` 的上下行合计。
- `.proxied`（出口未知）单独显示为「另有 X 出口未知」，不并入已用，不按比例估算（与 REVIEW §7.2.1 的方向一致）。**需用户决定**是否改为并入；默认不并入。
- `.proxyRuleDirect` 与 `.direct` 不计。
- 「代理分流」开关关闭、或周期内有未读到连接表的时段时，已用会偏小。界面用一句说明覆盖这一点，见下。

**这个数字不等于机场后台的用量**，文案必须写明是本机估算。差异来源：其他设备的用量、倍率节点、协议封装开销、出口未知的部分、ByteTrace 未运行的时段。

**ViewModel**（`ByteTraceViewModel.swift`）：

- 两个设置项各一个 `@Published` 属性，`didSet` 里写回 `UserDefaults`，写法参照 `readsMihomoConnections`（395 行）。
- `@Published private(set) var proxyPeriodUsage: ProxyPeriodUsage?`，包含 `period`、`nodeBytes`、`unknownExitBytes`、`quotaBytes`。
- 在主窗口总览的刷新路径里加载：`refreshIfNeeded` 的 `rangeDue` 分支（1784 行）和 `refreshOverview`（797 行），与 `loadRange` 同频（10 秒节流），不新增定时器。它与 `selectedRange` 无关，切换范围时不需要重算。设置项变化时立即重算一次。
- `clearAllData`（889 行）里置空。

**界面**（位置为建议，实施前用一段文字向用户确认）：

- 主窗口 `OverviewHeader`（`MainWindowView.swift:472`）下方加一行：`代理周期 11/01–11/30 · 已用 38.2 GB / 100 GB · 23 天后重置`，下面一条细进度条。进度条可复用 `RouteSegmentBar` 的画法或 `ProgressView`。
- 没有设置额度时只显示已用，不显示进度条与百分比。
- 周期内 `nodeBytes` 与 `unknownExitBytes` 都为 0、且没有设置额度时，整行不显示（不使用代理的用户看不到这个功能）。
- 超过额度时进度条封顶，文字显示「已超出 X」，不弹通知。
- `.help(...)` 文案：`按本机记录估算：只统计本机经代理节点的流量，不含其他设备、倍率与协议开销，可能与服务商后台不一致。`
- 设置页 `proxySection`（`SettingsView.swift:82`）加两项：「结算日」`Picker`（每月 1 日 … 31 日）和「周期额度」（数字输入，单位 GB，空或 0 表示不设）。输入框用 `.focusEffectDisabled()`，并确认打开设置页时它没有被自动聚焦。GB 与字节的换算用 10⁹：`formatBytes`（1009 行）按 1000 进位（1 GB = 1,000,000,000 字节），额度必须用同一个换算，否则「已用」与「额度」的单位对不上。

**验收**：`ProxyBillingPeriod` 与 `routeTotals` 的单元测试；`swift build` 通过。界面行为未经运行验证，交用户检查：有额度／无额度／无代理流量三种状态，结算日改动后数字立即变化。

### 2.3 F1b：按节点统计（新增一张表）

**需用户先确认的一点**：现在的约定是连接表「不落库」（`CLAUDE.md`「mihomo 连接表」一节）。本项会把**节点名称**写入本机数据库，域名、IP、端口仍然不保存。用户同意后再实施。

**数据怎么流过去**。节点名要从 mihomo 缓存一路带到聚合器，中间有两处会按路径合并连接（`SupplementalTrafficReducer`、`SupplementalResidualTracker`），合并键里要加上节点名，否则同一进程走不同节点的连接会被并成一条。

1. `Sources/ByteTraceCore/Storage/TrafficRoute.swift` 新增：

   ```swift
   public struct RouteResolution: Hashable, Sendable {
       public let route: TrafficRoute
       public let exitName: String?   // 只在 route == .proxyNode 时非空
       public init(route: TrafficRoute, exitName: String? = nil)
       public static let proxied = RouteResolution(route: .proxied)
   }
   ```

   初始化时归一：`route != .proxyNode` 或名称去掉首尾空白后为空 → `exitName = nil`；名称超过 128 个字符时截断。

2. `MihomoConnections.swift`：`MihomoConnection` 增加 `exitName: String?`（`chains.first` 去空白，仅 `.proxyNode` 时保留）。`MihomoRouteTracker.Entry` 存 `RouteResolution`，新增 `resolution(forLocalEndpoint:)`；现有 `route(forLocalEndpoint:)` 保留，改为返回 `resolution(...)?.route`，已有调用与测试不用改。REVIEW T4 给这个方法加的 `at now:` 参数和冲突处理要一并适用于 `resolution`：同一快照里同一端点出现两次且 `RouteResolution` 不同，记 `.proxied`。

3. `TrafficFilter.swift`：`RoutedDelta` 增加 `exitName: String?`（init 默认 `nil`）。`SupplementalTrafficReducer.reduceWithRoutes` 的 `route` 参数类型从 `(NettopDelta) -> TrafficRoute` 改为 `(NettopDelta) -> RouteResolution`，默认值 `{ _ in .proxied }`；内部 `Key.route` 改为 `RouteResolution`，输出时拆成 `route` 与 `exitName`。

4. `SupplementalResidualTracker.swift`：`residuals(...)` 的 `route` 参数同样改类型；`Kind.route` 改为 `RouteResolution`。残差仍记到窗口内字节最多的一类，现在这一类包含节点名，规则不变。

5. 调用点（读代码，共 4 处传了闭包或依赖这个类型，改之前用 `grep -rn 'reduceWithRoutes\|\.residuals(' Sources Tests` 复核）：
   - `ByteTraceViewModel.swift:1296` 的闭包和 `supplementalRoute(for:)`（1399 行）：改为返回 `RouteResolution`，关闭「代理分流」时返回 `.proxied`。
   - `ByteTraceViewModel.swift:1312`：外部通道 `RoutedDelta(delta:route: .direct)`，不用改。
   - `Sources/ByteTraceProbe/main.swift:422`：闭包包一层 `RouteResolution`。
   - `Tests/ByteTraceCoreTests/RouteUsageTests.swift:78`、`SupplementalResidualTrackerTests.swift`：传了 `route` 闭包的用例改返回类型。

6. `UsageModels.swift`：`UsageDelta` 增加 `exitName: String?`（init 末尾，默认 `nil`）。`ByteTraceViewModel.ingest(_:route:)`（1528 行）增加 `exitName` 参数并传入；代理传输进程传 `nil`，与 `route` 的处理一致（1565 行）。

7. `UsageAggregator.swift`：新增 `pendingExits: [ExitKey: ExitUsageAggregate]`，`ExitKey` 为 `(day, appKey, exitName)`。只在 `delta.route == .proxyNode` 且 `exitName` 非空时累加，写法照 `pendingRoutes`（82–91 行），同样受 `maxPendingEntries` 限制。`flush()` 把它传给 `store.apply`，成功后与另外两个 pending 一起清空；`discardPending()` 也要清。

**表结构**（追加一个迁移分支）：

```sql
CREATE TABLE IF NOT EXISTS daily_exit_usage (
    accounting_version INTEGER NOT NULL CHECK (accounting_version > 0),
    day TEXT NOT NULL,
    app_key TEXT NOT NULL,
    exit_name TEXT NOT NULL,
    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
    updated_at TEXT NOT NULL,
    PRIMARY KEY (accounting_version, day, app_key, exit_name),
    FOREIGN KEY (app_key) REFERENCES apps(app_key)
);
```

- 不带 `program_key`：节点 × 程序的组合用处小，行数会成倍增加。**用户可以改**。
- 写入：`UsageStore.apply` 增加参数 `exitAggregates: [ExitUsageAggregate] = []`，在同一个事务里 upsert，语句与 `prepareRouteUsageUpsert`（2201 行）同构（`ON CONFLICT … DO UPDATE SET x = x + excluded.x`）。`apps` 的 upsert 已经排在前面（157 行），外键成立。
- `clearAll()`（971 行）在 `DELETE FROM apps` 之前加 `DELETE FROM daily_exit_usage;`。
- 不参与保留策略，与 `daily_usage` 一样长期保留。
- 用 `grep -n 'DELETE FROM apps\|deleteAppRows' Sources/ByteTraceCore/Storage/UsageStore.swift` 确认：除 `clearAll` 外，删除 `apps` 行的代码都在旧版本的迁移分支里，执行时新表还不存在。若有例外，那里也要先删 `daily_exit_usage` 的对应行，否则外键报错。
- 迁移测试：从上一个版本的库升级后表存在、`user_version` 正确；新库直接到最新版本。

**查询**：

```swift
public struct ExitUsageRecord: Equatable, Sendable {
    public let exitName: String
    public let appKey: String
    public let downloadBytes: Int64
    public let uploadBytes: Int64
}
public func exitUsage(from startDay: String, through endDay: String) throws -> [ExitUsageRecord]
```

JOIN `apps` 排除代理传输，只取当前 `accountingVersion`。

**不变量**（写成 `RouteUsageTests` 的用例）：同一天同一应用，`daily_exit_usage` 各节点合计 ≤ `daily_route_usage` 里 `.proxyNode` 的字节；从空库开始、全部样本都带节点名时两者相等。`daily_usage` 的总量不受影响。

**界面**：

- F1a 的那一行可点击展开，下面列出本周期各节点用量：前 8 个，其余合并为「其他 N 个」。行组件复用 `DetailRowGroup` / `DetailRow`（`MainWindowView.swift:1017`、`1036`），列宽与应用行对齐。节点是实体，用列表行，符合现有约定。
- 各节点合计小于「已用」时（升级前的历史没有节点行），末尾加一行「未记录节点 X」。
- 应用展开详情里暂不加节点列表。**用户可以要求加**，数据已经按应用保存。

**导出**：`ByteTraceExportDocument` 增加 `exitUsage`（节点名、appKey、上下行），`formatVersion` 从 5 改为 6（`ByteTraceViewModel.swift:936`），范围用当前所选范围，不用结算周期。

**文案与文档**：设置页「代理分流」的说明（`SettingsView.swift:87`）补一句「节点名称保存在本机，用于按节点统计」。`CLAUDE.md` 的「mihomo 连接表」「存储」两节同步：新增的表、节点名落库、导出版本。

**已知局限**（写进 `CLAUDE.md`）：节点改名后是新的一行，不合并；短于轮询间隔（2 秒）就结束的连接查不到节点，仍记 `.proxied`；`url-test` 等策略组自动切换时记的是当时的叶子节点。

**验收**：解析测试（`chains` 为 `["节点A", "策略组"]` 得到 `exitName == "节点A"`；`DIRECT`、`REJECT`、空数组得到 `nil`）；reducer 测试（同一进程两条连接走不同节点，输出两条）；残差测试（残差带上主导类别的节点名）；聚合与存储测试（上面的不变量）；`swift build` 通过。真实数据的核对交用户：运行一段时间后执行

```bash
sqlite3 ~/Library/Application\ Support/com.nanvon.ByteTrace/usage.sqlite3 "SELECT exit_name, SUM(download_bytes + upload_bytes) FROM daily_exit_usage WHERE day = date('now','localtime') GROUP BY 1 ORDER BY 2 DESC;"
```

与 mihomo 面板里各节点的用量量级对照。

## 3. F2：数据库损坏处理

### 3.1 现状（读代码）

- `ByteTraceViewModel.init`（504–522 行）：`UsageStore(databaseURL:)` 抛出任何错误，`store` 与 `aggregator` 都置为 `nil`，`status = .failed("无法打开本地数据库：…")`。
- `start()`（599 行）在 `store == nil` 时直接返回。结果是数据库打不开时应用不采集，每次启动都一样，用户只能自己去删文件。
- 代码里没有 `integrity_check` / `quick_check`。
- `SQLiteDatabaseError`（`SQLiteDatabase.swift:4`）只带消息字符串，不带 SQLite 结果码，调用方分不出「文件损坏」和「权限、磁盘满、被占用、版本过新」。
- `migrate()`（1087 行）遇到比自己新的 `user_version` 时抛 `executeFailed("unsupported schema version N")`，界面显示的是这句英文。

没有复现过正式环境的数据库损坏。本项是补一条目前不存在的恢复路径，不是修一个已发生的故障。

### 3.2 F2a：打开失败时隔离并重建

**第 1 步，识别损坏**（`SQLiteDatabase.swift`）：

- `SQLiteDatabaseError` 增加 `case corrupt(String)`。
- 增加一个私有辅助方法：给定结果码，主结果码（`code & 0xFF`）为 `SQLITE_CORRUPT`（11）或 `SQLITE_NOTADB`（26）时返回 `.corrupt(消息)`，否则返回调用处原来的错误。
- 在 `init` 的 PRAGMA 失败分支、`execute`、`prepare`、`stepDone`、`scalarInt64` 里用它。`sqlite3_exec` 失败时结果码就是返回值；`init` 里要在 `sqlite3_close` 之前判断。
- `UsageStore` 里直接调 `sqlite3_step` 并抛 `stepFailed` 的十几处读取循环不改。运行期读到的损坏由 F2b 覆盖。
- `UsageStore.isSQLiteIntegerOverflow`（2308 行）匹配的是 `.stepFailed`，不受影响。
- `UsageStore` 增加 `public static func isCorruption(_ error: Error) -> Bool`，供应用层判断（`SQLiteDatabaseError` 是 internal 类型）。
- 版本过新单独识别：`migrate()` 改抛一个可识别的错误（例如 `SQLiteDatabaseError` 新增 `case unsupportedSchema(Int64)`），并增加 `public static func isNewerSchema(_ error: Error) -> Bool`。界面文案：「数据库由更新版本的 ByteTrace 创建，请升级应用后再使用。」**这种情况绝不能隔离重建**，否则降级运行一次就会让用户以为数据没了。

**第 2 步，隔离**（`UsageStore.swift`，纯文件操作，可测）：

```swift
/// 把数据库主文件与 -wal、-shm 一起改名保留，返回新的主文件路径。
public static func quarantineDatabase(at url: URL, now: Date = Date()) throws -> URL
```

目标名 `usage.corrupt-<yyyyMMdd-HHmmss>.sqlite3`，同目录；`-wal`、`-shm` 存在时用同样的前缀一并移动。目标已存在时在时间后加 `-2`、`-3`。用 `FileManager.moveItem`，不复制、不删除。

**第 3 步，启动流程**（`ByteTraceViewModel.swift`）。把 504–522 行的打开逻辑抽成一个静态方法，返回 `(store: UsageStore?, error: String?, notice: String?)`：

1. 打开成功 → 返回。
2. 失败且 `isNewerSchema` → 返回上面的文案，不重试。
3. 失败且 `isCorruption` →
   - 用一个**局部的** `DataDirectoryLock`（同一个 `defaultLockURL`）`tryAcquire()`。`init` 里 `super.init()` 之前不能访问 `self.instanceLock`，所以这里新建一个临时对象，用完 `release()`。
   - 拿不到锁：说明另一个实例正在使用这份数据，不隔离，返回错误「数据库无法读取，另一个 ByteTrace 正在运行；请退出它之后重新打开。」
   - 拿到锁：`quarantineDatabase` → 重新 `UsageStore(databaseURL:)` → 释放锁。重建成功时返回新 store 和提示；重建又失败时返回错误，不再重试。
4. 其他错误（权限、磁盘满、被占用）→ 与现在一样返回错误，不隔离。

**第 4 步，告知用户**：

- `lastError` 在 `start()` 里会被清空（617 行），不能用来承载这条提示。新增 `@Published private(set) var storageNotice: String?`，内容：「数据库已损坏，旧文件已另存为 usage.corrupt-….sqlite3，统计从现在重新开始。」
- 持久化在 `UserDefaults` 键 `ByteTrace.storageRecoveryNotice`，用户点「知道了」后清除，重启前不会丢。
- 显示位置：主窗口 `statusBar`（`MainWindowView.swift:354`）与菜单栏 `statusCard`（`MenuBarView.swift:140`），带「在访达中显示」和「知道了」两个按钮，都加 `.focusable(false)`。
- 在新库里记一条 `collector_events`：`kind = "database_quarantined"`，`details` 为旧文件名。
- 隔离出来的文件不自动删除，不自动读取。设置页「数据」一节在存在这类文件时显示「已另存的旧数据库 N 个，共 X MB」和「在访达中显示」。从旧文件里抢救数据不在本项范围，见 3.4。

**测试**（新文件 `Tests/ByteTraceCoreTests/UsageStoreRecoveryTests.swift`，用临时目录）：

| 用例 | 期望 |
| --- | --- |
| 数据库文件是 4 KB 随机字节 | `UsageStore.init` 抛错，`isCorruption == true` |
| 文件 `user_version = 9999` | 抛错，`isNewerSchema == true`，`isCorruption == false` |
| 目录只读或路径是一个目录 | 抛错，两个判断都为 `false` |
| `quarantineDatabase`，主文件与 `-wal`、`-shm` 都存在 | 三个文件都被改名，原路径不存在，随后能在原路径新建并打开 |
| 同一秒内调用两次 | 第二次的文件名带后缀，不覆盖第一次 |

启动流程在应用 target，没有测试，靠阅读确认，并在提交说明里写明。交用户手动验证的做法：退出应用，把正式库**复制**到别处备份，用 `head -c 4096 /dev/urandom > usage.sqlite3` 覆盖原文件并删掉 `-wal`、`-shm`，启动应用，应看到提示、旧文件被改名、采集正常；验证后退出应用并把备份放回去。这一步会动正式数据，必须由用户自己执行。

### 3.3 F2b：后台完整性检查

打开时只能发现文件头与 schema 层面的损坏，页面级损坏要靠检查。

- `UsageStore` 新增 `public func quickCheck() throws -> Bool`：执行 `PRAGMA quick_check(1);`，第一行为 `ok` 返回 `true`。全程持有 `lock`。
- **先测耗时再实现调度**：用 `sqlite3 <正式库> ".backup <副本>"` 复制一份，在副本上执行 `PRAGMA quick_check(1);` 计时，把数字报给用户。检查期间落库会等锁，主线程卡住同样的时长。超过 2 秒时停下来问用户是否接受，或改为只在迁移后检查一次。
- 调度：在 `retentionQueue` 上执行，排在当天的 `purgeBuckets` 之后，复用 `retentionCleanupInProgress` 门控；间隔不少于 7 天（`UserDefaults` 键 `ByteTrace.lastIntegrityCheckAt`）；只在没有界面可见时执行（`observedUsageSurfaces.isEmpty`）。
- 检查不通过：记 `collector_events`（`database_integrity_failed`），设置 `UserDefaults` 键 `ByteTrace.pendingDatabaseQuarantine = true`，`storageNotice` 显示「数据库检查发现损坏，下次启动时会另存旧文件并重新开始统计。」**运行中不替换数据库**：替换需要停采集、排空、换连接，这条路径现在不存在（见 ROADMAP §3.1）。
- 下次启动：3.2 第 3 步的静态方法在打开成功后检查这个标记；有标记时同步执行一次 `quickCheck()` 确认（只在这条少见的路径上承担这次耗时），仍不通过就走隔离流程，通过则清掉标记。
- 测试：正常库 `quickCheck()` 为 `true`。构造页面级损坏的夹具不稳定，不强求；能稳定构造（例如写入足够多的行后把文件中段若干页清零）就加一个用例，不能就在提交说明里写明这一分支未覆盖。

### 3.4 不在本项范围，留给用户决定

- **从旧文件抢救数据**：以只读方式 ATTACH 隔离出的文件，把 `apps`、`programs`、`daily_usage`、`daily_route_usage` 里还能读的行复制到新库。只在两边 schema 版本相同时可行，读到坏页要能跳过。有需求再做。
- **重建类迁移前自动备份**：版本 12 那样的重建一旦有错无法还原。可以在这类迁移前用 `VACUUM INTO` 留一份，代价是升级那次启动多几秒和一份库大小的磁盘空间。REVIEW §3 已建议以后的重型迁移放到后台并显示进度，两件事适合一起设计。
- **写入持续失败**：`flushNow`（1734 行）失败时每 5 秒记一条 `database_error` 事件并覆盖 `lastError`，样本留在内存里重试，`pending` 到 10,000 项后新键被丢弃（`UsageAggregator.swift:100`）。可以改成事件去重并在界面显示失败持续的时长。没有证据表明这种情况发生过，优先级低。

## 4. F3：新出现的应用与程序

### 4.1 现状（读代码）

- `apps.first_seen_at` 与 `programs.first_seen_at` 是 `String(format: "%.6f")` 的 epoch 秒文本。`apps` 的 upsert 在冲突时不改 `first_seen_at`（2115 行），`programs` 取 `MIN`（2147 行）。版本 12、13 的迁移合并记录时也取 `MIN`（1310、1510 行），历史值保留。
- 应用层没有任何地方读取这两个字段。

### 4.2 方案

**查询**（`UsageStore.swift`）：

```swift
/// 首次出现时间不早于 `date` 的宿主与程序。排除代理传输。
public func firstSeen(since date: Date) throws -> (apps: [String: Date], programs: [String: Date])
/// 全部宿主中最早的首次出现时间；空库或没有有效值时为 nil。
public func earliestFirstSeen() throws -> Date?
```

比较用 `CAST(first_seen_at AS REAL) >= ?`，不要直接比文本。`earliestFirstSeen` 忽略小于等于 0 的值（迁移兜底写过 `0.000000`）。两张表都只有几百行，不需要索引。

**判定**（Core 里的纯函数，建议放 `UsageModels.swift` 或新文件）：

```swift
public enum NewArrivalPolicy {
    public static let learningPeriod: TimeInterval = 3 * 24 * 60 * 60
    public static func threshold(windowStart: Date, earliestFirstSeen: Date?) -> Date?
}
```

- 没有 `earliestFirstSeen` 时返回 `nil`（不标记）。
- 否则返回 `max(windowStart, earliestFirstSeen + learningPeriod)`。首次出现时间不早于这个阈值的算「新出现」。
- 学习期的作用：新安装或清空统计后的头 3 天，所有应用都是第一次出现，全部标记没有意义。3 天这个值**用户可以改**。

范围与阈值的对应：「今天」用今天 0 点；「本周」「本月」「上月」用 `rangeWindow.start`，「上月」另加上界 `rangeWindow.end`；「全部」不标记。

不标记的对象：虚拟宿主（`host:system`、`host:other`）本身不标，它们下面的程序照常判断；代理传输不标。

**ViewModel**：

- `@Published private(set) var rangeNewAppKeys: Set<String>`、`rangeNewProgramKeys: Set<String>`，在 `loadRange`（1934 行）里随范围数据一起加载。
- `@Published private(set) var todayNewAppKeys: Set<String>`，在 `loadToday`（1851 行）里加载，供菜单栏使用。
- `clearAllData` 里清空。
- 每次刷新多两条小查询，与现有刷新同频，不新增定时器。

**界面**：

- 主窗口 `UsageRow`（`MainWindowView.swift:771`）增加可选的 `badge: String?`，在名称后显示一个小标签「新」（caption 字号、次要色描边或浅底，不用强调色，避免整列发亮）。`rowWithDetail`（204 行）传入。
- `listHeader` 的说明文字（`listDetail`，190 行）在有新应用时追加「新出现 N 个」。
- 应用展开详情的程序列表（`programRows`，922 行）：新程序在名称后加同样的标签。宿主本身不是新的、但它下面出现了新程序时，宿主行不标，只在展开后看到。
- 菜单栏 `UsageRowView`（`MenuBarView.swift:549`）在名称后加同样的标签。
- `.help` 文案：`首次联网：11 月 12 日 14:32`（用 `firstSeen` 返回的时间）。
- 可选，**用户可以要求加**：点击「新出现 N 个」只看新应用。

**已知局限**（写进 `CLAUDE.md`）：

- 「首次」指 ByteTrace 第一次记录到，不是应用安装时间。
- `appKey` 或 `program_key` 变了的同一个应用会被当成新的：无 bundle ID 的应用换了路径（`app:<路径>`）、`exec:` 路径里出现归一化规则没覆盖的版本号。这类误报本身也提示了归一化规则的缺口。
- 以后改动键的派生规则时，迁移必须像现在一样保留最早的 `first_seen_at`，否则升级后会出现一批误报。

**验收**：`firstSeen(since:)` 测试（边界时间、代理传输被排除、程序与宿主分别返回）；`earliestFirstSeen` 测试（空库、含 `0.000000` 的行）；`NewArrivalPolicy` 测试（学习期内、学习期外、无最早时间）；`swift build` 通过。界面未经运行验证。

## 5. F4：隐藏、置顶与右键菜单

### 5.1 现状（读代码）

- 主窗口列表按流量排序，默认前 20 个（`collapsedRowLimit`，`MainWindowView.swift:22`），菜单栏默认 10 个。没有隐藏或固定的逻辑。
- 应用层没有任何 `contextMenu`。路径只出现在悬停提示和展开详情的脚注里。

### 5.2 语义

- **隐藏只影响列表，不影响任何数字**。总量、占比的分母、趋势图、直连／代理拆分、导出都照旧包含被隐藏的应用（总量口径不变是既定决定）。
- 因为总量仍包含它们，列表末尾必须显示「已隐藏 N 个 · 共 X」，带「显示」切换，否则列表各行加起来对不上总量，用户会以为统计有误。
- 搜索时（`searchText` 非空）被隐藏的应用也参与匹配，方便找回。
- **置顶**的应用排在最前，彼此之间仍按流量排序；折叠状态下置顶的行总是显示，其余行补到 `collapsedRowLimit` 为止。当前范围内没有流量的置顶应用不显示（没有记录可画）。
- 同一个应用不能既隐藏又置顶：执行其中一个操作时取消另一个。
- 菜单栏面板同样遵守隐藏与置顶。

### 5.3 实现

**存储**：`UserDefaults` 键 `ByteTrace.pinnedAppKeys`、`ByteTrace.hiddenAppKeys`，都是字符串数组，存 `appKey`。各自上限 500 项，超出时丢最早加入的。`clearAllData` 不清这两项（它们是偏好，不是统计）。

**排列逻辑**放 Core（建议 `Sources/ByteTraceCore/Storage/AppListArrangement.swift`），不依赖界面类型：

```swift
public struct AppListArrangement: Equatable, Sendable {
    public let pinned: [String]      // 置顶的 appKey，保持传入顺序
    public let regular: [String]
    public let hidden: [String]
    public static func arrange(orderedKeys: [String], pinned: Set<String>, hidden: Set<String>) -> AppListArrangement
    /// 折叠时显示的 appKey：全部置顶 + 其余的前若干个，总数不超过 max(limit, 置顶数)。
    public func collapsed(limit: Int) -> [String]
}
```

测试：只有置顶、只有隐藏、两者都有、键同时出现在两个集合里（按隐藏处理）、置顶数超过 `limit`、空输入、输出保持输入顺序。

**ViewModel**：两个 `@Published private(set)` 集合，加 `togglePinned(_:)`、`toggleHidden(_:)`、`unhideAll()`，写回 `UserDefaults`。`applicationRecords`（544 行）与 `rangeApplicationRecords`（549 行）保持原样返回全部记录，因为总量与占比都从它们计算；另外提供排列后的结果给列表用，不要在这两个属性里过滤。

**主窗口**（`MainWindowView.swift`）：

- `appList`（113 行）改用排列结果决定 `visible`。`shareBase` 仍是 `model.selectedRangeTotals.totalBytes`。
- `listsAllRows`（107 行）、「显示其余 N 个」（144 行）、「收起」时对 `expandedAppKey` 的处理（153 行）都要按排列后的列表计算。
- `handlePendingRequests`（304 行起）用 `index >= Self.collapsedRowLimit` 判断是否要展开全部（318 行），同样改为按排列后的可见列表判断。
- 置顶的行在名称前或图标角上加一个小的 `pin.fill`；显示出来的隐藏行整体降低不透明度。
- 新增「已隐藏 N 个 · 共 X」一行，写法参照 `listToggle`（266 行），加 `.focusable(false)`。

**右键菜单**。加在 `rowWithDetail` 的 `Button`（212 行）和菜单栏 `UsageRows` 的 `Button`（`MenuBarView.swift:521`）上，把菜单内容写成一个共用的 `ViewModifier` 或函数，两处复用：

| 菜单项 | 行为 | 何时不可用 |
| --- | --- | --- |
| 置顶 / 取消置顶 | `togglePinned` | |
| 隐藏 / 取消隐藏 | `toggleHidden` | |
| 分隔线 | | |
| 在访达中显示 | `NSWorkspace.shared.activateFileViewerSelecting`，路径取 `bundlePath ?? executablePath` | 没有路径、或文件已不存在时不显示这一项 |
| 拷贝路径 | 写入 `NSPasteboard.general` | 同上 |
| 拷贝名称与用量 | `名称<Tab>格式化后的字节数` | |

虚拟宿主没有路径，只显示前两项和最后一项。

**未验证**：`.contextMenu` 在 `MenuBarExtra` 的 `.window` 样式面板里能否正常弹出、弹出后面板是否会被关闭。主窗口先做；菜单栏面板加上后由用户确认，有问题就只保留主窗口的菜单。

**设置页**：`SettingsView` 加一节「已隐藏的应用」，仅在有隐藏项时显示：列出名称（库里查不到名称时显示 `appKey`），每行一个「恢复」，底部「全部恢复」。按钮加 `.focusable(false)`。

**验收**：`AppListArrangement` 的单元测试；`swift build` 通过。交用户手动检查：隐藏后总量与百分比不变；末尾的隐藏汇总行数字正确；搜索能找到被隐藏的应用；置顶行在折叠状态下始终可见；从菜单栏点击某个应用跳到主窗口时能正确定位并展开；窗口打开时没有控件出现蓝色焦点环。

## 6. 任务清单

每个任务单独做、单独提交。顺序按风险从低到高排列。

| 任务 | 依据 | 允许改动的文件 | 完成标准 |
| --- | --- | --- | --- |
| G1 隐藏、置顶与右键菜单 | §5 | 新增 `Sources/ByteTraceCore/Storage/AppListArrangement.swift` 与对应测试；`ByteTraceViewModel.swift`、`MainWindowView.swift`、`MenuBarView.swift`、`SettingsView.swift`、`CLAUDE.md` | §5.3 的单元测试；`swift build` 通过；列出未经运行验证的界面行为 |
| G2 新出现的应用与程序 | §4 | `UsageStore.swift`、`UsageModels.swift`（或新文件）与对应测试；`ByteTraceViewModel.swift`、`MainWindowView.swift`、`MenuBarView.swift`、`CLAUDE.md` | §4.2 的单元测试；`swift build` 通过 |
| G3 数据库损坏时隔离并重建 | §3.2 | `SQLiteDatabase.swift`、`UsageStore.swift`、新增 `UsageStoreRecoveryTests.swift`；`ByteTraceViewModel.swift`、`MainWindowView.swift`、`MenuBarView.swift`、`SettingsView.swift`、`CLAUDE.md` | §3.2 的五个用例；版本过新不触发隔离；`swift build` 通过；提交说明写明启动流程未经运行验证 |
| G4 代理用量周期与额度 | §2.2 | 新增 `ProxyBillingPeriod.swift` 与测试；`UsageStore.swift`、`RouteUsageTests.swift`、`ByteTraceViewModel.swift`、`MainWindowView.swift`、`SettingsView.swift`、`CLAUDE.md` | 周期与查询的单元测试；界面位置先向用户确认；`swift build` 通过 |
| G5 按节点统计 | §2.3 | `TrafficRoute.swift`、`MihomoConnections.swift`、`TrafficFilter.swift`、`SupplementalResidualTracker.swift`、`UsageModels.swift`、`UsageAggregator.swift`、`UsageStore.swift`、`Sources/ByteTraceProbe/main.swift`、相关测试文件；`ByteTraceViewModel.swift`、`ByteTraceExport.swift`、`MainWindowView.swift`、`SettingsView.swift`、`CLAUDE.md` | 用户已同意节点名落库；REVIEW T4 已完成；§2.3 的全部测试；迁移测试；`swift build` 通过 |
| G6 后台完整性检查 | §3.3 | `UsageStore.swift` 与测试、`ByteTraceViewModel.swift`、`CLAUDE.md` | 先在正式库副本上量 `quick_check` 耗时并报告，用户确认后再实现 |

依赖：G5 依赖 G4（界面入口）和 REVIEW T4；G6 依赖 G3（隔离流程）。G1、G2、G3、G4 互不依赖。

G1、G2、G4 都会改 `MainWindowView.swift` 的列表与总览部分，不要并行做，按顺序一个一个来。

每个带用户可见变化的任务完成后，在提交说明里用一两句面向用户的话描述变化，发版时写 `release-notes/` 要用。

## 7. 需用户决定的事项

| 事项 | 默认 | 位置 |
| --- | --- | --- |
| 节点名称是否允许写入本机数据库 | 未决定，G5 开始前必须确认 | §2.3 |
| 额度进度是否把「出口未知」并入已用 | 不并入，单独显示 | §2.2 |
| `daily_exit_usage` 是否带 `program_key` | 不带 | §2.3 |
| 应用展开详情里是否列出该应用用过的节点 | 不列 | §2.3 |
| 新出现判定的学习期 | 3 天 | §4.2 |
| 是否提供「只看新出现」的筛选 | 不提供 | §4.2 |
| `quick_check` 耗时超过 2 秒时是否仍定期执行 | 测完再定 | §3.3 |
| 是否做旧库数据抢救、迁移前备份 | 不做 | §3.4 |
| 菜单栏面板的右键菜单表现不正常时 | 只保留主窗口的菜单 | §5.3 |

## 8. 评估过、本文没有展开的事项

有需求时再单独写方案。

| 事项 | 没有展开的原因 |
| --- | --- |
| 按网络（Wi-Fi 名称、热点）统计 | 读 SSID 需要定位权限，ad-hoc 签名下能否拿到没有验证；要新增存储维度 |
| Shortcuts / App Intents | 代码量小，但要先定对外暴露哪些查询，以及没有界面可见时如何取到最新数字（当前刷新受可见性门控） |
| 全局快捷键与列表键盘操作 | 全局快捷键不引入第三方库时要用 Carbon 的 `RegisterEventHotKey`，需要单独评估 |
| 英文界面 | 文案分散在各视图里且都是硬编码，要先整体抽取，改动面大 |
| 诊断信息导出 | 独立的小功能，依赖 ROADMAP §2.2 对 `collector_events` 的读取，适合一起做 |
| 界面逻辑下沉到 Core 并补测试 | 是重构，不产生用户可见变化；本文各任务已按「纯逻辑进 Core」的方式做，可以逐步带过去 |
| Homebrew Cask | 改动在仓库之外，不涉及应用代码 |
