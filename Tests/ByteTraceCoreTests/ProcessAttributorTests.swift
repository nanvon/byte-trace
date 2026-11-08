import XCTest

@testable import ByteTraceCore

final class ProcessAttributorTests: XCTestCase {
    func testResolverKeepsRecentIdentityAfterProcessExits() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.1"]
        try process.run()

        let resolver = SystemProcessIdentityResolver(cacheTTL: 15)
        let token = NettopProcessToken(rawValue: "sleep.\(process.processIdentifier)")
        let beforeExit = resolver.resolve(token)
        process.waitUntilExit()
        let afterExit = resolver.resolve(token)

        XCTAssertNotNil(beforeExit.processStartTime)
        XCTAssertEqual(afterExit, beforeExit)
    }

    func testProcessTokenUsesTheLastNumericSuffixAsPID() {
        let token = NettopProcessToken(rawValue: "GitHub Desktop .2168")

        XCTAssertEqual(token.processName, "GitHub Desktop ")
        XCTAssertEqual(token.pid, 2168)
    }

    func testProcessTokenKeepsNamesWithDotsAndRejectsNonNumericSuffixes() {
        let dotted = NettopProcessToken(rawValue: "Browser.Helper.42")
        let invalid = NettopProcessToken(rawValue: "git-remote-http")

        XCTAssertEqual(dotted.processName, "Browser.Helper")
        XCTAssertEqual(dotted.pid, 42)
        XCTAssertEqual(invalid.processName, "git-remote-http")
        XCTAssertNil(invalid.pid)
    }

    func testHelperUsesOuterAppBundleWhenExecutableIsInsideContents() {
        let identity = ProcessIdentity(
            pid: 10,
            processStartTime: Date(timeIntervalSince1970: 100),
            nettopProcessName: "Browser Helper.10",
            executablePath: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper",
            bundleID: "com.example.browser.helper",
            bundlePath: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app",
            displayName: "Browser Helper",
            ancestors: [
                ProcessAncestor(
                    pid: 9,
                    processStartTime: Date(timeIntervalSince1970: 99),
                    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
                    bundleID: "com.example.browser",
                    bundlePath: "/Applications/Browser.app",
                    displayName: "Browser"
                )
            ]
        )

        let attributed = ProcessAttributor().attribute(identity)

        XCTAssertEqual(attributed.appKey, "bundle:com.example.browser")
        XCTAssertEqual(attributed.bundleID, "com.example.browser")
        XCTAssertEqual(attributed.bundlePath, "/Applications/Browser.app")
        XCTAssertEqual(attributed.displayName, "Browser")
        XCTAssertEqual(attributed.category, .userApp)
    }

    func testCLILaunchedByApplicationIsMergedIntoIt() {
        let identity = ProcessIdentity(
            pid: 20,
            nettopProcessName: "curl",
            executablePath: "/usr/bin/curl",
            ancestors: [
                ProcessAncestor(
                    pid: 19,
                    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
                    bundleID: "com.example.browser",
                    bundlePath: "/Applications/Browser.app",
                    displayName: "Browser"
                )
            ]
        )

        let attributed = ProcessAttributor().attribute(identity)

        XCTAssertEqual(attributed.appKey, "bundle:com.example.browser")
        XCTAssertEqual(attributed.displayName, "Browser")
        XCTAssertEqual(attributed.category, .userApp)
        XCTAssertNil(attributed.launcherName)
    }

    func testCLILaunchedThroughShellByApplicationIsMergedButTerminalIsNot() {
        let shell = ProcessAncestor(pid: 50, executablePath: "/bin/zsh")
        let magpie = ProcessAncestor(
            pid: 49,
            executablePath: "/Applications/magpie.app/Contents/MacOS/magpie",
            bundleID: "com.yetone.magpie",
            bundlePath: "/Applications/magpie.app",
            displayName: "magpie"
        )
        let ghostty = ProcessAncestor(
            pid: 48,
            executablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            bundleID: "com.mitchellh.ghostty",
            bundlePath: "/Applications/Ghostty.app",
            displayName: "Ghostty"
        )
        let attributor = ProcessAttributor()

        let viaApp = attributor.attribute(
            ProcessIdentity(
                pid: 51,
                nettopProcessName: "mise",
                executablePath: "/Users/u/.local/bin/mise",
                ancestors: [shell, magpie]
            )
        )
        let viaTerminal = attributor.attribute(
            ProcessIdentity(
                pid: 52,
                nettopProcessName: "mise",
                executablePath: "/Users/u/.local/bin/mise",
                ancestors: [shell, ghostty]
            )
        )

        XCTAssertEqual(viaApp.appKey, "bundle:com.yetone.magpie")
        XCTAssertEqual(viaApp.category, .userApp)
        XCTAssertEqual(viaTerminal.appKey, "command:mise")
        XCTAssertEqual(viaTerminal.category, .unclassified)
    }

    func testEditorKeepsIntegratedTerminalCommandsButMergesExtensions() {
        let editor = ProcessAncestor(
            pid: 60,
            executablePath: "/Applications/Visual Studio Code.app/Contents/MacOS/Code",
            bundleID: "com.microsoft.VSCode",
            bundlePath: "/Applications/Visual Studio Code.app",
            displayName: "Code"
        )
        let pluginHost = ProcessAncestor(
            pid: 61,
            executablePath: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
            bundleID: "com.microsoft.VSCode.helper",
            bundlePath: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app",
            displayName: "Code Helper (Plugin)"
        )
        let attributor = ProcessAttributor()

        let extensionProcess = attributor.attribute(
            ProcessIdentity(
                pid: 62,
                nettopProcessName: "ai-agent",
                executablePath: "/Users/u/.marscode/ai-chat/binary/1.0/modules/ai-agent/ai-agent",
                ancestors: [pluginHost, editor]
            )
        )
        let terminalCommand = attributor.attribute(
            ProcessIdentity(
                pid: 63,
                nettopProcessName: "claude",
                executablePath: "/Users/u/.local/share/claude/versions/2.1.314",
                ancestors: [ProcessAncestor(pid: 64, executablePath: "/bin/zsh"), pluginHost, editor]
            )
        )

        XCTAssertEqual(extensionProcess.appKey, "bundle:com.microsoft.VSCode")
        XCTAssertEqual(extensionProcess.displayName, "Code")
        XCTAssertEqual(terminalCommand.appKey, "exec:/Users/u/.local/share/claude/versions/*")
    }

    func testApplicationSupportBundleIsMergedIntoLaunchingApplication() {
        let claude = ProcessAncestor(
            pid: 70,
            executablePath: "/Applications/Claude.app/Contents/MacOS/Claude",
            bundleID: "com.anthropic.claudefordesktop",
            bundlePath: "/Applications/Claude.app",
            displayName: "Claude"
        )
        let disclaimer = ProcessAncestor(
            pid: 71,
            executablePath: "/Applications/Claude.app/Contents/Helpers/disclaimer",
            bundleID: "com.anthropic.claudefordesktop",
            bundlePath: "/Applications/Claude.app",
            displayName: "Claude"
        )
        let claudeCodePath = "/Users/u/Library/Application Support/Claude/claude-code/2.1.317/abc/claude.app"
        let claudeCode = ProcessAncestor(
            pid: 72,
            executablePath: claudeCodePath + "/Contents/MacOS/claude",
            bundleID: "com.anthropic.claude-code",
            bundlePath: claudeCodePath,
            displayName: "Claude Code"
        )
        let attributor = ProcessAttributor()

        let agent = attributor.attribute(
            ProcessIdentity(
                pid: 72,
                nettopProcessName: "claude",
                executablePath: claudeCodePath + "/Contents/MacOS/claude",
                bundleID: "com.anthropic.claude-code",
                bundlePath: claudeCodePath,
                displayName: "Claude Code",
                ancestors: [disclaimer, claude]
            )
        )
        let tool = attributor.attribute(
            ProcessIdentity(
                pid: 73,
                nettopProcessName: "gh",
                executablePath: "/opt/homebrew/Cellar/gh/2.80.0/bin/gh",
                ancestors: [ProcessAncestor(pid: 74, executablePath: "/bin/zsh"), claudeCode, disclaimer, claude]
            )
        )

        XCTAssertEqual(agent.appKey, "bundle:com.anthropic.claudefordesktop")
        XCTAssertEqual(agent.displayName, "Claude")
        XCTAssertEqual(tool.appKey, "bundle:com.anthropic.claudefordesktop")
    }

    func testNestedAppUsesOutermostApplicationWithoutParent() {
        let pythonApp = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app"
        let executable = pythonApp + "/Contents/MacOS/Python"
        let containing = SystemProcessIdentityResolver.containingApplication(
            for: executable,
            ownBundlePath: pythonApp
        )
        XCTAssertEqual(containing?.bundlePath, "/Applications/Xcode.app")
        XCTAssertNil(
            SystemProcessIdentityResolver.containingApplication(
                for: "/Applications/Xcode.app/Contents/MacOS/Xcode",
                ownBundlePath: "/Applications/Xcode.app"
            )
        )

        let attributed = ProcessAttributor().attribute(
            ProcessIdentity(
                pid: 80,
                nettopProcessName: "Python",
                executablePath: executable,
                bundleID: "com.apple.python3",
                bundlePath: pythonApp,
                displayName: "Python",
                containingApplication: ContainingApplication(
                    bundleID: "com.apple.dt.Xcode",
                    bundlePath: "/Applications/Xcode.app",
                    displayName: "Xcode"
                )
            )
        )

        XCTAssertEqual(attributed.appKey, "bundle:com.apple.dt.Xcode")
        XCTAssertEqual(attributed.displayName, "Xcode")
        XCTAssertEqual(attributed.category, .userApp)
    }

    func testExitedProcessReusesLastAttributionWithSameName() {
        let cache = ProcessAttributionCache()
        let resolved = cache.attribute(
            ProcessIdentity(
                pid: 90,
                processStartTime: Date(timeIntervalSince1970: 100),
                nettopProcessName: "Discord Helper",
                executablePath: "/Applications/Discord.app/Contents/Frameworks/Discord Helper.app/Contents/MacOS/Discord Helper",
                bundleID: "com.hnc.Discord.helper",
                bundlePath: "/Applications/Discord.app/Contents/Frameworks/Discord Helper.app",
                ancestors: [
                    ProcessAncestor(
                        pid: 89,
                        executablePath: "/Applications/Discord.app/Contents/MacOS/Discord",
                        bundleID: "com.hnc.Discord",
                        bundlePath: "/Applications/Discord.app",
                        displayName: "Discord"
                    )
                ]
            )
        )
        let exited = cache.attribute(ProcessIdentity(pid: 91, nettopProcessName: "Discord Helper"))
        let unknown = cache.attribute(ProcessIdentity(pid: 92, nettopProcessName: "never-seen"))

        XCTAssertEqual(resolved.appKey, "bundle:com.hnc.Discord")
        XCTAssertEqual(exited.appKey, "bundle:com.hnc.Discord")
        XCTAssertEqual(exited.category, .userApp)
        XCTAssertEqual(exited.pid, 91)
        XCTAssertEqual(unknown.appKey, "process:never-seen")
    }

    func testVersionedExecutablesShareOneKeyAndStableName() {
        let attributor = ProcessAttributor()
        let first = attributor.attribute(
            ProcessIdentity(
                pid: 30,
                nettopProcessName: "2.1.300",
                executablePath: "/Users/u/.local/share/claude/versions/2.1.300"
            )
        )
        let second = attributor.attribute(
            ProcessIdentity(
                pid: 31,
                nettopProcessName: "2.1.314",
                executablePath: "/Users/u/.local/share/claude/versions/2.1.314"
            )
        )
        let node = attributor.attribute(
            ProcessIdentity(
                pid: 32,
                nettopProcessName: "npm exec figma-developer-mcp --stdio",
                executablePath: "/Users/u/.local/share/mise/installs/node/22.22.0/bin/node"
            )
        )

        XCTAssertEqual(first.appKey, "exec:/Users/u/.local/share/claude/versions/*")
        XCTAssertEqual(second.appKey, first.appKey)
        XCTAssertEqual(first.displayName, "claude")
        XCTAssertEqual(node.appKey, "command:node")
        XCTAssertEqual(node.displayName, "node")
    }

    func testSameCommandFromSystemAndHomebrewSharesOneKey() {
        let attributor = ProcessAttributor()
        let system = attributor.attribute(
            ProcessIdentity(pid: 35, nettopProcessName: "curl", executablePath: "/usr/bin/curl")
        )
        let homebrew = attributor.attribute(
            ProcessIdentity(pid: 36, nettopProcessName: "curl", executablePath: "/opt/homebrew/Cellar/curl/8.23.0/bin/curl")
        )
        let daemon = attributor.attribute(
            ProcessIdentity(pid: 37, nettopProcessName: "mDNSResponder", executablePath: "/usr/sbin/mDNSResponder")
        )

        XCTAssertEqual(system.appKey, "command:curl")
        XCTAssertEqual(homebrew.appKey, system.appKey)
        XCTAssertEqual(system.displayName, "curl")
        XCTAssertEqual(system.category, .unclassified)
        XCTAssertEqual(homebrew.category, .unclassified)
        XCTAssertEqual(daemon.category, .systemProcess)
    }

    func testTruncatedProcessNameUsesExecutableFileName() {
        let attributed = ProcessAttributor().attribute(
            ProcessIdentity(
                pid: 33,
                nettopProcessName: "SafariSearchUpl",
                executablePath: "/System/Library/ExtensionKit/Extensions/SafariSearchUploadWorker.appex/Contents/MacOS/SafariSearchUploadWorker"
            )
        )

        XCTAssertEqual(attributed.displayName, "SafariSearchUploadWorker")
        XCTAssertEqual(attributed.category, .systemProcess)
    }

    func testDetectedProxyExecutableBecomesProxyTransport() {
        let cache = ProcessAttributionCache()
        let identity = ProcessIdentity(
            pid: 34,
            processStartTime: Date(timeIntervalSince1970: 1),
            nettopProcessName: "my-core",
            executablePath: "/opt/proxy/my-core"
        )
        XCTAssertEqual(cache.attribute(identity).category, .unclassified)

        XCTAssertTrue(cache.registerDetectedProxy(executablePath: "/opt/proxy/my-core"))
        XCTAssertFalse(cache.registerDetectedProxy(executablePath: "/opt/proxy/my-core"))
        let attributed = cache.attribute(identity)
        XCTAssertEqual(attributed.category, .proxyTransport)
        XCTAssertEqual(attributed.appKey, "proxy:my-core")
    }

    func testProxyRulesUseExactProcessNames() {
        let classifier = ProxyClassifier(
            rules: [
                ProxyRule(key: "mihomo", displayName: "Mihomo", processNames: ["mihomo"])
            ]
        )
        let attributor = ProcessAttributor(proxyClassifier: classifier)

        let exact = ProcessIdentity(pid: 30, nettopProcessName: "mihomo")
        let similar = ProcessIdentity(pid: 31, nettopProcessName: "mihomo-helper")

        XCTAssertEqual(attributor.attribute(exact).category, .proxyTransport)
        XCTAssertEqual(attributor.attribute(exact).appKey, "proxy:mihomo")
        XCTAssertNotEqual(attributor.attribute(similar).category, .proxyTransport)
    }

    func testCCBarIsClassifiedAsAnApplicationByDefault() {
        let identity = ProcessIdentity(
            pid: 32,
            nettopProcessName: "CCBar",
            bundleID: "com.nanvon.ccbar",
            bundlePath: "/Applications/CCBar.app",
            displayName: "CCBar"
        )

        let attributed = ProcessAttributor().attribute(identity)

        XCTAssertEqual(attributed.appKey, "bundle:com.nanvon.ccbar")
        XCTAssertEqual(attributed.category, .userApp)
        XCTAssertNotEqual(attributed.category, .proxyTransport)
    }

    func testUnknownKeyIsDeterministic() {
        let identity = ProcessIdentity(pid: nil, nettopProcessName: "")
        let attributor = ProcessAttributor()

        let first = attributor.attribute(identity)
        let second = attributor.attribute(identity)

        XCTAssertTrue(first.appKey.hasPrefix("unknown:"))
        XCTAssertEqual(first.appKey, second.appKey)
        XCTAssertEqual(first.category, .unclassified)
    }

    func testNonAppBundlePathPollutionDoesNotProduceAppKey() {
        // NSRunningApplication 偶发把非 app 进程的可执行文件路径自身当成 bundleURL，
        // 此时 bundlePath == executablePath 且无 .app 后缀，必须回退到 exec: 派生，
        // 不能产生 app: 前缀的 appKey（曾导致 node 出现 app:/…/bin/node 分裂记录）。
        let identity = ProcessIdentity(
            pid: 40,
            processStartTime: Date(timeIntervalSince1970: 100),
            nettopProcessName: "node.40",
            executablePath: "/Users/nanvon/.local/share/fnm/node-versions/v24.17.0/installation/bin/node",
            bundlePath: "/Users/nanvon/.local/share/fnm/node-versions/v24.17.0/installation/bin/node"
        )

        let attributed = ProcessAttributor().attribute(identity)

        XCTAssertEqual(
            attributed.appKey,
            "command:node"
        )
        XCTAssertNotEqual(attributed.category, .userApp)
    }

    func testAttributionCacheDoesNotReuseAnEntryAfterPIDReuse() {
        let cache = ProcessAttributionCache()
        let first = ProcessIdentity(
            pid: 42,
            processStartTime: Date(timeIntervalSince1970: 100),
            nettopProcessName: "first.42",
            executablePath: "/Applications/First.app/Contents/MacOS/First",
            bundleID: "com.example.first",
            bundlePath: "/Applications/First.app",
            displayName: "First"
        )
        let second = ProcessIdentity(
            pid: 42,
            processStartTime: Date(timeIntervalSince1970: 200),
            nettopProcessName: "second.42",
            executablePath: "/Applications/Second.app/Contents/MacOS/Second",
            bundleID: "com.example.second",
            bundlePath: "/Applications/Second.app",
            displayName: "Second"
        )

        XCTAssertEqual(cache.attribute(first).appKey, "bundle:com.example.first")
        XCTAssertEqual(cache.attribute(second).appKey, "bundle:com.example.second")
    }

    func testAttributionCacheStaysCorrectAfterEviction() {
        // 上限压到 1，使每次写入都触发淘汰，验证淘汰只影响命中率、不影响归属结果。
        let cache = ProcessAttributionCache(maxCount: 1)
        let first = ProcessIdentity(
            pid: 1,
            processStartTime: Date(timeIntervalSince1970: 100),
            nettopProcessName: "first.1",
            bundleID: "com.example.first"
        )
        let second = ProcessIdentity(
            pid: 2,
            processStartTime: Date(timeIntervalSince1970: 100),
            nettopProcessName: "second.2",
            bundleID: "com.example.second"
        )

        XCTAssertEqual(cache.attribute(first).appKey, "bundle:com.example.first")
        XCTAssertEqual(cache.attribute(second).appKey, "bundle:com.example.second")
        XCTAssertEqual(cache.attribute(first).appKey, "bundle:com.example.first")
    }

    func testResolverReturnsConsistentIdentityForTheSameProcess() {
        let resolver = SystemProcessIdentityResolver()
        let token = NettopProcessToken(rawValue: "probe.\(getpid())")

        let first = resolver.resolve(token)
        let second = resolver.resolve(token)

        XCTAssertEqual(first.pid, getpid())
        XCTAssertEqual(first, second)
    }

    func testResolverStaysCorrectWhenCacheEvicts() {
        // 上限压到 1：解析另一个 pid 会挤掉前一条，再次解析必须重建出相同身份。
        let resolver = SystemProcessIdentityResolver(maxCacheCount: 1)
        let selfToken = NettopProcessToken(rawValue: "probe.\(getpid())")
        let parentToken = NettopProcessToken(rawValue: "parent.\(getppid())")

        let before = resolver.resolve(selfToken)
        _ = resolver.resolve(parentToken)
        let after = resolver.resolve(selfToken)

        XCTAssertEqual(before.pid, getpid())
        XCTAssertEqual(before, after)
    }
}
