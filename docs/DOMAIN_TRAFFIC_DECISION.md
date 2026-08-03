# 域名/主机流量数据源决策

状态：决策已完成；正式应用级统计和有限 hostname 实验排行已实现。正式产品不接入通用域名/URL 采集和完整域名 UI；Network Extension Lab 冻结为编译研究记录。macOS 桌面会话、网络/睡眠恢复、对账和长时间运行仍需实机验收。

日期：2026-08-02

## 决策摘要

ByteTrace 继续使用 `/usr/bin/nettop -P` 作为应用级流量基线。连接级 `nettop` 不作为精确域名流量来源，但允许用于独立的实验排行：在能同时观察到 hostname 和应用归属的连接中，按全局或应用聚合上下行字节。`mihomo`、Telegram、Browser Helper 和 Dia 的多轮实测已经证明，它不能稳定覆盖所有应用的进程流量，也不能稳定提供应用到 hostname 的完整关联，因此必须显示“无法识别/其他”和可识别覆盖率。

技术上，Network Extension 可以支持更细粒度的 flow 观察；但在当前“不购买 Apple Developer Program、只在自己的 Mac 上使用”的前提下，免费 Personal Team 不支持 Network Extension provider 的授权运行。正式产品不继续推进 Network Extension 的签名、安装、用户授权、启用或网络对账。Bytetally 等已运行产品只能证明授权环境下的技术可行性，不能改变 ByteTrace 的账号和产品边界。

## 账号费用与可做范围（已联网核实）

当前不购买 Apple Developer Program、不支付每年 ¥688 时，ByteTrace 仍可以继续使用 `/usr/bin/nettop` 做本地、连接级的粗略排行：

- 全局可见 hostname 的上传、下载和总量排行；
- 应用详情内的可见 hostname 排行；
- IP-only、hostname 缺失和无法关联应用的流量归入“无法识别/其他”；
- 显示可识别覆盖率，不把部分结果伪装成完整域名流量。

该能力不需要 Network Extension entitlement。Apple 中国大陆官方页面显示 ¥688 是 Apple Developer Program 的年度续订费用；Apple DTS 明确说明免费 Personal Team 不支持 Network Extension Provider。因此，¥688 是 Network Extension 的授权、签名、安装和启用路线的前置条件，不是普通 `nettop` 粗略排行的前置条件。[Apple 中国大陆注册与续订说明](https://developer.apple.com/cn/help/account/membership/enrolling-in-the-app/)、[Apple 会员资格对比](https://developer.apple.com/cn/support/compare-memberships/)、[Apple DTS：免费 Personal Team 不支持 Network Extension Provider](https://developer.apple.com/forums/thread/128767)

`nettop` 只提供 socket/连接级观察，不等于 HTTP 请求级数据。连接级模式可以尽力取得 hostname、端口、协议和字节，但不能保证所有 App 都可见，也不能提供通用完整 URL、路径、查询参数或请求内容。[nettop 手册](https://keith.github.io/xcode-man-pages/nettop.1.html)

## 候选方案

| 方案 | 可获得的信息 | 主要代价和限制 | 当前决策 |
| --- | --- | --- | --- |
| 连接级 `nettop` | 部分连接可提供 hostname、远端端口、协议和上下行字节，并有机会关联到应用 | 连接明细与进程摘要存在差异；代理转发、连接复用、UDP/QUIC、短生命周期连接和 hostname 缺失都会造成部分可见；不能提供完整 URL 或 HTTP 请求 | **允许进入独立的可见网站/主机名排行实验；不替代应用级总量** |
| `NEFilterDataProvider` + 宿主侧 `NEFilterManager` | 当前 macOS SDK 可提供来源 App audit token / source process audit token；socket flow 可提供远端 hostname（如果调用方按 hostname 建连）；WebKit flow 可能提供 HTTP URL；`NEFilterReport` 可提供流关闭时的入站/出站字节 | 需要 Content Filter Network Extension 能力；macOS 的 Filter Data Provider 需要 System Extension 形态；Provider 有严格沙箱，不能把它当普通 SwiftUI App 使用；audit token 到稳定 Bundle ID 的映射还需要单独验证；它本质上是内容过滤链路，默认决策和隐私边界必须明确 | **不进入当前产品；仅保留编译研究记录** |
| `NEAppProxyProvider` | 按匹配到的应用接收 TCP/UDP flow；flow 有 source metadata，并可能提供 remote hostname；可以在转发过程中统计字节 | 需要 App Proxy entitlement 和 VPN/Per-App 路由配置；Provider 位于实际网络路径上，转发错误会影响网络；默认不覆盖未纳入规则的应用 | **不进入当前产品** |
| `NEPacketTunnelProvider` | 可从虚拟接口读取被路由进 tunnel 的 IP packet，覆盖面较广 | 需要自己重建 flow、DNS/hostname 和应用归属；网络路径、性能、权限和故障恢复成本最高；不能直接得到通用 URL | 暂不作为第一条路线 |
| DNS Proxy / DNS 观察 | 可辅助记录解析关系和时间 | 不能证明域名消耗了多少字节，会遗漏缓存、DoH/DoT、直连 IP 和代理转发 | 不进入当前产品，仅作为历史评估 |
| 用户手动配置的 HTTP/SOCKS 代理 | 对遵守代理设置的应用可观察部分主机或请求 | 不覆盖绕过代理的应用、UDP/QUIC 和未配置代理的流量；应用归属也可能退化为代理进程 | 不作为默认或通用方案 |
| 浏览器或单应用扩展 | 特定浏览器可以提供页面 URL 或请求级信息 | 覆盖范围窄，无法回答系统级应用流量；需要分别适配应用 | 不进入当前产品 |

## 官方能力边界

需要特别区分平台：当前 macOS SDK 将 `NEFilterFlow.sourceAppIdentifier` 标记为 macOS 不可用；macOS Provider 实际可用的是 `sourceAppAuditToken` 和 `sourceProcessAuditToken`，因此第一阶段不能直接承诺稳定的 Bundle ID 归属，需要验证 audit token 的解析链路。[NEFilterFlow](https://developer.apple.com/documentation/networkextension/nefilterflow)

`NEFilterSocketFlow` 的 `remoteHostname` 只在应用按 hostname 建连等条件满足时提供，不能保证所有连接都有 hostname。[remoteHostname](https://developer.apple.com/documentation/networkextension/nefiltersocketflow/remotehostname)

`NEFilterFlow.URL` 只对来自 WebKit browser objects 的 flow 可能非空，因此不能把它当作所有应用的完整 URL 来源。[URL](https://developer.apple.com/documentation/networkextension/nefilterflow/url)

`NEFilterReport` 可提供 flow 的入站/出站字节；Apple 文档说明这些计数在 flow 关闭事件中才非零，因此原型必须以 flow 生命周期为单位 flush，而不能只依赖新建连接事件。[NEFilterReport](https://developer.apple.com/documentation/networkextension/nefilterreport)、[bytesInboundCount](https://developer.apple.com/documentation/networkextension/nefilterreport/bytesinboundcount)

`NEAppProxyProvider` 接收匹配规则的 TCP/UDP flow，并可通过 flow metadata 获得来源应用信息；它属于实际的 App Proxy/VPN 路径，不是当前 `nettop` 这种被动读取器。[NEAppProxyProvider](https://developer.apple.com/documentation/networkextension/neappproxyprovider)、[NEAppProxyFlow](https://developer.apple.com/documentation/networkextension/neappproxyflow)

Network Extension 需要相应的 entitlement；Apple 列出的能力包括 `content-filter-provider`、`app-proxy-provider` 和 `packet-tunnel-provider`。macOS 的 Filter Data Provider 还需要 System Extension 部署，不能沿用当前单一菜单栏 App 的打包方式。[Network Extensions Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)、[filterDataProviderBundleIdentifier](https://developer.apple.com/documentation/networkextension/nefilterproviderconfiguration/filterdataproviderbundleidentifier)

Apple DTS 明确说明 Network Extension provider 不支持免费 Personal Team；它必须由 provisioning profile 授权。Apple 的系统扩展开发模式可以放宽部分目录和开发检查，但不能替代正确的 entitlement 和代码签名。[免费账号与 Network Extension](https://developer.apple.com/forums/thread/128767)、[调试和测试系统扩展](https://developer.apple.com/documentation/driverkit/debugging-and-testing-system-extensions)

## 当前项目边界

当前仓库是 Swift Package，包含单一 `ByteTraceApp`、独立 hostname 实验数据模型和将应用签名打包的 `Scripts/package_app.sh`：

- 没有 `.entitlements` 文件；
- 没有 App Extension 或 System Extension target；
- 当前 ad-hoc `.app` 的 release 构建、图标资源复制和签名校验已通过；它不能证明 Network Extension entitlement、用户安装和系统扩展生命周期，真实 Finder/菜单栏启动仍需有 WindowServer 的桌面会话验收；
- 因此后续正式开发不修改 `Package.swift`、打包脚本或主窗口 UI 来接入 Network Extension；可在独立的数据模型和查询层增加连接级 hostname 实验排行，但不得修改应用级统计口径；正式产品继续沿用 `nettop` 应用级采集链。

## 原型运行门禁记录

2026-08-02 已在当前开发机执行只读前置检查：`security find-identity -v -p codesigning` 返回 `0 valid identities found`，本地 provisioning profile 目录也没有可用 profile。由此可以确认：当前 Network Extension Lab 只能保留编译和纯数据模型测试记录，不能进入安装、用户授权或启用阶段。

这不是 `NEFilterDataProvider` 代码编译失败，而是签名与 entitlement 前置条件未满足。可重复执行的检查位于 [NetworkExtensionLab/Scripts/preflight.sh](NetworkExtensionLab/Scripts/preflight.sh)；在获得 Apple Developer 签名身份和对应 Network Extension entitlement 前，不执行 `--save-disabled-config`，也不尝试修改系统网络配置。

## 已冻结的原型路线（历史记录）

以下内容记录此前为验证技术边界而建立的独立 Xcode/System Extension 原型，不是当前开发任务，也不代表项目会继续推进运行化：

1. 只申请一个最小的 Content Filter capability，Provider 对 flow 做明确的 pass-through 决策，不拦截、不修改内容；
2. 记录最小字段：采样时间、source app audit token / source process audit token、解析后的 App 标识（若可得）、hostname 或远端 endpoint、可选 WebKit URL、方向、flow close 时的入站/出站字节和可见性状态；
3. 以版本化 `flow_closed` 事件作为第一版对账边界，事件包含 flow 生命周期、可见性和入站/出站字节，但不把原始 audit token 写入 public log；
4. 默认不保存请求内容、Cookie、Header、查询参数和响应正文；URL 也只作为明确标注的可选字段；
5. 用 WebKit 页面、`curl`、Telegram、Dia、`mihomo` 分别制造已知流量，与现有 `nettop` 应用级总量做同时间窗口对账；
6. 覆盖 flow 复用、HTTPS、UDP/DNS、代理转发、网络切换、睡眠唤醒、Provider 停止和用户关闭；
7. 原计划只有在来源 App、hostname/URL 可见性、flow close 字节和权限体验都通过后，才设计正式 `domain_usage` 数据表；该计划现已取消。

## 已取消的正式接入门槛

以下门槛仅用于保留历史验收标准，不再作为后续实现计划：

- 同一活跃场景连续多轮可将 flow 归属到应用；
- flow close 字节与应用级基线有可解释且稳定的差异；
- hostname、WebKit URL、IP-only 和未知流量分层清楚；
- Network Extension 安装、授权、启停、网络切换和异常退出可恢复；
- 不把扩展沙箱中的数据读取限制绕成未授权的系统级采集；
- 采集范围、保存字段、清理方式和关闭入口能在设置页明确说明。

## 最终产品决定

- 正式数据源：`/usr/bin/nettop -P`；
- 正式数据粒度：应用/进程级上传、下载、总量和时间聚合；
- 正式 UI：菜单栏 popover、主窗口概览、设置、趋势、排行和应用详情；
- 实验 UI：连接级 `nettop` 允许支持全局“可见网站/主机名排行”和应用详情内的“可见网站/主机名排行”；不显示原始 IP，无法识别的流量归入“无法识别/其他”，并展示覆盖率；
- 口径隔离：实验排行不写回或重复计入应用级总量，不能替代正式应用级统计；
- 明确不做：Network Extension 运行化、通用域名采集、完整 URL、HTTP 请求解析、系统级透明代理、TLS 检查和限速代理扩展。

当前实现已经按上述决定完成正式应用级统计和有限 hostname 实验排行；剩余工作只包括 macOS 桌面会话、网络/睡眠、对账和长跑验收。若将来账号、权限或需求边界发生变化，重新开立独立评估，不在当前路线中隐式扩张范围。
