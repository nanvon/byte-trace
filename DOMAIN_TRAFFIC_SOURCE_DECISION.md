# 域名/主机流量数据源决策

状态：评估完成，等待独立 Network Extension 原型；当前版本不接入域名数据库和域名 UI。

日期：2026-08-02

## 决策摘要

ByteTrace 继续使用 `/usr/bin/nettop -P` 作为应用级流量基线。连接级 `nettop` 只保留为诊断工具：`mihomo`、Telegram、Browser Helper 和 Dia 的多轮实测已经证明，它不能稳定覆盖所有应用的进程流量，也不能稳定提供应用到 hostname 的完整关联。

下一步不在现有菜单栏 App 中直接拼接域名列表，而是先做一个独立的 macOS Network Extension 原型。第一候选是 macOS `NEFilterDataProvider` 的 flow/report 链路，由宿主侧 `NEFilterManager` 管理配置；第二候选是针对选定应用的 App Proxy。两者都必须先完成权限、签名、生命周期和对账验证，再决定是否进入正式产品。

## 候选方案

| 方案 | 可获得的信息 | 主要代价和限制 | 当前决策 |
| --- | --- | --- | --- |
| `NEFilterDataProvider` + 宿主侧 `NEFilterManager` | 当前 macOS SDK 可提供来源 App audit token / source process audit token；socket flow 可提供远端 hostname（如果调用方按 hostname 建连）；WebKit flow 可能提供 HTTP URL；`NEFilterReport` 可提供流关闭时的入站/出站字节 | 需要 Content Filter Network Extension 能力；macOS 的 Filter Data Provider 需要 System Extension 形态；Provider 有严格沙箱，不能把它当普通 SwiftUI App 使用；audit token 到稳定 Bundle ID 的映射还需要单独验证；它本质上是内容过滤链路，默认决策和隐私边界必须明确 | **第一候选，先做只读统计原型** |
| `NEAppProxyProvider` | 按匹配到的应用接收 TCP/UDP flow；flow 有 source metadata，并可能提供 remote hostname；可以在转发过程中统计字节 | 需要 App Proxy entitlement 和 VPN/Per-App 路由配置；Provider 位于实际网络路径上，转发错误会影响网络；默认不覆盖未纳入规则的应用 | **第二候选，作为选定应用专项** |
| `NEPacketTunnelProvider` | 可从虚拟接口读取被路由进 tunnel 的 IP packet，覆盖面较广 | 需要自己重建 flow、DNS/hostname 和应用归属；网络路径、性能、权限和故障恢复成本最高；不能直接得到通用 URL | 暂不作为第一条路线 |
| DNS Proxy / DNS 观察 | 可辅助记录解析关系和时间 | 不能证明域名消耗了多少字节，会遗漏缓存、DoH/DoT、直连 IP 和代理转发 | 只能做辅助数据 |
| 浏览器或单应用扩展 | 特定浏览器可以提供页面 URL 或请求级信息 | 覆盖范围窄，无法回答系统级应用流量；需要分别适配应用 | 作为后续专项能力 |

## 官方能力边界

需要特别区分平台：当前 macOS SDK 将 `NEFilterFlow.sourceAppIdentifier` 标记为 macOS 不可用；macOS Provider 实际可用的是 `sourceAppAuditToken` 和 `sourceProcessAuditToken`，因此第一阶段不能直接承诺稳定的 Bundle ID 归属，需要验证 audit token 的解析链路。[NEFilterFlow](https://developer.apple.com/documentation/networkextension/nefilterflow)

`NEFilterSocketFlow` 的 `remoteHostname` 只在应用按 hostname 建连等条件满足时提供，不能保证所有连接都有 hostname。[remoteHostname](https://developer.apple.com/documentation/networkextension/nefiltersocketflow/remotehostname)

`NEFilterFlow.URL` 只对来自 WebKit browser objects 的 flow 可能非空，因此不能把它当作所有应用的完整 URL 来源。[URL](https://developer.apple.com/documentation/networkextension/nefilterflow/url)

`NEFilterReport` 可提供 flow 的入站/出站字节；Apple 文档说明这些计数在 flow 关闭事件中才非零，因此原型必须以 flow 生命周期为单位 flush，而不能只依赖新建连接事件。[NEFilterReport](https://developer.apple.com/documentation/networkextension/nefilterreport)、[bytesInboundCount](https://developer.apple.com/documentation/networkextension/nefilterreport/bytesinboundcount)

`NEAppProxyProvider` 接收匹配规则的 TCP/UDP flow，并可通过 flow metadata 获得来源应用信息；它属于实际的 App Proxy/VPN 路径，不是当前 `nettop` 这种被动读取器。[NEAppProxyProvider](https://developer.apple.com/documentation/networkextension/neappproxyprovider)、[NEAppProxyFlow](https://developer.apple.com/documentation/networkextension/neappproxyflow)

Network Extension 需要相应的 entitlement；Apple 列出的能力包括 `content-filter-provider`、`app-proxy-provider` 和 `packet-tunnel-provider`。macOS 的 Filter Data Provider 还需要 System Extension 部署，不能沿用当前单一菜单栏 App 的打包方式。[Network Extensions Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)、[filterDataProviderBundleIdentifier](https://developer.apple.com/documentation/networkextension/nefilterproviderconfiguration/filterdataproviderbundleidentifier)

## 当前项目边界

当前仓库只有 Swift Package、`Packaging/Info.plist` 和将单一 `ByteTraceApp` 签名打包的 `Scripts/package_app.sh`：

- 没有 `.entitlements` 文件；
- 没有 App Extension 或 System Extension target；
- 当前 ad-hoc `.app` 只能证明菜单栏应用本身可启动，不能证明 Network Extension entitlement、用户安装和系统扩展生命周期；
- 因此本阶段不修改 `Package.swift`、打包脚本、正式 SQLite schema 或主窗口 UI。

## 第一条原型路线

建立一个独立的 Xcode/System Extension 原型，先不连接正式 ByteTrace 数据库：

1. 只申请一个最小的 Content Filter capability，Provider 对 flow 做明确的 pass-through 决策，不拦截、不修改内容；
2. 记录最小字段：采样时间、source app audit token / source process audit token、解析后的 App 标识（若可得）、hostname 或远端 endpoint、可选 WebKit URL、方向、flow close 时的入站/出站字节和可见性状态；
3. 默认不保存请求内容、Cookie、Header、查询参数和响应正文；URL 也只作为明确标注的可选字段；
4. 用 WebKit 页面、`curl`、Telegram、Dia、`mihomo` 分别制造已知流量，与现有 `nettop` 应用级总量做同时间窗口对账；
5. 覆盖 flow 复用、HTTPS、UDP/DNS、代理转发、网络切换、睡眠唤醒、Provider 停止和用户关闭；
6. 只有在来源 App、hostname/URL 可见性、flow close 字节和权限体验都通过后，才设计正式 `domain_usage` 数据表。

## 进入正式产品的门槛

以下任一项未通过，就继续显示“域名明细不可用/评估中”，不显示推断的域名列表：

- 同一活跃场景连续多轮可将 flow 归属到应用；
- flow close 字节与应用级基线有可解释且稳定的差异；
- hostname、WebKit URL、IP-only 和未知流量分层清楚；
- Network Extension 安装、授权、启停、网络切换和异常退出可恢复；
- 不把扩展沙箱中的数据读取限制绕成未授权的系统级采集；
- 采集范围、保存字段、清理方式和关闭入口能在设置页明确说明。

当前决定：继续保持应用级统计为正式能力；域名/主机明细停在独立 Network Extension 原型之前，暂不实现通用域名 UI。
