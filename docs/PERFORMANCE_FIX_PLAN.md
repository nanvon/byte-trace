# ByteTrace 性能修复执行方案

状态：**已执行**（v0.1.7 落地全部任务，v0.1.8 修复两处收尾缺陷）。执行记录见第九节，遗留事项与验收结论以第九节为准。

日期：2026-08-03
基线版本：`d4b96f2`（ByteTrace 0.1.5）
测量环境：macOS 15（Darwin 25.6.0），341 条 ESTABLISHED 连接，ClashBar / mihomo 混合代理（系统代理 + TUN）

---

## 0. 执行须知（执行者必读）

1. **本文结论优先级高于 `PERFORMANCE_REVIEW.md` 与 `ENERGY_AND_PERFORMANCE.md`**。那两份文档的部分结论已被实测推翻，见第三节。遇到冲突以本文为准。
2. 本文所有行号基于基线版本。**定位代码时用 `grep` 搜关键字，不要死认行号。**
3. 任务 T0 → T4 按编号递减优先级排列，**彼此独立，可分批提交**。不要为了做 T3 而跳过 T0。
4. 第四节「硬约束」是禁止事项，**违反会直接破坏产品核心能力**，任何情况下不得触碰。
5. 每个任务都给了验收命令，**改完必须验收**，不要凭代码看起来对就认为完成。

### 产品需求边界（决定了什么可以牺牲）

真实使用场景：**用户全天开启 ClashBar 代理，系统代理与 TUN 混用**。

- **必须保住**：各应用的流量排行；代理进程（mihomo/ClashBar/CCBar）与普通应用分开计账。
- **可以牺牲**：数据实时性（不需要秒级刷新）、连接级主机名明细、分钟级精度。

换言之：**正式应用级管线是产品的全部价值，连接级主机名管线是可选实验功能。** 涉及取舍时，永远优先保应用级管线。

---

## 1. 根因：`nettop` 的 stdin 被设成 `/dev/null`，导致进程空转

这是本项目能耗问题的**唯一主要来源**，占总开销约 98%。

### 现状代码（两处，完全相同）

`Sources/ByteTraceCore/NettopCollector.swift:86-88`
`Sources/ByteTraceCore/NettopConnectionCollector.swift:67-69`

```swift
if let nullInput = FileHandle(forReadingAtPath: "/dev/null") {
    process.standardInput = nullInput
}
```

### 机理

`nettop` 是 curses 交互程序，运行期会 poll stdin 等待按键（`q` 退出、`d` 切换 delta、`x` 切换单位等）。`/dev/null` 的语义是**永远立即可读并返回 EOF**，于是这个 poll 每次都立刻就绪，退化成一个不休眠的死循环。子进程因此恒定占满一个多核心，与它实际要做的采样工作无关。

### 实测证据

参数恒定为生产参数 `-n -P -d -x -L 0 -s 1`，只改变 stdin / stdout：

| stdin | stdout | CPU 均值 |
| --- | --- | ---: |
| `/dev/null` | pipe **（当前实现）** | **124.0%** |
| `/dev/null` | file | 127.5% |
| 空 pipe（永不就绪） | file | **1.3%** |
| 空 pipe（永不就绪） | pipe **（修复后）** | **0.8%** |

结论：**与 stdout 无关，与全部 nettop 参数无关，只由 stdin 决定。** 修复后单进程 CPU 下降约 155 倍。

数据完整性已验证：修复前后同样时长内**帧数一致**（12 帧 vs 12 帧），进程数 53 个齐全，delta 增量语义正常。**省下的 CPU 没有以丢数据为代价。**

---

## 2. 各参数组合实测（用于否决无效方案）

同为 `-L 0` 长跑、stdin=`/dev/null`：

| 参数组合 | CPU 均值 |
| --- | ---: |
| 应用级 `-n -P -d -x -L 0 -s 1` | 131.3% |
| 应用级 `-n -P -d -x -L 0 -s 5` | **131.9%** |
| 连接级 `-d -x -L 0 -s 1` | 110.3% |
| 连接级 `-n -d -x -L 0 -s 1` | **131.3%** |
| 应用级 `-L 3600`（有限样本） | 124.0% |
| 应用级 `-l 0`（raw 而非 CSV） | 126.0% |
| 应用级 `-L 0 -s 1 -c`（省 CPU 开关） | 128.2% |

**所有组合均在 110%–132% 区间，无一有效。** 采样间隔、日志模式、`-c` 开关、`-n` 开关全部无法改善——因为它们都不是根因。

---

## 3. 已被实测推翻的旧结论（执行者不要照做）

| 出处 | 旧结论 | 实测 | 判定 |
| --- | --- | --- | --- |
| `ENERGY_AND_PERFORMANCE.md` 优化方向 2 | `-s 1` → `-s 5` 降频省电 | `-s 5` = 131.9%，与 `-s 1` 的 131.3% 无差异 | **零收益**（修复 T0 前） |
| `ENERGY_AND_PERFORMANCE.md` 优化方向 1 | 连接级降频到 `-s 5` 可砍一半能耗 | 同上，降频无效 | 结论错，但**关闭**它仍有效 |
| `PERFORMANCE_REVIEW.md` H2 | 连接级缺 `-n` 带来高开销 | 加 `-n` 后升到 131.3%，比不加的 110.3% 更高 | 判断有误。缺 `-n` 的代价是**出帧延迟**（6 样本耗时 13.49s，应为 6s），不是 CPU |
| `PERFORMANCE_REVIEW.md` H1 | 合并两条管线「收益最大」 | 修复 T0 后单进程仅约 1% | **不值得做**，纯风险无收益 |
| `PERFORMANCE_REVIEW.md` S2/S3/H3/H4 等 | 列为 P0/P1 | 优化对象是主进程的 1.7%–4.7% | 有效但**收益占总量 < 2%**，降级为 T4 |

`PERFORMANCE_REVIEW.md` 的静态代码分析质量很高，缺陷描述本身准确可信；问题在于它**没有实测**，把 98% 的开销归错了地方。其条目在 T4 中仍然可用，只是优先级需重排。

---

## 4. 硬约束（禁止事项）

### 🚫 禁止给 nettop 添加 `-t external`（或任何接口过滤）

实测在本用户的真实代理环境下：

| 配置 | 可见进程数 |
| --- | ---: |
| 当前（不过滤接口） | 40+（Dia、Telegram、Chrome、Discord、WeChat、DingTalk…） |
| 加 `-t external` | **9**（只剩 mihomo 等） |

原因是混合代理模式下应用流量的实际路径：

```
Dia / Chrome / Discord   →  tcp4 127.0.0.1:x <-> localhost:7890   接口 lo0    （系统代理）
Telegram                 →  tcp4 198.18.0.1:x <-> 1.2.3.4:443     接口 utun4  （TUN + fake-ip）
mihomo                   →  lo0 收代理连接  +  en0 真实出网
```

`-t external` 会排除 lo0，**所有走系统代理的应用会整体消失**。loopback 流量恰恰是本产品最需要的数据。同理不得使用 `-m tcp`（会丢 QUIC/UDP）。

### 🚫 禁止改动 `appKey` 派生规则

`appKey` 是 SQLite 主键，改动会切断历史数据连续性，老数据变孤儿行。详见 `CLAUDE.md`。

### 🚫 禁止让连接级数据回写应用级总量

两条管线永不互相修正、抵扣或补全。这是 `DOMAIN_TRAFFIC_SOURCE_DECISION.md` 的最终决策。

### 🚫 禁止移除代理进程的独立计账

`ProxyClassifier.defaultClassifier` 已覆盖 `mihomo` / `ClashBar` / `CCBar`（`Sources/ByteTraceCore/Attribution/ProxyClassifier.swift:56-58`），与本用户环境匹配。代理流量单独展示、不反向抵扣、不计入应用总量；UI 各处统一用 `category != .proxyTransport` 过滤。

---

## 5. 任务清单

### T0 · 修复 nettop 空转（最高优先级，收益 98%）

**收益**：两个子进程合计 262% → 约 2% CPU。电池与风扇问题基本消失。
**改动量**：两个文件，各约 5 行。
**风险**：极低。

#### 修改点

两处相同改法：`NettopCollector.swift` 与 `NettopConnectionCollector.swift`。

将 `/dev/null` 替换为一个**永不写入、且父进程持续持有**的 `Pipe`：

```swift
// 删除：
// if let nullInput = FileHandle(forReadingAtPath: "/dev/null") {
//     process.standardInput = nullInput
// }

// 改为：
let stdinPipe = Pipe()
process.standardInput = stdinPipe
```

并在类中增加属性保存强引用（与现有 `process` / `readGroup` 同一把 `stateLock` 保护）：

```swift
private var stdinPipe: Pipe?
```

在 `start()` 中与 `self.process` 一同赋值，在 `stop()` 中与之一同置 `nil`。

#### ⚠️ 关键实现要点（做错会完全失效）

- **必须持有 `Pipe` 的强引用。** 若 `Pipe` 被 ARC 回收，其写端关闭，子进程 stdin 立刻变为 EOF，退回空转状态，CPU 重新涨到 130%。
- **父进程不得向该 pipe 写入任何数据，也不得主动关闭写端。** 目的就是让 stdin 永远不就绪。
- 不要用 `FileHandle.nullDevice`、不要用 `/dev/zero`（永远可读，同样空转）、不要不设 `standardInput`（会继承父进程 stdin，行为不确定）。
- 进程终止路径不受影响：现有 `terminate()` 用 SIGTERM + SIGKILL，已验证可正常退出。

#### 验收（必做）

```bash
swift build && swift run ByteTraceApp
```

另开终端观察，两个 nettop 均应低于 **5%**：

```bash
ps -Ao pid,pcpu,args | grep "[n]ettop"
```

再确认数据仍在写入（帧数正常增长、UI 有数据）。若任一 nettop 仍在 100% 以上，说明 Pipe 强引用没持住，回头检查。

---

### T1 · 连接级管线改为默认关闭

**收益**：再省约 1% CPU；解析量降 8 倍（实测连接级 2083 行/帧 vs 应用级 272 行/帧）；消除增长最快的 `host_usage_buckets` 表；消除 DNS 反解触发的出站查询与观测回环。
**代价**：默认看不到主机名排行——**该功能不在用户需求内**，且本身覆盖率远低于 100%。
**风险**：低。

#### 方向

1. 新增设置项 `ByteTrace.enableConnectionCollector`，**默认 `false`**。
   仿照 `showsSystemProcesses` 的写法（`ByteTraceViewModel.swift:157-164`）：`@Published var` + `didSet` 写 `UserDefaults`，键名常量放在 `:179-180` 旁边。
2. `startCollectorProcess()`（`:886`）中对 `startConnectionCollector()` 的调用加开关判断；`startConnectionCollector()`（`:905`）的 `guard` 也加上该条件，双保险。
3. 开关从开→关时调用 `stopConnectionCollector()`；从关→开时调用 `startConnectionCollector()`。
4. `SettingsView.swift` 的「可见主机名实验」Section（`:116`）加一个 Toggle，文案需说明**开启会显著增加 CPU 与耗电**。
5. 关闭状态下 `HostUsageView` 显示「未启用」的空态，不要显示为「无数据」——两者含义不同。

#### 注意

- `hostAggregator` 的初始化（`:232`）保持不变，关闭时它只是不再收到数据。
- 已有的 `host_usage_buckets` 历史数据不要自动删除，用户可在设置页手动清空（现有按钮）。
- 睡眠/唤醒、网络切换的重连路径中也要尊重这个开关，不要绕过它把连接级拉起来。

#### 验收

```bash
swift build && swift run ByteTraceApp
ps -Ao pid,pcpu,args | grep "[n]ettop" | wc -l    # 默认应为 1
```

在设置页打开开关后应变为 2，关闭后回到 1，且应用级采集全程不中断。

---

### T2 · 应用级采样间隔 `-s 1` → `-s 5`

**收益**：App 主进程侧的解析、进程归属、定时器唤醒频率降 5 倍。这是修复 T0 之后**剩余开销的主要来源**，对电池续航有实际帮助（减少 CPU 唤醒次数比降低瞬时占用更省电）。
**代价**：采集器重启时基线帧丢失窗口从 1 秒扩大到 5 秒。落库本就是分钟粒度，**用户已明确不需要秒级实时性**。
**风险**：低，但需同步改测试与文档。

#### 方向

1. `NettopCollector.arguments`（`NettopCollector.swift:35`）中 `"-s", "1"` 改为 `"-s", "5"`。
2. 同步更新 `Tests/ByteTraceCoreTests/` 中断言参数数组的用例。已知 `NettopConnectionCollectorTests.swift:8-12` 断言了连接级参数；**用 grep 确认应用级是否也有同类断言**，一并更新。
3. 同步更新 `CLAUDE.md`「架构：两条互不干扰的采集管线」表格中记录的 nettop 参数。
4. 连接级参数**不要动**（它默认已关闭；若用户手动开启，`-s 1` 与 `-s 5` 的 CPU 实测无差异，改了没有收益）。

#### 注意

- 分钟桶按时间戳落桶，采样间隔变化不影响分桶逻辑，无需迁移。
- `-d` 是增量模式，5 秒一帧即 5 秒的增量，总量口径不变。
- 若同时做 T3，UI 刷新周期不应短于采样间隔。

#### 验收

```bash
swift test
swift run ByteTraceProbe --duration 30
```

确认帧间隔约 5 秒、字节总量与 `-s 1` 时同量级（探针用 `:memory:` 库，不污染正式数据）。

---

### T3 · 数据库无限增长治理

**收益**：内存与磁盘占用可控。
**风险**：中，涉及默认值变更与删除操作。

#### 方向

1. **保留策略默认值**：`ByteTraceViewModel.swift:224` 当前 `?? .never`，改为一个有限默认（建议 90 天）。
   ⚠️ 仅对**新用户**生效——已有用户的 `UserDefaults` 已写入旧值。不要强制覆盖用户已有设置。
2. **`collector_events` 表无保留策略**（`purgeBuckets` 只清 2 张 bucket 表）。加行数上限或按天清理。
3. **无 `VACUUM`**：WAL 下 DELETE 后文件不收缩。可在清理后按需执行一次，注意它是阻塞操作，**不要放在主线程**。
4. **`ProcessAttributionCache` 永不淘汰**（`ProcessAttributor.swift:209`，`removeAll()` 从未被调用）：加 LRU 上限（建议 2000 条）。key 含 `processStartTime`，每个短命进程都会留下永久条目。

#### 注意

- `purgeBuckets` 首次启用时可能删除数百万行，当前在主线程同步执行（`:1002`）。若改默认值，务必同时把首次大批量删除移出主线程，或分批删除。
- `daily_usage` 与 `apps` 表不参与清理，这是既有设计，不要改。

#### 验收

```bash
DB=~/Library/Application\ Support/com.nanvon.ByteTrace/usage.sqlite3
sqlite3 "$DB" "SELECT 'usage',COUNT(*) FROM usage_buckets UNION ALL SELECT 'host',COUNT(*) FROM host_usage_buckets UNION ALL SELECT 'events',COUNT(*) FROM collector_events;"
ls -lh "$DB"*
```

---

### T4 · 主进程侧优化（收尾，收益 < 2%）

做完 T0–T3 后主进程才成为相对大头。以下条目**全部来自 `PERFORMANCE_REVIEW.md`，缺陷描述准确可信**，按新的优先级重排：

| 顺序 | 事项 | 原编号 | 位置 |
| --- | --- | --- | --- |
| 1 | `bucketStats()` 每 5 秒全表 `COUNT(*)` → 移出周期，改设置页按需查询 | H3 / P1-1 | `UsageStore.swift:263-285` |
| 2 | 写入与 UI 刷新解耦：`flushNow()` 不再无条件 `refresh()`，落库保持原节奏、UI 降频或仅主窗口可见时刷新 | H4 / P1-9 | `ByteTraceViewModel.swift:344-365, 979-992` |
| 3 | `NettopHostUsageAggregator` 由 struct 改 `final class`，消除 CoW 深拷贝 | S1 / P1-2 | `NettopHostUsage.swift:88` |
| 4 | `SystemProcessIdentityResolver.resolve()` 加 pid→identity 缓存 | S2 / P0-1 | `ProcessIdentity.swift:101-144` |
| 5 | `ByteCountFormatter` / `DateFormatter` 改 `static let`；图标结果加缓存 | M5/M6/M7 | `ByteTraceViewModel.swift:552-558` 等 |
| 6 | 移除 4 处嵌套 `RunLoop.main.run(until:)`，`collector.stop()` 改异步 | H5 / P1-4 | `ByteTraceViewModel.swift:313,691,866,928` |
| 7 | 加 `PRAGMA synchronous = NORMAL` | M3 / P1-5 | `SQLiteDatabase.swift:57-59` |

其中第 3、4 项在 T1（关闭连接级）+ T2（降频 5 倍）之后，调用频率已大幅下降，紧迫性显著降低。第 6 项改动面较大，收益是消除卡顿而非省电，可最后做。

**不要做** `PERFORMANCE_REVIEW.md` 的 H1（合并两条管线）——见第三节。

---

## 6. 复现测量的方法

任何性能改动前后都应跑一次对照。以下脚本可直接使用：

```bash
#!/bin/bash
# 测量单个 nettop 进程的真实 CPU 占用
probe() {
  label="$1"; shift
  /usr/bin/nettop "$@" 2>/dev/null | cat > /dev/null &
  sleep 1
  pid=$(pgrep -n nettop)
  samples=""
  for i in 1 2 3 4 5; do
    sleep 2
    c=$(ps -o pcpu= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$c" ] && break
    samples="$samples $c"
  done
  kill "$pid" 2>/dev/null; wait 2>/dev/null
  avg=$(echo $samples | tr ' ' '\n' | awk '{s+=$1;n++} END{if(n>0) printf "%.1f", s/n}')
  printf "%-30s 均值=%s%%\n" "$label" "$avg"
}
probe "应用级(当前生产参数)" -n -P -d -x -L 0 -s 1
```

### 测量陷阱（务必注意）

1. **短样本测不出问题。** `-L 6` 这类有限小样本跑完即退，测得约 3%，会掩盖空转。**必须长跑至少 20 秒并周期采样。**
2. **stdin 决定一切。** 在 shell 中前台运行 nettop 时 stdin 是终端，不会空转；后台运行或重定向自 `/dev/null` 才会。测量时务必复现 App 的实际 stdin 环境。
3. `/usr/bin/time -p cmd > out 2>/dev/null` 会把 `time` 自己的输出一起丢弃，需用 `sh -c` 隔离内层重定向。
4. 活动监视器的「12 小时电源」是累计值，ByteTrace 全天运行而多数应用只在使用时耗电，直接横向对比会放大差距。判断优化效果应看**进程级瞬时 CPU**。

---

## 7. 预期效果

| 阶段 | 两个 nettop | 主进程 | 说明 |
| --- | ---: | ---: | --- |
| 当前 | 约 262% | 1.7%–4.7% | 活动监视器 12 小时电源 1911，为第二名的 6 倍 |
| T0 后 | 约 2% | 1.7%–4.7% | 能耗问题基本解决 |
| T0+T1 后 | 约 1% | 约 1%–3% | 单管线，解析量降 8 倍 |
| T0+T1+T2 后 | 约 1% | < 1% | 唤醒频率降 5 倍，续航明显改善 |
| 再加 T3+T4 | 约 1% | < 0.5% | 长期驻留稳定 |

核心结论：**T0 一项就拿下约 98% 的收益，其余都是收尾。** 先做 T0 并实测确认，再决定后续投入。

---

## 9. 执行记录（2026-08）

### 落地版本

| 任务 | 落地 | 说明 |
| --- | --- | --- |
| T0 | v0.1.7 `b4d72d2` | 两采集器 stdin 改父进程持有的空 Pipe，`stdinPipe` 与 `process` 同生命周期（stateLock 保护） |
| T1 | v0.1.7 `b4d72d2` | 设置项 `ByteTrace.enableConnectionCollector` 默认 `false`；启停双保险；重连路径尊重开关；HostUsageView「未启用」空态 |
| T2 | v0.1.7 `b4d72d2` | 应用级 `-s 1` → `-s 5`；连接级保持 `-s 1`；CLAUDE.md 表格同步 |
| T3 | v0.1.7 `b4d72d2` | 保留策略默认 90 天（仅新用户）；`purgeCollectorEvents` 按 30 天清理；删除 > 10000 行后后台 `VACUUM`；`ProcessAttributionCache` LRU 上限 2000 |
| T4 | v0.1.7 `b4d72d2` + v0.1.8 | 7 项全部落地（详见下文缺陷修复） |

### 验收结论

- `swift build` ✅，`swift test` 43/43 ✅（v0.1.7 与 v0.1.8 均通过）。
- 未执行文档要求的实机 CPU 对照（`ps` 观察 nettop < 5%、活动监视器 12 小时电源复核）——建议发布后观察一两天确认能耗回落。

### v0.1.8 收尾缺陷修复

上版执行后复查发现两处问题，已修复：

1. **停止/退出路径最后一帧可能丢失**：`emitParserEvent` 经 `DispatchQueue.main.async` 投递，删除嵌套 RunLoop 后 `flushNow()` 会先于最后一帧事件执行。修复：非退出路径（手动停止/网络切换/睡眠）改用 `flushAfterStop()`（同样入主队列、排在事件之后）；退出路径 `shutdown()` 保留一次 `RunLoop.main.run(until: +0.05s)` 同步排空再落库。
2. **`NettopHostUsageAggregator.flush` 快照/清空非原子**：原实现「锁内取快照 → 锁外写库 → 锁内清空」，写库期间新 ingest 的样本可能被连带清掉。修复：锁内完成「取快照 + removeAll」（提取 `lockedSortedRecords()`），锁外写库，与 `UsageAggregator.flush()` 风格一致。

### 按文档要求未做的事

- **H1（合并两条采集管线）**：文档第三节实测结论已否决，未做。
- **硬约束全部未触碰**：无 `-t external`、无 `-m tcp`、未改 `appKey` 派生规则、连接级未回写应用级、代理进程独立计账保留。

### 遗留事项

- 连接级主机名排行默认关闭，需在设置页手动开启（文档 T1 的预期取舍）。
- 保留策略默认 90 天仅对新用户生效，存量用户 `UserDefaults` 已有旧值不强制覆盖（文档 T3 注意项）。
- 基线帧间隙（每次 nettop 重启约 5 秒）流量丢失为已知取舍，非本次引入。

---

## 相关文档

- `PERFORMANCE_REVIEW.md` — 静态代码审查，缺陷描述准确，但**优先级排序已被本文推翻**
- `ENERGY_AND_PERFORMANCE.md` — 能耗现象记录，**优化方向 1、2 已被本文实测推翻**
- `../DOMAIN_TRAFFIC_SOURCE_DECISION.md` — 连接级管线的存在理由与能力边界
- `../CLAUDE.md` — 架构约束与代码风格
