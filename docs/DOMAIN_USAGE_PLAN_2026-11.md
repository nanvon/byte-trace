# ByteTrace 按域名统计方案（2026-11-12）

> 代码基线：`8ae3281`（v0.1.41 之后），与 [REVIEW_2026-11.md](REVIEW_2026-11.md)、[FEATURE_PLAN_2026-11.md](FEATURE_PLAN_2026-11.md) 相同
> 前提不变：不使用 Apple 付费开发者身份，不加 root，不启用 Network Extension，ad-hoc 签名，不引入第三方依赖
> 状态：D1–D6 已实施。覆盖率实测见 §5。任务清单见 §9。

本文的「读代码」指基线 `8ae3281` 的静态阅读，行号是该基线下的位置。实施后的字段核对见 §4.3，覆盖率测量见 §5。

## 0. 实施者守则

沿用 [FEATURE_PLAN_2026-11.md](FEATURE_PLAN_2026-11.md) §0 的八条，要点重复如下：

1. 一次只做 §9 的一个任务，做完停下来给用户看 diff。提交要等用户说。
2. 动手前按当前代码复核本文引用的行号与事实；与本文不符时停下来报告，不要按自己的理解继续。
3. 只改任务表「允许改动的文件」一栏列出的文件。需要多改时先说明范围，等用户同意。
4. 写完只运行 `swift build` 做编译检查。`swift test`、探针、打包都要先说明原因再运行。不做界面自动化。
5. 遇到「需用户决定」的事项时停下来问。本文替用户选了默认值的地方都写明了「用户可以改」。
6. 沿用 `CLAUDE.md` 的约定：面向用户的文案用中文；字节累加用就近的 `saturatingAdd`；`ByteTraceCore` 的 public 类型显式写 `public init`，模型 `Equatable, Sendable`；新增按钮与可点击行加 `.focusable(false)`；汇总逻辑一律排除 `category == .proxyTransport`；schema 变更追加迁移分支并同步 `UsageStore.schemaVersion` 与 `CLAUDE.md`。
7. 纯逻辑放进 `ByteTraceCore` 并写单元测试。应用 target 没有测试。
8. 界面改动无法由执行者运行验证。带界面的任务完成时，列出「未经运行验证」的界面行为，交给用户手动检查。

另加一条：**域名只允许出现在 `daily_domain_usage` 表、导出文件和界面里**。不写入 `collector_events`，不写日志，不出现在错误消息里。

## 1. 目标与范围

用户长期开着 mihomo 的系统代理和 TUN，想看每个应用访问了哪些域名、各用了多少流量，代理流量优先，规则直连其次。

做：

- 应用展开详情里列出该应用的域名排行，每个域名标注直连或代理。
- 域名用量写入本机 SQLite，长期保留，可导出。

不做：

- 完整网址、页面、浏览器标签页级别的统计。mihomo 只提供主机名。
- 全局的「域名排行」视图（跨应用）。数据按应用保存，后续可加。
- 按节点统计的表与界面。那是 [FEATURE_PLAN_2026-11.md](FEATURE_PLAN_2026-11.md) §2.3（F1b）的范围；本文只把节点名放进同一个传递类型里，供 F1b 直接使用。
- 用 mihomo 的字节数替换或修正 nettop 的字节数。字节仍以 nettop 为准，mihomo 只提供标签。

## 2. 现状（读代码）

- `MihomoConnectionsParser`（`MihomoConnections.swift:34`）只解码 `metadata.sourceIP` / `sourcePort`、`upload`、`download`、`chains`。域名字段没有解码。
- `MihomoRouteTracker`（同文件 95 行起）以应用侧本地端点为键缓存 `TrafficRoute`，保留 120 秒。`route(forLocalEndpoint:)`（120 行）读取时不检查过期，同端点冲突不处理。这是 REVIEW §7.1.1 记录的缺陷，修法在 REVIEW §8.6（任务 T4）。
- `ByteTraceViewModel.supplementalRoute(for:)`（1399 行）查这个缓存，结果作为闭包传给两处：
  - `SupplementalResidualTracker.residuals(...)`（`SupplementalResidualTracker.swift:44`），合并键 `Kind` 是「接口 + 路径」（17 行）。
  - `SupplementalTrafficReducer.reduceWithRoutes(...)`（`TrafficFilter.swift:110`），合并键 `Key` 是「进程名 + 来源 + 路径」（95 行）。合并后端点信息被丢弃。
- `ByteTraceViewModel.ingest(_:route:)`（1528 行）做进程归属并构造 `UsageDelta`（`UsageModels.swift:3`）；代理传输进程的 `route` 传 `nil`（1565 行）。
- `UsageAggregator.ingest`（`UsageAggregator.swift:69`）把路径累加进 `pendingRoutes`；`flush()`（139 行）在一个事务里交给 `UsageStore.apply`（`UsageStore.swift:112`）。
- 应用展开详情是 `AppDetailPanel`（`MainWindowView.swift:835`）：趋势图、图例行、程序排行（`DetailRowGroup`，916 行）、用途说明与路径。出现和消失时调用 `beginObservingAppDetail` / `endObservingAppDetail`（`ByteTraceViewModel.swift:586`、`591`）。
- 设置页「代理分流」的说明写着「不读取域名」（`SettingsView.swift:87`、`89`）。
- [NEXT_MAJOR_VERSION_PLAN.md](NEXT_MAJOR_VERSION_PLAN.md) 第 23 行把「全量连接、域名历史」列在「暂不纳入」。用户已于 2026-11-12 明确同意域名落库，这一行要同步修改。
- 探针 `--routes` 自己维护一个 `MihomoRouteTracker`，每 1 秒轮询（`Sources/ByteTraceProbe/main.swift:543`），应用是 2 秒（`ByteTraceViewModel.swift:410`）。探针的匹配闭包在 420–423 行。

## 3. 与其他文档的关系

- **REVIEW 的 T4 是前置任务**。路径分错只影响分类；域名分错会把流量记到别的域名上。本文任务 D1 就是执行 T4，细则以 REVIEW §8.6 为准。
- **与 F1b 共用 `RouteResolution`**。F1b §2.3 第 1 条定义的 `RouteResolution` 只有 `route` 和 `exitName`；本文的定义多一个 `domain`（§4.1）。谁先实施谁定义，后做的一方只补自己的字段和表。两份方案改同一批文件（`TrafficRoute.swift`、`MihomoConnections.swift`、`TrafficFilter.swift`、`SupplementalResidualTracker.swift`、`UsageModels.swift`、`UsageAggregator.swift`），不要并行做。
- **schema 版本**。域名用量使用版本 14。REVIEW 的 T1 追加下一 schema 版本。
- **导出版本**。使用实施时 `exportCurrentRange(to:)` 里的 `formatVersion + 1`（基线是 5，`ByteTraceViewModel.swift:936`）。
- **NStat 数据源（REVIEW §1）**。域名匹配依赖每条连接的应用侧本地端点。本文作者只读了 REVIEW 的结论部分，没有核对 NStat 方案是否保留这个字段（未验证）。如果先换数据源，要先确认这一点。

## 4. 设计

### 4.1 传递类型

`Sources/ByteTraceCore/Storage/TrafficRoute.swift` 新增（F1b 已定义时改为补字段）：

```swift
public struct RouteResolution: Hashable, Sendable {
    public let route: TrafficRoute
    public let exitName: String?   // 只在 route == .proxyNode 时非空；本文不落库，供 F1b 使用
    public let domain: String?     // 归一化后的域名；route == .direct 时恒为 nil
    public init(route: TrafficRoute, exitName: String? = nil, domain: String? = nil)
    public static let proxied = RouteResolution(route: .proxied)
}
```

初始化时归一：`route != .proxyNode` 或名称去掉首尾空白后为空 → `exitName = nil`，超过 128 个字符截断；`domain` 为空串 → `nil`。

### 4.2 域名归一化

新文件 `Sources/ByteTraceCore/Mihomo/DomainName.swift`，纯函数：

```swift
public enum DomainName {
    /// 主机名 → 用于统计的域名；IP 字面量、空串返回 nil。
    public static func registrable(_ host: String) -> String?
}
```

规则，按顺序：

1. 去掉首尾空白，转小写，去掉末尾的 `.`。结果为空 → `nil`。
2. IP 字面量 → `nil`：四段都是 0–255 数字的 IPv4，或包含 `:` 的 IPv6（含方括号形式）。
3. 长度超过 253 → `nil`。
4. 按 `.` 分段。只有一段（如 `localhost`）→ 原样返回。
5. 末两段拼成的后缀在内置的多段后缀表里 → 取末三段（不足三段时原样返回）；否则取末两段。

多段后缀表是一个内置的 `Set<String>`，首版收录：`com.cn`、`net.cn`、`org.cn`、`gov.cn`、`edu.cn`、`ac.cn`、`com.hk`、`com.tw`、`com.sg`、`com.au`、`net.au`、`org.au`、`co.uk`、`org.uk`、`ac.uk`、`gov.uk`、`co.jp`、`ne.jp`、`or.jp`、`ac.jp`、`co.kr`、`or.kr`、`co.in`、`com.br`、`com.mx`、`co.nz`、`co.za`、`com.tr`。不引入完整的 Public Suffix List（不加第三方依赖，也不打包大文件）。表里没有的多段后缀会被归到后缀本身，例如 `a.example.com.xx` 记成 `com.xx`，属于已知局限，发现后往表里加。

**默认存主域名，用户可以改为存完整主机名**。理由：完整主机名数量大，CDN 子域名（`rr3---sn-xxx.googlevideo.com`）会把排行打散，表行数也会多一个量级。改成完整主机名只需把第 4、5 步换成原样返回。

单元测试（新文件 `Tests/ByteTraceCoreTests/DomainNameTests.swift`）：

| 输入 | 输出 |
| --- | --- |
| `www.GitHub.com.` | `github.com` |
| `rr3---sn-abc.googlevideo.com` | `googlevideo.com` |
| `news.sina.com.cn` | `sina.com.cn` |
| `com.cn` | `com.cn` |
| `localhost` | `localhost` |
| `1.2.3.4`、`::1`、`[2001:db8::1]`、空串、纯空白 | `nil` |
| `xn--fiq228c.com` | `xn--fiq228c.com` |

### 4.3 解析 mihomo 连接

`MihomoConnections.swift`：

- `Payload.Connection.Metadata` 增加可选字段 `host`、`sniffHost`（均为 `String?`）。
- `MihomoConnection` 增加 `exitName: String?` 与 `domain: String?`，`init` 末尾带默认值 `nil`，已有调用不用改。
- `domain = DomainName.registrable(host)`；`host` 为空或得到 `nil` 时再试 `sniffHost`。
- `--domains` 探针会解码域名字段。正式应用在「代理分流」与「记录访问的域名」同时开启时才解码并记录域名。
- `exitName` = `chains.first` 去空白，仅在 `route == .proxyNode` 时保留。

**已核对**：2026-11-13 对本机 ClashBar 的 mihomo 发送一次只读 `GET /connections`，返回 82 条连接，`metadata.host` 和 `metadata.sniffHost` 的值均为字符串。换控制器时可用以下命令复查字段（把地址换成实际的控制器；Clash Verge 用 unix socket 时加 `--unix-socket /tmp/verge/verge-mihomo.sock`）：

```bash
curl -s http://127.0.0.1:9090/connections | python3 -c "import json,sys; c=json.load(sys.stdin)['connections']; print(sorted(c[0]['metadata'].keys()) if c else 'no connections')"
```

这条命令只打印键名，不打印域名。

### 4.4 缓存

`MihomoRouteTracker`（D1 完成后的版本上改）：

- `Entry` 存 `RouteResolution`。
- 新增 `resolution(forLocalEndpoint:at:)`，过期规则与 D1 给 `route(forLocalEndpoint:at:)` 加的一致。`route(forLocalEndpoint:at:)` 保留，改为返回 `resolution(...)?.route`，已有调用与测试不用改。
- 同一份快照里同一个本地端点出现两次：
  - 路径不同 → 记 `RouteResolution.proxied`（D1 的规则）。
  - 路径相同、域名或节点名不同 → 保留路径，不同的那个字段置 `nil`。

类名不改。

### 4.5 合并

`TrafficFilter.swift`：

- `RoutedDelta` 增加 `exitName: String?`、`domain: String?`，`init` 默认 `nil`。
- `reduceWithRoutes` 的 `route` 参数类型从 `(NettopDelta) -> TrafficRoute` 改为 `(NettopDelta) -> RouteResolution`，默认值 `{ _ in .proxied }`。内部 `Key.route` 改为 `RouteResolution`，输出时拆成三个字段。同一进程访问两个域名的连接因此输出两条。
- `reduce(_:proxyEndpoints:)`（101 行）不变。

### 4.6 已关闭连接的残差

`SupplementalResidualTracker.swift`。残差没有端点，现在记到该进程 30 秒窗口内字节最多的一类（102 行）。域名不能照搬这条规则：浏览器同时连几十个域名，把残差全记给字节最多的那个是错的。

- `residuals(...)` 的 `route` 参数改为 `(NettopDelta) -> RouteResolution`。
- `Kind` 仍是「接口 + 路径」，取 `resolution.route`。残差记到哪一类的规则不变。
- `History` 增加两项：`domains: [String: Date]`（窗口内受支持连接出现过的域名 → 最近一次出现时间）与 `lastUnlabeledAt: Date?`（最近一次出现没有域名的受支持连接）。
- 残差的域名：窗口内 `domains` 恰好只有一个，且 `lastUnlabeledAt` 不在窗口内 → 用这个域名；否则 `nil`。
- 残差的 `exitName` 本文恒为 `nil`，由 F1b 决定规则。
- 现有的 60 帧清理（119 行）顺带清掉 `domains` 里过期的项。

测试加在 `SupplementalResidualTrackerTests.swift`：单一域名时残差带域名；两个域名时残差域名为 `nil` 而路径照旧；窗口内有无域名连接时为 `nil`；域名过期后不再使用。现有三个用例传的 `route` 闭包要改返回类型。

### 4.7 聚合

`UsageModels.swift`：`UsageDelta` 增加 `domain: String?`（`init` 末尾，默认 `nil`）。新增：

```swift
public struct DomainUsageAggregate: Equatable, Sendable {
    public let day: String
    public let appKey: String
    public let domain: String
    public let route: TrafficRoute
    public let lastSeenAt: Date
    public let downloadBytes: Int64
    public let uploadBytes: Int64
}
```

`UsageAggregator.swift`：

- 新增 `pendingDomains: [DomainKey: DomainUsageAggregate]`，`DomainKey` 为 `(day, appKey, domain, route)`。
- 只在 `delta.route != nil` 且 `delta.domain` 非空时累加，合并写法照 `merge(_:with:key:)`（156 行）。
- **容量满时的处理与路径不同**：`pendingDomains` 达到 `maxPendingEntries` 且键是新的，就跳过这条域名记录，不抛错。路径那一段在容量满时抛 `pendingLimitExceeded`（84 行），整条样本丢失；域名只是附加标签，不能因为它丢掉总量。跳过的字节在界面上落进「未识别域名」。
- `flush()` 把 `Array(pendingDomains.values)` 传给 `store.apply`，成功后与另外两个 pending 一起清空；`discardPending()`（62 行）也要清。

不带 `program_key`：域名 × 程序的组合会让行数成倍增加。**用户可以改**。

测试加在 `UsageAggregatorTests.swift`：带域名的样本进入域名聚合且总量不变；`route == nil`（代理传输）或域名为空时不产生域名聚合；域名容量满时样本总量照常入队。

### 4.8 存储

追加一个迁移分支，写法照版本 8 的分支（`UsageStore.swift:1184`）：

```sql
CREATE TABLE IF NOT EXISTS daily_domain_usage (
    accounting_version INTEGER NOT NULL CHECK (accounting_version > 0),
    day TEXT NOT NULL,
    app_key TEXT NOT NULL,
    domain TEXT NOT NULL,
    route TEXT NOT NULL,
    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
    updated_at TEXT NOT NULL,
    PRIMARY KEY (accounting_version, day, app_key, domain, route),
    FOREIGN KEY (app_key) REFERENCES apps(app_key)
);
```

- 写入：`UsageStore.apply`（112 行）增加参数 `domainAggregates: [DomainUsageAggregate] = []`，在同一个事务里 upsert，语句与 `prepareRouteUsageUpsert`（2201 行）同构（`ON CONFLICT … DO UPDATE SET x = x + excluded.x`）。`apps` 的 upsert 排在前面（157 行），外键成立。域名聚合总是伴随日汇总出现，`apply` 开头的空检查（117 行）不用改。
- `clearAll()`（971 行）在 `DELETE FROM apps` 之前加 `DELETE FROM daily_domain_usage;`。
- 用 `grep -n 'DELETE FROM apps\|deleteAppRows' Sources/ByteTraceCore/Storage/UsageStore.swift` 确认：除 `clearAll` 外，删除 `apps` 行的代码都在旧版本的迁移分支里，执行时新表还不存在。若有例外，那里也要先删新表的对应行，否则外键报错。
- **默认长期保留，不参与保留策略，用户可以改**。按主域名估算，每天每个应用十几到几十行，一年在几十万行以内。
- 迁移只建一张空表，不搬数据，耗时可忽略。

查询：

```swift
public struct DomainUsageRecord: Equatable, Sendable {
    public let domain: String
    public let route: TrafficRoute
    public let downloadBytes: Int64
    public let uploadBytes: Int64
}
/// 一个应用在一段日期内每个域名每条路径的流量，跨天累加。
public func domainUsage(appKey: String, from startDay: String, through endDay: String) throws -> [DomainUsageRecord]
```

只取当前 `accountingVersion`，`GROUP BY domain, route`，加 `lock`。主键前缀 `(accounting_version, day, app_key)` 能覆盖这个查询，不另建索引。导出另需一个不带 `appKey` 条件、JOIN `apps` 排除代理传输的全量版本。

测试：

- 新文件 `Tests/ByteTraceCoreTests/DomainUsageTests.swift`：跨两天累加；范围外的日期不计；重复 `apply` 是累加；`clearAll` 之后为空。
- **不变量**：同一天同一应用，`daily_domain_usage` 合计 ≤ `daily_usage` 合计；`daily_usage` 的数值与不带域名时完全相同。
- `UsageStoreMigrationTests.swift`：从上一个版本升级后表存在、`user_version` 正确；新库直接到最新版本。

### 4.9 开关与 ViewModel

新增 `UserDefaults` 键 `ByteTrace.recordsDomains`，**默认关闭，用户可以改默认值**。理由：已发布的版本向用户说明过「不读取域名」，升级后不应自动开始记录。写法参照 `readsMihomoConnections`（395 行）。只有 `readsMihomoConnections` 与它同时开启时才记录域名。

`ByteTraceViewModel.swift`：

- `supplementalRoute(for:)`（1399 行）改为返回 `RouteResolution`，调用 `mihomoRouteTracker.resolution(forLocalEndpoint:)`。「代理分流」关闭时返回 `.proxied`。「记录域名」关闭时把结果的 `domain` 置 `nil` 再返回，下游不会见到域名。
- 1296 行的闭包类型随之修改。1312 行外部通道的 `RoutedDelta(delta:route: .direct)` 不用改。
- `ingest(_:route:)`（1528 行）增加 `domain` 参数，1321 行的调用传 `routed.domain`；1261 行的间隙补偿不传。代理传输进程的域名传 `nil`，与 1565 行对 `route` 的处理一致。
- 关闭「记录域名」不删除已有记录。清除走现有的「清空全部数据」。
- 新增 `@Published private(set) var detailDomains: [String: [DomainShare]]`（键为 `appKey`）。在 `beginObservingAppDetail`（586 行）里加载，在该应用详情保持展开期间随范围数据的刷新一起更新，`endObservingAppDetail` 里移除。**实施前先读 586–600 行与 `loadRange`（1934 行）、`loadRangeRoutes`（1988 行）**，沿用它们的日期范围取法与节流方式，不新增定时器，不在每次刷新时加载全部应用的域名。
- `DomainShare` 放在应用层：域名、总字节、各路径字节。同一域名的多条路径合成一行。
- `clearAllData`（889 行）里清空 `detailDomains`。

日期范围：「今天」「本周」「本月」等按日汇总的范围直接用同一组 `startDay` / `endDay`。当前主窗口提供今日、本周、本月、上月和全部五档，域名与应用总量使用相同的日期范围。菜单栏的分钟趋势不展示域名。

### 4.10 界面

`MainWindowView.swift` 的 `AppDetailPanel`：

- 在 `programSection`（852 行）之后、`footnote` 之前加 `domainSection`。标题行「域名」加数量，写法照程序排行的标题（904–914 行）。
- 行用 `DetailRowGroup` / `DetailRow.Item`（1017、1036 行）：`marker` 用 `.symbol("globe")`，`name` 是域名，`note` 写路径，`share` 按应用总量算。
- `note` 文案：字节全部是 `.proxyNode` → `代理`；全部是 `.proxyRuleDirect` → `规则直连`；混合 → `代理 X%`；只有 `.proxied` → `经代理`。
- 排序按总字节降序。前 8 个之外合并为「其他 N 个」，只多出一项时直接列出（与 `programRows` 的 944–956 行同一规则）。
- 末尾一行「未识别域名」= 应用总量 − 域名合计，大于 0 时显示，`marker` 用 `.symbol("questionmark")`。`.help(...)`：`没有匹配到域名的流量：不经过 mihomo 的直连、很快结束的连接、只有 IP 的连接，以及开启记录之前的历史。`
- 该应用在范围内没有任何域名记录时整组不显示。
- 域名行不可点击，不需要焦点处理。域名文字加 `.textSelection(.enabled)` 时确认不出现焦点环。

菜单栏面板不改。

`SettingsView.swift` 的 `proxySection`（82 行）：

- 现有开关的说明（87 行）去掉「不读取域名」，改为：`有经代理流量时每秒读取本机 mihomo 控制器的连接列表，按连接判断走节点还是命中 DIRECT 规则。字节仍以 nettop 为准，不上传数据。`89 行的副标题改为 `读取本机 mihomo 连接列表。`
- 新增开关「记录访问的域名」，说明：`把每个应用访问的主域名和流量保存在本机数据库，用于在应用详情里查看域名排行。只保存域名，不保存完整网址、IP 和端口；导出的文件会包含域名。`
- 「代理分流」关闭时新开关置灰。新开关加 `.focusable(false)`。

### 4.11 导出

`ByteTraceExport.swift` 增加：

```swift
struct DomainUsage: Encodable {
    let appKey: String
    let domain: String
    let downloadBytes: Int64
    let uploadBytes: Int64
    let totalBytes: Int64
    let routeBytes: [String: Int64]
}
```

`ByteTraceExportDocument` 增加 `domainUsage: [DomainUsage]`，`formatVersion` 加 1（`ByteTraceViewModel.swift:936`）。范围用当前所选范围。没有域名记录时导出空数组。

## 5. 探针测量（在建表之前做）

目的：拿到「补充通道的字节里有多少能匹配到域名」的数字，再决定是否继续做存储和界面。这一步只改探针，不动应用和数据库。

`Sources/ByteTraceProbe/main.swift` 新增模式 `--domains`，与 `--duration <秒>` 一起用：

- 两个通道照常采集；按 `--routes` 的方式发现控制器并轮询连接表（536–554 行）。
- 新增参数 `--mihomo-interval <秒>`，默认 2，与应用一致。`--routes` 现有的 1 秒不动。
- 匹配闭包改用 `tracker.resolution(forLocalEndpoint:)`。
- 结束时打印，字节取上下行合计：

  ```
  [domains] supplemental_bytes=… with_domain=… without_domain=… residual_bytes=… residual_with_domain=…
  [domains] coverage=0.xxxx distinct_domains=N
  ```

  `coverage = with_domain / supplemental_bytes`，分母包含残差。
- **不打印域名本身**，只打印数量。用户要看明细时加 `--show-domains`，打印字节最多的 10 个域名。
- 退出码按 REVIEW §8.5 的规则。采集或存储检查失败，或有补充流量却始终读不到连接表时返回 1。没有补充流量时覆盖率显示 `n/a` 并返回 2；只读到部分连接表时也返回 2。成功完成测量返回 0，覆盖率另行判断。

需要用户运行的测量（各 300 秒，期间正常使用浏览器和常用应用）：

```bash
swift run ByteTraceProbe --duration 300 --domains
```

```bash
swift run ByteTraceProbe --duration 300 --domains --mihomo-interval 1
```

**判断标准（建议值，用户决定）**：

- 2 秒间隔下 `coverage ≥ 0.85`：按本文继续。
- 2 秒不到、1 秒达到：把应用的 `mihomoPollInterval` 改为 1 秒后继续，并在 `CLAUDE.md` 记录由此增加的唤醒。
- 1 秒也不到：停下来。候选是改用 mihomo 的 WebSocket 推送，或放宽残差的域名规则，需要另写方案。

2026-11-13 在本机 ClashBar / mihomo 环境连续观察两轮，每轮 300 秒。每轮均有 61 帧外部通道、301 帧补充通道，退出码 0，存储错误 0。

| 轮询间隔 | 补充通道字节 | 已匹配域名字节 | 覆盖率 | 主域名数 | 成功／失败快照 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2 秒 | 27,151,241 | 21,979,490 | 80.95% | 33 | 150／0 |
| 1 秒 | 255,994,795 | 252,303,336 | 98.56% | 38 | 299／0 |

2 秒轮次的残差为 3,523,035 字节，其中 41,582 字节匹配到域名。1 秒轮次分别为 5,290,093 和 2,302,333 字节。两轮观察的是不同的自然流量，覆盖率差值不能单独归因于轮询间隔。按 85% 的方案门槛继续，应用改为 1 秒轮询，域名记录默认关闭。

## 6. 已知局限（实施后写进 `CLAUDE.md`）

- 短于轮询间隔就结束的连接匹配不到域名，记入「未识别域名」。
- mihomo 定时器只在最近 30 秒有补充通道流量时运行，空闲后的第一批连接可能赶不上第一份快照。
- 不经过 mihomo 的流量（外部通道记录的直连）没有域名。
- 只有 IP、mihomo 没有嗅探出主机名的连接没有域名。
- 已关闭连接的残差只在进程窗口内只有一个域名时带域名。
- 域名来自 mihomo 的连接元数据，不是从报文里解析的。
- 多段后缀表不完整（§4.2）。
- 域名按宿主应用记录，不区分宿主里的程序。
- 「记录域名」开启之前的历史没有域名。

## 7. 需用户决定

| 事项 | 默认 | 在哪里 |
| --- | --- | --- |
| 存主域名还是完整主机名 | 主域名 | §4.2 |
| 域名记录是否带 `program_key` | 不带 | §4.7 |
| 域名记录的保留时长 | 长期保留 | §4.8 |
| 「记录域名」开关的默认值 | 关闭 | §4.9 |
| 测量的通过标准 | coverage ≥ 0.85 | §5 |
| 是否紧接着做按节点统计（F1b） | 不做，另行安排 | §3 |

## 8. 文档同步（最后一个任务）

- `CLAUDE.md`：
  - 「mihomo 连接表」一节：连接表缓存仍只在内存保留 120 秒；域名在「记录域名」开启时落库；删掉「不展示域名」。
  - 「存储」一节：表数量、`daily_domain_usage` 的键与口径、`schemaVersion`、它不参与保留策略、`clearAll` 会清空它。
  - 「应用层」：新的 `UserDefaults` 键、展开详情的域名一组、导出版本。
  - 常用命令：`--domains` 探针。
  - §6 的已知局限。
- `docs/NEXT_MAJOR_VERSION_PLAN.md` 第 23 行：把「域名历史」从「暂不纳入」里移走，保留「全量连接」。
- `docs/FEATURE_PLAN_2026-11.md` §2.3：注明 `RouteResolution` 已由本文实现并含 `domain` 字段，F1b 只需补表与界面。
- 发版时的更新说明要写明：新增可选的域名记录，默认关闭，数据只保存在本机。

## 9. 任务清单

每个任务单独做、单独提交，做完一个停下来给用户看 diff。D1 → D6 按顺序做，后一个依赖前一个。

| 任务 | 依据 | 允许改动的文件 | 完成标准 |
| --- | --- | --- | --- |
| D1 mihomo 缓存修正 | REVIEW §8.6（即 T4；已完成则跳过） | `MihomoConnections.swift`、`ByteTraceViewModel.swift` 的 mihomo 一段、`MihomoTests.swift` | REVIEW §8.6 的四个测试；`swift build` 通过 |
| D2 域名随连接传递 | §4.1–§4.6 | `TrafficRoute.swift`、新增 `Mihomo/DomainName.swift`、`MihomoConnections.swift`、`TrafficFilter.swift`、`SupplementalResidualTracker.swift`；测试 `DomainNameTests.swift`（新增）、`MihomoTests.swift`、`RouteUsageTests.swift`、`SupplementalResidualTrackerTests.swift`、`TrafficFilterTests.swift`；为保持编译而改的调用点：`ByteTraceViewModel.swift:1296`、`1399`，`Sources/ByteTraceProbe/main.swift:420` | 先按 §4.3 确认 mihomo 字段名；§4.2、§4.4、§4.5、§4.6 的测试；应用行为不变（ViewModel 这一步丢弃域名）；`swift build` 通过 |
| D3 探针测量 | §5 | `Sources/ByteTraceProbe/main.swift`、本文 §5 | 两轮测量结果已写回 §5；1 秒轮次达到方案门槛 |
| D4 聚合与存储 | §4.7、§4.8 | `UsageModels.swift`、`UsageAggregator.swift`、`UsageStore.swift`；测试 `UsageAggregatorTests.swift`、`DomainUsageTests.swift`（新增）、`UsageStoreMigrationTests.swift` | §4.7、§4.8 的测试与不变量；迁移测试；`swift build` 通过。此时还没有任何代码往新表写数据 |
| D5 开关、界面与导出 | §4.9–§4.11 | `ByteTraceViewModel.swift`、`MainWindowView.swift`、`SettingsView.swift`、`ByteTraceExport.swift`；缓存与残差历史在关闭记录时清除域名标签 | 应用编译通过。界面待人工验证：开关默认关闭且升级后不记录；开启后展开应用能看到域名；关闭「代理分流」时开关置灰；五个日期范围的显示与导出；打开设置页没有控件被自动选中 |
| D6 文档 | §8 | `CLAUDE.md`、`docs/NEXT_MAJOR_VERSION_PLAN.md`、`docs/FEATURE_PLAN_2026-11.md`、本文状态行 | 与实际实现一致 |

D5 完成后交用户核对真实数据。运行一段时间后执行下面的命令，与 mihomo 面板里同一应用的域名用量对照量级：

```bash
sqlite3 ~/Library/Application\ Support/com.nanvon.ByteTrace/usage.sqlite3 "SELECT app_key, domain, SUM(download_bytes + upload_bytes) AS bytes FROM daily_domain_usage WHERE day = date('now','localtime') GROUP BY 1, 2 ORDER BY bytes DESC LIMIT 20;"
```

未经用户要求，执行者只运行 `swift build` 做编译检查；`swift test` 与探针测量都要先说明再运行。
