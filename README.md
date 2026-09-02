<p align="center">
  <img src="Packaging/Resources/Brand/ByteTraceAppIconCentered.png" width="128" alt="ByteTrace Logo">
</p>

<h1 align="center">ByteTrace</h1>

<p align="center">
  <b>macOS 原生菜单栏应用级网络流量监控工具</b><br>
  实时呈现各应用上下行带宽与用量发生时段，零配置兼顾直连、系统代理与 TUN 流量。
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white">
  <a href="https://github.com/nanvon/byte-trace/releases/latest"><img alt="Latest Release" src="https://img.shields.io/github/v/release/nanvon/byte-trace?color=brightgreen"></a>
  <img alt="Total Downloads" src="https://img.shields.io/github/downloads/nanvon/byte-trace/total?color=blue">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-orange">
</p>

<p align="center">
  <a href="https://github.com/nanvon/byte-trace/releases/latest">下载安装</a> ·
  <a href="#-核心特性">核心特性</a> ·
  <a href="#-界面预览">界面预览</a> ·
  <a href="#-快速安装">安装指南</a> ·
  <a href="#-数据与隐私安全">数据安全</a> ·
  <a href="#-从源码构建">从源码构建</a> ·
  <a href="https://github.com/nanvon/byte-trace/issues">问题反馈</a> ·
  <a href="README_EN.md">English</a>
</p>

<p align="center">
  <img src="docs/images/menubar-panel.png" width="380" alt="ByteTrace 菜单栏面板">
</p>

---

## ✨ 核心特性

### ⚡ 菜单栏常驻与轻量交互
- **今日流量即时看板** — 状态栏直显当日总流量、实时下行（下载）与上行（上传）累积数值，采集状态指示灯秒级反馈运行状态。
- **应用级消耗动态排行** — 自动按流量消耗逆序排列前台与后台应用，集成应用专属原生图标与双向字节明细。
- **代理与系统进程独立分组** — 将代理外层运输流量与 macOS 系统守护进程自动折叠归组，杜绝污染用户应用实际统计。
- **极低后台系统负载** — 采集通道保持极低 CPU 与内存基线开销，支持菜单栏一键随时暂停或恢复采集。

### 🌐 双通道代理感知与流量校准
- **免配置动态代理适配** — 自动监听 macOS `SystemConfiguration` 动态代理变更，无需手动指定或轮询 7890 等本地监听端口。
- **外层与回环双通道管线** — 外部通道（5s 周期）汇总实体网卡进程流量；补充通道（1s 周期）高频捕获 `lo0` 代理入口与 `utun*` 隧道流量。
- **防重记与镜像消除机制** — 算法级剔除本地 IPC 进程通信、广播多播包以及代理客户端对 TUN 的镜像流量，杜绝数据虚高与双重计费。

### 📊 多维历史分析与数据自主掌控
- **五档时间窗口穿透** — 支持「最近 10 分钟」、「最近 1 小时」、「今天」、「本周」与「本月」五维范围，下钻查看各应用独立时序趋势图。
- **进程拓扑树智能归属** — 沿进程派生链向上回溯多达 8 层祖先，自动将浏览器 Helper、渲染器及辅助子进程准确归并至主应用 Bundle。
- **可配置本地生命周期** — 提供分钟级明细桶 7 天 / 30 天 / 90 天及永久保留策略，支持一键无损导出当前范围结构化 JSON 数据。

---

### 📸 界面预览

<p align="center">
  <img src="docs/images/main-window.png" width="760" alt="ByteTrace 主窗口概览"><br>
  <sub><b>主窗口全景看板</b>：时间范围切换、多维汇总指标卡、实时动态流量趋势图表与应用排行明细</sub>
</p>

---

## 📦 快速安装

> **运行环境**：macOS 14 (Sonoma) 或更高版本，原生支持 Apple Silicon (M 系列芯片) 与 Intel 架构。<br>
> **前置要求**：**零特权依赖**。无需安装 Network Extension、无需内核扩展 (kext)、无需 root / sudo 提权。

1. 前往 [Releases 页面](https://github.com/nanvon/byte-trace/releases/latest) 下载对应架构的安装包：

   | 硬件芯片架构 | 推荐下载安装包 | 说明 |
   | :--- | :--- | :--- |
   | **Apple Silicon (M 系列芯片)** | `ByteTrace_<版本>_macOS-Apple-Silicon.dmg` | 原生 arm64 架构 |
   | **Intel 处理器** | `ByteTrace_<版本>_macOS-Intel.dmg` | 原生 x86_64 架构 |

   *(注：亦可下载免挂载的 `.zip` 压缩包，解压后内容完全一致。)*

2. 打开 DMG 镜像，将 `ByteTrace.app` 拖入 `Applications` 应用程序目录；
3. 启动应用后，macOS 菜单栏将常驻 ⇅ 图标（无 Dock 栏图标），点击图标即自动开始监控。

> [!NOTE]
> **首次启动安全放行提示 (Gatekeeper)**
>
> 官方发布的预编译包使用本地 ad-hoc 签名（未购买 Apple 开发者账号企业证书公证）。首次启动若被系统拦截：
> 1. 打开 **系统设置 → 隐私与安全性**，向下滑动找到拦截提示，点击 **「仍要打开」**（*macOS Sequoia 起旧版右键打开方式已失效*）；
> 2. 若系统提示「应用程序已损坏」，可在终端手动清除隔离属性：
>    ```bash
>    xattr -dr com.apple.quarantine /Applications/ByteTrace.app
>    ```

每个 Release 产物均随附同名 `.sha256` 校验文件及汇总的 `SHA256SUMS.txt`，可供校验二进制完整性：
```bash
shasum -a 256 -c ByteTrace_<版本>_macOS-Apple-Silicon.dmg.sha256
```

---

## 🔒 数据与隐私安全

ByteTrace 遵循**本地优先（Local-first）与零遥测（Zero Telemetry）**原则，所有解析、统计与绘图均在用户本地闭环完成：

### 凭据与权限访问矩阵

| 模块 / 数据源 | 存储与访问路径 | 权限模式 | 安全机制与行为说明 |
| :--- | :--- | :---: | :--- |
| **系统流量数据源** | `/usr/bin/nettop` | **严格只读** | 系统内置网络诊断工具，普通用户权限启动子进程，零 root 提权，仅读取进程进出字节计数。 |
| **代理配置监听** | `SCDynamicStore` (SystemConfiguration) | **严格只读** | 动态监听系统网络代理配置（用于回环端口过滤），端点仅留存内存，绝不持久化、绝不外显。 |
| **本地用量数据库** | `~/Library/Application Support/com.nanvon.ByteTrace/usage.sqlite3` | **本地读写** | 原生 SQLite3（WAL 模式），无密码加密，数据完全归用户所有，可使用任意 SQLite 工具查阅或删除。 |
| **应用偏好配置** | `UserDefaults` (`com.nanvon.ByteTrace`) | **本地读写** | 仅存储开机自启开关、系统进程显示偏好与数据保留天数。 |

### 安全与隐私承诺
- **零外部遥测 (Zero Telemetry)**：项目无任何第三方数据分析 SDK、错误上报或外部网络请求逻辑，绝不向外部网络回传任何统计数据；
- **零报文解析**：不捕获网络数据载荷，不解密 HTTPS/TLS 通信，不读取任何请求体、标头、Cookie 或访问网址，仅汇总内核层进程网络字节量；
- **无敏感权限索取**：不申请辅助功能权限、屏幕录制权限或完整磁盘访问权限。

> [!TIP]
> 预编译版本均采用开源源码公开构建并生成。如果您对未公证的二进制文件有所顾虑，推荐自行审阅代码后[从源码构建](#-从源码构建)。

---

## 🔧 从源码构建

### 环境要求
* macOS 14.0 或更高版本
* Xcode 16.0+（包含 Swift 6.0 工具链）
* Swift Package Manager (SPM，零第三方依赖)

### 本地日常开发调试
```bash
# 克隆仓库
git clone https://github.com/nanvon/byte-trace.git
cd byte-trace

# 编译项目
swift build

# 执行单元测试
swift test

# 开发模式运行应用（仅用于代码逻辑调试）
swift run ByteTraceApp
```

> [!WARNING]
> `swift run ByteTraceApp` 直接运行编译产出的裸二进制文件，无法读取 `Packaging/Info.plist`，因此菜单栏常驻策略（`LSUIElement`）与应用图标将不会生效。如需完整体验真实菜单栏交互，请使用打包脚本生成 `.app`。

### 导出正式打包产物
使用仓库内置的打包脚本完成打包与 ad-hoc 签名：
```bash
./Scripts/package_app.sh
```
打包成功后，输出产物将保存在 `dist/` 目录：
- `dist/ByteTrace.app`（macOS 应用程序包）
- `dist/ByteTrace.dmg`（带 Applications 软链接的安装镜像）
- `dist/ByteTrace.zip`（便携压缩包）

---

## 🙏 致谢

- [`nettop`](https://keith.github.io/xcode-man-pages/nettop.1.html) — macOS 系统内置的高效网络性能分析工具，为 ByteTrace 提供了无侵入、免扩展的数据测量底座。

---

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。
