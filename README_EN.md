<!-- Logo placeholder: the repo has no embeddable PNG icon yet (only .icns under Packaging/). Replace this comment once one exists:
<p align="center">
  <img src="docs/images/app-icon-256.png" width="128" alt="ByteTrace icon">
</p>
-->

<h1 align="center">ByteTrace</h1>

<p align="center">A per-app network traffic monitor that lives in the macOS menu bar:<br>see how much data each app used, and when.</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white">
  <img alt="swift" src="https://img.shields.io/badge/Swift%206-F05138?logo=swift&logoColor=white">
  <a href="https://github.com/nanvon/byte-trace/releases/latest"><img alt="release" src="https://img.shields.io/github/v/release/nanvon/byte-trace?color=brightgreen"></a>
  <img alt="downloads" src="https://img.shields.io/github/downloads/nanvon/byte-trace/total?color=blue">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-orange">
</p>

<p align="center">
  <a href="https://github.com/nanvon/byte-trace/releases/latest">Download</a> ·
  <a href="#-installation">Install</a> ·
  <a href="#-building-from-source">Build from source</a> ·
  <a href="https://github.com/nanvon/byte-trace/issues">Feedback</a> ·
  <a href="README.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/images/menubar-panel.png" width="360" alt="Menu bar panel">
</p>

## ✨ Features

- **Menu bar panel** — today's total / download / upload summary and a traffic-sorted app list with real app icons; proxy-transport traffic and system background processes sit in their own collapsible groups, kept out of the app total; live collection status, with start/stop at any time
- **Proxy-aware accounting** — covers direct, TUN, and macOS system-proxy traffic; active proxy endpoints are read from system settings instead of hard-coding Clash/Mihomo ports, while the supplemental lane filters proxy mirrors, local IPC, and broadcast traffic to avoid missing, duplicate, or inflated app usage
- **Main window overview** — five time ranges (last 10 minutes / last hour / today / this week / this month): summary cards, a traffic trend chart, and an app ranking; click any app to open its detail page
- **App detail** — one app's total, upload/download, and its own trend chart, plus an optional registrable-domain ranking identified through Mihomo
- **Settings** — optional local Mihomo website accounting, minute-level data retention (never / 7 / 30 / 90 days), JSON export of the current range, clear statistics, show system processes, and launch at login

### 📸 Screenshots

<p align="center">
  <img src="docs/images/main-window.png" width="720" alt="Main window overview"><br>
  <sub>Overview: time-range switcher, summary cards, traffic trend, and app ranking</sub>
</p>

## 📦 Installation

🍎 Requires macOS 14 (Sonoma) or later, on Apple Silicon or Intel; no system extensions, kernel extensions, or root privileges needed.

1. Download the artifact for your architecture from [Releases](https://github.com/nanvon/byte-trace/releases/latest):

   | Your Mac                     | File                                        |
   | ---------------------------- | ------------------------------------------- |
   | Apple Silicon (M-series)     | `ByteTrace_<version>_macOS-Apple-Silicon.dmg` |
   | Intel                        | `ByteTrace_<version>_macOS-Intel.dmg`         |

   Not sure which Mac you have: Apple menu (top-left) → "About This Mac", check the "Chip" line. The `.zip` has identical contents to the `.dmg`, no mounting required — pick whichever you prefer.

2. Open the DMG and drag ByteTrace into Applications. After launch, a ⇅ icon appears in the menu bar (the app does not show in the Dock); click the icon and collection starts.

3. ByteTrace is not notarized by Apple, so Gatekeeper blocks the first launch: after the double-click is blocked, go to **System Settings → Privacy & Security**, scroll down to the ByteTrace prompt, and click **"Open Anyway"**.

> [!NOTE]
> Since macOS Sequoia the old "right-click → Open" bypass no longer works; the System Settings route above is the only way.
> If macOS still claims the app "is damaged", remove the quarantine attribute manually:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/ByteTrace.app
> ```

Every artifact ships with a same-named `.sha256` file plus an aggregated `SHA256SUMS.txt` for integrity checks:

```bash
shasum -a 256 -c ByteTrace_<version>_macOS-Apple-Silicon.dmg.sha256
```

## 🔒 Data & Security

- Application totals come exclusively from the read-only system command `/usr/bin/nettop`; no Network Extension is used
- Website rankings are off by default. When enabled, ByteTrace only connects to a Mihomo API on a loopback address and reads active connections' host, process path, and cumulative byte counters; it never guesses a domain from a destination IP
- The optional Mihomo secret is stored in the macOS Keychain. Very short connections may be missed, so identified-domain totals do not equal an app's total traffic
- ByteTrace only reads enabled local-proxy addresses and ports from macOS `SystemConfiguration` to identify app-to-proxy loopback traffic; endpoints are neither stored nor displayed
- Everything is stored locally in SQLite: `~/Library/Application Support/com.nanvon.ByteTrace/usage.sqlite3` — inspectable with any SQLite client
- Nothing is uploaded; no stats ever leave your machine
- No packet inspection, no HTTPS decryption, and no request bodies

> [!TIP]
> Released `ByteTrace.app` binaries are ad-hoc signed and not notarized by Apple; if that concerns you, review the code and [build from source](#-building-from-source) instead.

## 🔧 Building from Source

Requires macOS 14 or later and Xcode with the Swift 6 toolchain.

**Day-to-day development**: `swift build` to build, `swift test` to run tests, `swift run ByteTraceApp` to run in development mode.

**Release packaging**:

```bash
./Scripts/package_app.sh
```

Artifacts land under `dist/`: `ByteTrace.app`, `ByteTrace.dmg`, and `ByteTrace.zip`, ad-hoc signed by default.

> [!WARNING]
> `swift run ByteTraceApp` runs the bare executable, which cannot read `Packaging/Info.plist` — menu-bar-only behavior (`LSUIElement`), the app icon, and other plist-driven behaviors will not apply. To validate the menu bar experience, use the output of `./Scripts/package_app.sh`.

## 🙏 Acknowledgments

- [`nettop`](https://keith.github.io/xcode-man-pages/nettop.1.html) — the network statistics command built into macOS and the only source for ByteTrace application totals
- [Mihomo](https://github.com/MetaCubeX/mihomo) — optional active-connection snapshots for website traffic
- [Public Suffix List](https://publicsuffix.org/) — offline registrable-domain rules; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for licensing

## 📄 License

[MIT](LICENSE)
