# ByteTrace

常驻 macOS 菜单栏的应用级流量统计工具。看清每个应用用掉了多少流量、在什么时间段用掉的。

[![Release](https://img.shields.io/github/v/release/nanvon/byte-trace?style=flat-square&color=0b7285)](https://github.com/nanvon/byte-trace/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/nanvon/byte-trace/ci.yml?style=flat-square&label=CI)](https://github.com/nanvon/byte-trace/actions/workflows/ci.yml)
![platform](https://img.shields.io/badge/macOS-14.0%2B-black?style=flat-square)
![swift](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square)
![arch](https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-lightgrey?style=flat-square)
[![License](https://img.shields.io/badge/license-MIT-555?style=flat-square)](LICENSE)

> 早期版本（0.1.x）。应用级流量统计已稳定可用；「可见主机名」是标注清楚的实验能力，覆盖率天然不完整。发布产物使用 ad-hoc 签名，未经过 Apple 公证。

## ByteTrace 解决什么问题

macOS 自带的活动监视器只给出「当前速率」和「自本次开机以来」的累计值，退出即清零，也无法回溯。于是这类问题始终没有答案：

- 这个月的流量到底被哪个应用吃掉了？
- 刚才那波突发上传是谁发起的？
- 某个应用是不是在后台一直悄悄传数据？

ByteTrace 常驻菜单栏，持续读取系统自带的 `/usr/bin/nettop`，把每个应用的上传与下载字节数写入本机 SQLite，因此可以按时间范围回看历史，而不是只看一眼实时速率。

数据全部留在本机，不上传任何网络内容，也不解析你的通信内容。

<!-- 截图占位：请补充以下三张图后删除本注释。
     建议放在 docs/images/ 下，宽度 1200px 左右，浅色模式即可。
     1. menubar-panel.png  菜单栏面板展开态（今日汇总 + 应用排行 + 代理运输分组）
     2. main-window.png    主窗口概览（时间范围切换 + 趋势折线图 + 应用排行）
     3. host-usage.png     可见主机名排行（含覆盖率指示）
-->

|                    菜单栏面板                     |                     主窗口概览                     |
| :-----------------------------------------------: | :------------------------------------------------: |
| _待补充 `docs/images/menubar-panel.png`_ | _待补充 `docs/images/main-window.png`_ |

## 功能

### 菜单栏速览

点击菜单栏图标即可展开面板：

- 今日总量、下载、上传三项汇总
- 按流量排序的应用列表，带真实应用图标
- **代理运输流量**独立折叠分组：`mihomo`、`ClashBar`、`CCBar` 会被单独识别，不混入应用总量
- **系统与后台进程**独立折叠分组，可在设置中隐藏
- 采集状态实时提示，覆盖「正在启动采集 / 正在建立统计基线 / 正在统计 / 正在重连 / 系统格式不兼容 / 采集不可用 / 统计已停止」七种状态，每种都带一句说明，可随时开始或停止
- 一键进入主窗口、设置与刷新

### 主窗口概览

- 五档时间范围：**最近 10 分钟 · 最近 1 小时 · 今天 · 本周 · 本月**
- 所选范围的总量 / 下载 / 上传汇总卡片
- 流量趋势折线图（最近 10 分钟、最近 1 小时与今天使用分钟级粒度）
- 应用流量排行，点击任一应用进入详情

### 应用详情

- 该应用在当前时间范围内的总量、下载、上传
- 该应用的独立流量趋势柱状图
- 该应用可观察到的主机名列表与识别覆盖率

### 可见主机名（实验能力）

在连接级采集中，`nettop` 对**部分**连接会直接暴露主机名。ByteTrace 把这部分数据单独存放，用于回答「大致访问了哪些站点」：

- 全局主机名流量排行，含每个主机名的连接数
- 覆盖率指示：可识别字节占正式应用总量的比例
- IP-only、名称缺失或无法归属的流量**不展示原始 IP**，统一计入「无法识别 / 其他」

该能力全程标注为「实验数据 · 部分可见」，独立存储、独立清理，**不会修改也不会污染正式的应用级统计**。

### 本地数据管理

- 显示数据库路径，一键在 Finder 中定位
- 导出当前时间范围为 JSON（正式应用汇总与主机名实验数据分块保存）
- 分钟级数据保留策略：永不自动清理 / 7 天 / 30 天 / 90 天
- 查看已积累的分钟桶数量与最早、最新记录时间
- 正式统计（设置 → 本地存储）与主机名实验数据（设置 → 可见主机名实验）可分别清空
- 「设置 → 采集」还提供「显示系统与后台进程」与「登录时启动」两个开关

### 稳定性

- `nettop` 意外退出时按 1 / 2 / 5 / 10 / 30 秒退避自动重连
- 网络路径切换时安全停止并落盘，恢复后重新建立基线
- 睡眠前落盘，唤醒后重建基线
- 退出时只回收自己创建的 `nettop` 子进程

## 系统要求

- macOS 14.0 或更高版本
- Apple Silicon 或 Intel
- 无需安装系统扩展、内核扩展，也无需 root 权限

## 安装

### 下载发行版

前往 [Releases](https://github.com/nanvon/byte-trace/releases/latest) 下载对应架构的产物：

| 你的 Mac | 下载文件 |
| --- | --- |
| Apple Silicon（M 系列芯片） | `ByteTrace_<版本>_macOS-Apple-Silicon.dmg` |
| Intel | `ByteTrace_<版本>_macOS-Intel.dmg` |

不确定自己是哪种：点击左上角  → 「关于本机」，看「芯片」一行。

打开 DMG 后把 ByteTrace 拖入「应用程序」即可。`.zip` 与 `.dmg` 内容相同，只是免挂载，按喜好选一个。

每个产物都附带同名 `.sha256` 文件，另有一份汇总的 `SHA256SUMS.txt`。想校验完整性：

```bash
shasum -a 256 -c ByteTrace_<版本>_macOS-Apple-Silicon.dmg.sha256
```

> **首次打开会被系统拦截。** ByteTrace 使用 ad-hoc 签名，未经过 Apple 公证，这是预期行为。请在「系统设置 → 隐私与安全性」页面下方找到被阻止的提示，点击「仍要打开」。

### 从源码构建

需要 macOS 14 或更高版本，以及包含 Swift 6 工具链的 Xcode（打包脚本还会用到系统自带的 `codesign`、`hdiutil`、`plutil`、`ditto`）。

```bash
git clone https://github.com/nanvon/byte-trace.git
cd byte-trace
./Scripts/package_app.sh
```

产物位于 `dist/`，包含 `ByteTrace.app`、`ByteTrace.dmg` 与 `ByteTrace.zip`，默认使用 ad-hoc 签名。

## 快速开始

1. 启动 ByteTrace，菜单栏出现 ⇅ 图标（应用不在 Dock 中显示）
2. 点击图标展开面板，采集会自动开始
3. 首帧仅用于建立基线，不计入流量；应用流量每约 5 秒写入一次数据库，等几秒就能看到第一批数据
4. 点击面板右上角的窗口图标进入主窗口，切换时间范围查看趋势与排行

## 使用说明

### 时间范围如何取数

| 范围 | 数据来源 | 趋势粒度 |
| --- | --- | --- |
| 最近 10 分钟 | 分钟级时间桶 | 分钟级 |
| 最近 1 小时 | 分钟级时间桶 | 分钟级 |
| 今天 | 日汇总 | 分钟级 |
| 本周 | 日汇总 | 日级 |
| 本月 | 日汇总 | 日级 |

时间口径跟随系统当前时区与本地日历。分钟级趋势从安装后开始积累，历史日汇总不会被反向摊分成虚构的分钟数据。

### 代理流量为什么单独算

启用代理时，应用的流量会经由代理进程转发，两侧都会被 `nettop` 观察到。若直接相加会重复计算，因此 ByteTrace 把已知的代理进程归入「代理运输」单独展示，**不做反向抵扣**，也不计入今日应用总量。

当前内置识别 `mihomo`、`ClashBar`、`CCBar` 三个进程名，**规则硬编码在代码里，暂不支持自定义**。如果你用的是 Surge、sing-box、Proxyman 等其他代理，它们的转发流量会被当作普通应用计入总量，与被代理应用重复计算。需要支持更多代理请提 issue 并附上进程名。

### 导出数据

在「设置 → 本地存储 → 导出当前范围 JSON」中导出，结构包含：

```
formatVersion / product / exportedAt / range
applicationUsage[]        应用级汇总（含分类、Bundle ID、路径、上下行字节、样本数）
hostnameExperiment
  ├─ coverage             可见字节、无法识别字节、覆盖率
  └─ rows[]               主机名明细
```

## 数据与隐私

- 唯一数据源是系统自带的只读命令 `/usr/bin/nettop`
- 所有数据保存在本机：`~/Library/Application Support/com.nanvon.ByteTrace/usage.sqlite3`
- 不上传、不联网回传任何统计结果
- 不解析报文内容，不解密 HTTPS，不读取请求体

数据库为标准 SQLite（启用 WAL），包含 `apps`、`daily_usage`、`usage_buckets`、`host_usage_buckets`、`collector_events` 五张表，你可以用任意 SQLite 客户端自行查询。

## 统计口径与边界

诚实地说明 ByteTrace **不做什么**，比夸大能力更重要：

| 能做 | 不做 |
| --- | --- |
| 按应用统计上传 / 下载 / 总量 | 抓取完整 URL、路径与查询参数 |
| 按时间范围回看与出趋势图 | 解析 HTTP 请求内容或响应体 |
| 展示部分可观察到的主机名 | 承诺覆盖全部连接的域名 |
| 单独标记代理运输流量 | 对代理流量做反向抵扣 |
| 识别内置的三个代理进程 | 自定义代理进程名单 |
| 本地导出与数据清理 | 限速、拦截或修改任何流量 |

关于统计精度：

- `nettop` 的进程级汇总与连接级观测存在天然差异，主机名排行属于**部分可见**，不能替代应用级总量
- 连接复用、代理转发和短生命周期连接都会造成主机名缺口
- IP-only 流量统一归入「无法识别 / 其他」，界面不展示原始 IP
- ByteTrace 不使用 Network Extension，因此无法拿到系统级的完整流量视图

## 常见问题

**看不到任何数据？**
首帧仅用于建立基线不会入账，需要等待一个采样周期。若状态一直停留在「正在建立统计基线」，检查面板中的错误提示。

**状态显示「系统格式不兼容」？**
说明当前 macOS 版本的 `nettop` 输出格式与解析器预期不符，此时会暂停入账以避免写入脏数据。欢迎提交 issue 并附上你的系统版本。

**Dock 里找不到 ByteTrace？**
这是设计如此。ByteTrace 是纯菜单栏应用（`LSUIElement`），只在菜单栏出现。退出请点击面板右下角的电源图标。

**主机名排行为什么只有寥寥几条？**
只有 `nettop` 在连接级直接暴露主机名的连接才会被统计。启用代理、连接复用或应用自建加密通道都会显著降低可见比例，这是该实验能力的固有限制。

**数据库会无限增长吗？**
默认不自动清理。可在「设置 → 细粒度统计」中启用 7 / 30 / 90 天保留策略，只会删除超期的分钟桶，日汇总与应用信息不受影响。

## 开发

```bash
swift build                                   # 构建
swift test                                    # 运行测试
swift run ByteTraceApp                        # 开发模式运行菜单栏应用
./Scripts/package_app.sh                      # 打包 .app / .dmg / .zip
```

`swift run ByteTraceApp` 直接运行的是裸可执行文件，没有 `.app` 包装，也读不到 `Packaging/Info.plist`，因此 `LSUIElement`、应用图标等由 Info.plist 决定的行为不会生效。验收菜单栏形态请用 `./Scripts/package_app.sh` 的产物。

调试探针（不写入正式数据库）：

```bash
swift run ByteTraceProbe --duration 15                              # 应用级采集，默认 15 秒
swift run ByteTraceConnectionProbe --duration 5                     # 连接级主机名采集
swift run ByteTraceConnectionProbe --duration 5 --runs 3 --process mihomo   # 多轮验证，每轮独立建立基线
```

打包脚本支持两个环境变量：`BYTE_TRACE_SIGNING_IDENTITY`（默认 `-`，即 ad-hoc）与 `BYTE_TRACE_SWIFT_TRIPLE`（交叉构建目标架构）。

### 项目结构

```
Sources/
  ByteTraceCore/            采集、CSV 解析、进程归属、SQLite 存储与聚合
  ByteTraceApp/             SwiftUI 菜单栏与主窗口
  ByteTraceProbe/           应用级采集探针
  ByteTraceConnectionProbe/ 连接级主机名探针
Tests/ByteTraceCoreTests/   ByteTraceCore 的单元测试
Scripts/
  package_app.sh            打包与签名
  check-release-version.py  校验 tag 与 Info.plist 版本一致
Packaging/                  Info.plist 与图标资源
```

### CI 与发布

- `ci.yml`：在 Apple Silicon 与 Intel runner 上执行构建、测试与打包校验
- `release.yml`：推送 `v*` 标签后构建双架构产物，生成 DMG、ZIP 与 SHA-256 校验文件并创建 Release
- 标签必须与 `Packaging/Info.plist` 中的 `CFBundleShortVersionString` 一致，由 `Scripts/check-release-version.py` 强制校验

发布不使用 Apple Developer ID 证书，也不执行公证，全部采用 ad-hoc 签名。

## 贡献

欢迎提交 issue 与 pull request。提交 issue 时请附上 macOS 版本与架构；涉及采集异常时，请附上对应探针命令的输出片段。

提交 PR 前请确保 `swift build` 与 `swift test` 通过，并保持既有代码风格。

## 许可

[MIT](LICENSE)

## 致谢

数据源为 macOS 系统自带的 [`nettop`](https://keith.github.io/xcode-man-pages/nettop.1.html)。
