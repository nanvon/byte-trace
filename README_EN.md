<p align="center">
  <img src="Packaging/Resources/Brand/ByteTraceAppIconCentered.png" width="128" alt="ByteTrace Logo">
</p>

<h1 align="center">ByteTrace</h1>

<p align="center">
  <b>Native macOS Menu Bar App-Level Network Traffic Monitor</b><br>
  Real-time per-application bandwidth accounting across direct, system proxy, and TUN connections using native system telemetry.
</p>

<p align="center">
  <a href="https://github.com/nanvon/byte-trace/releases/latest"><img alt="Latest Release" src="https://img.shields.io/github/v/release/nanvon/byte-trace?color=brightgreen"></a>
  <img alt="Total Downloads" src="https://img.shields.io/github/downloads/nanvon/byte-trace/total?color=blue">
  <a href="https://github.com/nanvon/byte-trace/releases/latest"><img alt="Latest Downloads" src="https://img.shields.io/github/downloads/nanvon/byte-trace/latest/total?label=latest%20downloads&color=blue"></a>
  <a href="https://github.com/nanvon/byte-trace/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/nanvon/byte-trace/ci.yml?branch=main"></a>
</p>

<p align="center">
  <a href="https://github.com/nanvon/byte-trace/releases/latest">Download</a> ·
  <a href="#-features">Features</a> ·
  <a href="#-screenshots">Screenshots</a> ·
  <a href="#-installation">Installation</a> ·
  <a href="#-data--privacy-security">Data & Security</a> ·
  <a href="#-building-from-source">Build from Source</a> ·
  <a href="https://github.com/nanvon/byte-trace/issues">Issues</a> ·
  <a href="README.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/images/menubar-panel.png" width="360" alt="ByteTrace Menu Bar Panel - Light Appearance">
  <img src="docs/images/menubar-panel-dark.png" width="360" alt="ByteTrace Menu Bar Panel - Dark Appearance"><br>
  <sub>Menu bar panel (light on the left, dark on the right)</sub>
</p>

---

## ✨ Features

### ⚡ Menu Bar Presence & Lightweight Interaction
- **Live Daily Summary Dashboard** — Displays today's cumulative traffic, download, and upload totals directly in the menu bar, with real-time status indicators reflecting collection state.
- **Dynamic App Consumption Ranking** — Automatically sorts foreground and background applications in descending order of traffic, featuring native application icons and bidirectional byte breakdowns.
- **Dedicated Proxy & System Process Grouping** — Collapses proxy transport flows and macOS system daemons into separate sections, preventing background noise from inflating application totals.
- **Minimal Background Footprint** — Maintains low CPU and memory baselines, with one-click toggles to start or pause collection at any time.

### 🌐 Dual-Channel Proxy-Aware Pipeline
- **Zero-Configuration Proxy Detection** — Dynamically listens to macOS `SystemConfiguration` proxy state, eliminating the need to hard-code or poll local ports such as 7890.
- **External & Loopback Dual Pipeline** — An external channel (5s interval) aggregates physical interface traffic; a supplemental channel (1s interval) captures `lo0` proxy loopback and `utun*` tunnel flows.
- **De-duplication & Mirror Traffic Rejection** — Filters out local IPC communications, broadcast/multicast packets, and proxy mirror traffic on TUN interfaces to eliminate inflated and duplicate byte counts.
- **Direct vs. Proxied Breakdown** — Splits each app's traffic into direct and proxied; when a local mihomo connection table is readable, proxied traffic is further split into proxy nodes and rule-based DIRECT (can be turned off in Settings).
- **Readable System Processes** — Common macOS daemons show a short description of what they do, and command-line tools show which app or tool launched them.

### 📊 Historical Analytics & Data Ownership
- **Five Granular Time Windows** — Supports Last 10 Minutes, Last Hour, Today, This Week, and This Month, with drill-down views into individual application timelines.
- **Process Hierarchy Attribution** — Traverses up to 8 ancestor process levels to accurately attribute helper processes, renderers, and daemons to their parent application bundle.
- **Configurable Local Retention** — Offers 7-day, 30-day, 90-day, and indefinite retention policies for minute-level buckets, alongside one-click structured JSON export for any selected range.

---

### 📸 Screenshots

<p align="center">
  <img src="docs/images/main-window.png" width="760" alt="ByteTrace Main Window Overview"><br>
  <sub><b>Main Window Panoramic Dashboard</b>: Time range selector, multidimensional summary cards, dynamic traffic trend charts, and detailed application ranking</sub>
</p>

---

## 📦 Installation

> **System Requirements**: macOS 26 or later; Apple Silicon (M-series) only.<br>
> **Privilege Notice**: **Zero elevated privileges**. Requires no Network Extension, no kernel extensions (kext), and no root / sudo access.

1. Download the Apple Silicon package from the [Releases page](https://github.com/nanvon/byte-trace/releases/latest):

   | Hardware Architecture | Recommended Package | Details |
   | :--- | :--- | :--- |
   | **Apple Silicon (M-series chips)** | `ByteTrace_<version>_macOS-Apple-Silicon.dmg` | Native arm64 architecture |

   *(Note: Standalone `.zip` archives are also provided with identical contents for mounting-free extraction.)*

2. Open the DMG image and drag `ByteTrace.app` into your `Applications` directory;
3. Launch the application. A ⇅ icon will appear in the macOS menu bar (the app does not appear in the Dock); click the icon to begin monitoring.

Check for updates from the app menu or beside the current version in Settings → About ByteTrace. When an update is available, the bottom of the menu bar panel shows its version and a Download button that opens the update window. The window displays release notes and download progress, then installs and restarts after confirmation. Automatic checks are optional. Versions without the updater require one manual upgrade first.

> [!NOTE]
> **First-Launch Gatekeeper Prompt**
>
> Official prebuilt releases are signed using local ad-hoc signatures without paid Apple Developer notarization. If macOS prevents initial launch:
> 1. Navigate to **System Settings → Privacy & Security**, locate the blocked ByteTrace notification, and click **"Open Anyway"** (*the legacy right-click Open shortcut is deprecated in macOS Sequoia*);
> 2. If macOS reports that the application "is damaged", clear the quarantine attribute via Terminal:
>    ```bash
>    xattr -dr com.apple.quarantine /Applications/ByteTrace.app
>    ```

Each release asset includes a matching `.sha256` checksum file and an aggregated `SHA256SUMS.txt` for integrity verification:
```bash
shasum -a 256 -c ByteTrace_<version>_macOS-Apple-Silicon.dmg.sha256
```

---

## 🔒 Data & Privacy Security

ByteTrace adheres to **Local-first and Zero Telemetry** principles. All analysis, metric aggregation, and visual rendering occur strictly on your machine:

### Access & Storage Matrix

| Module / Data Source | Path & Storage Location | Access Mode | Security Mechanism & Behavior |
| :--- | :--- | :---: | :--- |
| **System Traffic Source** | `/usr/bin/nettop` | **Strictly Read-Only** | Native macOS diagnostic tool executed as a subprocess with standard user privileges; zero root elevation; reads byte counters only. |
| **Proxy State Monitor** | `SCDynamicStore` (SystemConfiguration) | **Strictly Read-Only** | Dynamically listens for active local proxy ports for loopback filtering; endpoints are kept in memory only and never written to disk or exposed. |
| **mihomo Connection Table (optional)** | Local mihomo controller (`127.0.0.1` or unix socket) | **Strictly Read-Only** | Reads `/connections` every 2 seconds only while proxy traffic is present, using just each connection's local port and outbound chain to tell proxy nodes from rule-based DIRECT. Reads the proxy core's launch arguments and config file to find the controller address and secret. Connection data stays in memory; domains and destinations are never stored. Can be turned off in Settings. |
| **Local Metrics Store** | `~/Library/Application Support/com.nanvon.ByteTrace/usage.sqlite3` | **Local Read/Write** | Embedded SQLite3 (WAL mode) database without encryption; entirely owned by the user and inspectable/clearable via any SQLite client. |
| **App Preferences** | `UserDefaults` (`com.nanvon.ByteTrace`) | **Local Read/Write** | Stores launch-at-login, process visibility, retention, and automatic update check preferences. |
| **App Updates** | GitHub Releases / Sparkle | **Network Read** | Fetches signed update feeds, notes, and archives. EdDSA verification is required; traffic statistics and system profiles are never uploaded. |

### Security & Privacy Commitments
- **Zero Telemetry**: No analytics or crash reporting SDKs, and no statistics are uploaded. Update checks access GitHub and its download services; automatic checks can be disabled in Settings.
- **No Packet Inspection**: Does not capture network payloads, decrypt HTTPS/TLS streams, or inspect request bodies, headers, cookies, or URL paths; only records OS kernel-level process byte totals.
- **Minimal Permissions**: Requests no Accessibility, Screen Recording, or Full Disk Access permissions.

> [!TIP]
> All prebuilt binaries are compiled directly from open-source repository code. If you prefer not to run ad-hoc signed executables, you can inspect the code and [build from source](#-building-from-source).

---

## 🔧 Building from Source

### Prerequisites
* macOS 26.6 or later on Apple Silicon (M-series)
* Xcode 27.1 (with the macOS 27.0 SDK, matching CI and release builds)
* Swift Package Manager (Sparkle 2.10.0 for updates; collection and storage have no third-party dependencies)

### Run in Xcode

Open `ByteTrace.xcodeproj`, select the `ByteTrace` scheme and My Mac, then press ⌘R. The project uses `Packaging/Info.plist` and the icon resources to run a full `.app`. Quit any installed copy of ByteTrace first: both use the same bundle ID, preferences, and SQLite database.

The project references `ByteTraceCore` through the local Swift package and uses Sparkle for updates. `Sources/ByteTraceApp/` is a synchronized folder, so new source files do not require manual project-file changes. The scheme has no test target; use `swift test` below. CI and release packaging also continue to use Swift Package Manager and the packaging script.

### Command-Line Development & Debugging
```bash
# Clone repository
git clone https://github.com/nanvon/byte-trace.git
cd byte-trace

# Build project
swift build

# Run unit tests
swift test

# Run app in development mode (logic debugging only)
swift run ByteTraceApp
```

> [!WARNING]
> `swift run ByteTraceApp` runs a raw binary without `Packaging/Info.plist` or the app bundle's icon resources; in-app updates are unavailable. Use the Xcode project or the packaging script below when a full `.app` is needed.

In-app updating also requires an `.app` bundle. See [app update configuration](docs/APP_UPDATES.md) for signing and release setup.

### Packaging a Release Bundle
Execute the bundled packaging script to compile and ad-hoc sign the production bundle:
```bash
./Scripts/package_app.sh
```
Artifacts are generated in the `dist/` directory:
- `dist/ByteTrace.app` (macOS application bundle)
- `dist/ByteTrace.dmg` (disk image with Applications symlink)
- `dist/ByteTrace.zip` (portable distribution archive)

---

## 🙏 Acknowledgments

- [`nettop`](https://keith.github.io/xcode-man-pages/nettop.1.html) — The built-in macOS network diagnostics tool providing an efficient, non-intrusive foundation for process-level network measurement.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
