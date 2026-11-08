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

    private let ghostty = ProcessAncestor(
        pid: 500,
        executablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
        bundleID: "com.mitchellh.ghostty",
        bundlePath: "/Applications/Ghostty.app",
        displayName: "Ghostty"
    )
    private let shell = ProcessAncestor(pid: 501, executablePath: "/bin/zsh")

    func testCLILaunchedByApplicationIsItsProgram() {
        let attributed = ProcessAttributor().attribute(
            ProcessIdentity(
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
        )

        XCTAssertEqual(attributed.appKey, "bundle:com.example.browser")
        XCTAssertEqual(attributed.displayName, "Browser")
        XCTAssertEqual(attributed.category, .userApp)
        XCTAssertEqual(attributed.program?.key, "command:curl")
        XCTAssertEqual(attributed.program?.displayName, "curl")
        XCTAssertEqual(attributed.program?.category, .unclassified)
    }

    func testTerminalIsTheHostAndShellsAreSkipped() {
        let magpie = ProcessAncestor(
            pid: 49,
            executablePath: "/Applications/magpie.app/Contents/MacOS/magpie",
            bundleID: "com.yetone.magpie",
            bundlePath: "/Applications/magpie.app",
            displayName: "magpie"
        )
        let login = ProcessAncestor(pid: 502, executablePath: "/usr/bin/login")
        let attributor = ProcessAttributor()
        func mise(_ ancestors: [ProcessAncestor]) -> AttributedProcess {
            attributor.attribute(
                ProcessIdentity(pid: 51, nettopProcessName: "mise", executablePath: "/Users/u/.local/bin/mise", ancestors: ancestors)
            )
        }

        let viaApp = mise([shell, magpie])
        let viaTerminal = mise([shell, login, ghostty])

        XCTAssertEqual(viaApp.appKey, "bundle:com.yetone.magpie")
        XCTAssertEqual(viaApp.program?.key, "command:mise")
        XCTAssertEqual(viaTerminal.appKey, "bundle:com.mitchellh.ghostty")
        XCTAssertEqual(viaTerminal.displayName, "Ghostty")
        XCTAssertEqual(viaTerminal.program?.key, "command:mise")
    }

    func testEditorHostsBothExtensionsAndIntegratedTerminalCommands() {
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
                ancestors: [shell, pluginHost, editor]
            )
        )

        XCTAssertEqual(extensionProcess.appKey, "bundle:com.microsoft.VSCode")
        XCTAssertEqual(extensionProcess.displayName, "Code")
        XCTAssertEqual(extensionProcess.program?.key, "exec:/Users/u/.marscode/ai-chat/binary/*/modules/ai-agent/ai-agent")
        XCTAssertEqual(terminalCommand.appKey, "bundle:com.microsoft.VSCode")
        XCTAssertEqual(terminalCommand.program?.key, "command:claude")
    }

    func testApplicationSupportBundleIsAProgramOfTheLaunchingApplication() {
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
                ancestors: [shell, claudeCode, disclaimer, claude]
            )
        )

        XCTAssertEqual(agent.appKey, "bundle:com.anthropic.claudefordesktop")
        XCTAssertEqual(agent.displayName, "Claude")
        XCTAssertEqual(agent.program?.key, "command:claude")
        // Claude Code 调起的工具算 Claude Code 这个程序。
        XCTAssertEqual(tool.appKey, "bundle:com.anthropic.claudefordesktop")
        XCTAssertEqual(tool.program?.key, "command:claude")
    }

    func testToolInHostDataDirectoryCountsAsTheApplicationItself() {
        let raycast = ProcessAncestor(
            pid: 75,
            executablePath: "/Applications/Raycast.app/Contents/MacOS/Raycast",
            bundleID: "com.raycast.macos",
            bundlePath: "/Applications/Raycast.app",
            displayName: "Raycast"
        )
        let attributed = ProcessAttributor().attribute(
            ProcessIdentity(
                pid: 76,
                nettopProcessName: "node",
                executablePath: "/Users/u/Library/Application Support/com.raycast.macos/node/runtime/node-v22-darwin-arm64/bin/node",
                ancestors: [raycast]
            )
        )

        XCTAssertEqual(attributed.appKey, "bundle:com.raycast.macos")
        XCTAssertNil(attributed.program)
    }

    func testXcodeToolchainIsAProgramNotXcode() {
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

        let attributor = ProcessAttributor()
        let python = attributor.attribute(
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
        let swift = attributor.attribute(
            ProcessIdentity(
                pid: 81,
                nettopProcessName: "swift",
                executablePath: "/Applications/Xcode-test.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
                ancestors: [shell, ghostty]
            )
        )

        XCTAssertEqual(python.appKey, VirtualHost.otherKey)
        XCTAssertEqual(python.program?.key, "command:python")
        XCTAssertEqual(swift.appKey, "bundle:com.mitchellh.ghostty")
        XCTAssertEqual(swift.program?.key, "command:swift")
    }

    func testInterpreterIsNamedByItsScript() {
        let brew = ProcessAncestor(
            pid: 85,
            executablePath: "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/3.4.5/bin/ruby",
            scriptName: "brew"
        )
        let attributed = ProcessAttributor().attribute(
            ProcessIdentity(
                pid: 86,
                nettopProcessName: "curl",
                executablePath: "/usr/bin/curl",
                ancestors: [brew, shell, ghostty]
            )
        )
        let node = ProcessAttributor().attribute(
            ProcessIdentity(
                pid: 87,
                nettopProcessName: "node",
                executablePath: "/Users/u/.local/share/mise/installs/node/24.0.0/bin/node",
                ancestors: [shell, ghostty],
                scriptName: "figma-developer-mcp"
            )
        )

        XCTAssertEqual(attributed.program?.key, "command:brew")
        XCTAssertEqual(node.program?.key, "command:figma-developer-mcp")
        XCTAssertEqual(node.program?.displayName, "figma-developer-mcp")
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
        XCTAssertNil(resolved.program)
        XCTAssertEqual(exited.appKey, "bundle:com.hnc.Discord")
        XCTAssertEqual(exited.category, .userApp)
        XCTAssertEqual(exited.pid, 91)
        XCTAssertEqual(unknown.appKey, VirtualHost.otherKey)
        XCTAssertEqual(unknown.program?.key, "process:never-seen")
    }

    func testVersionedExecutablesShareOneProgramAndStableName() {
        let attributor = ProcessAttributor()
        let first = attributor.attribute(
            ProcessIdentity(pid: 30, nettopProcessName: "2.1.300", executablePath: "/Users/u/.local/share/claude/versions/2.1.300")
        )
        let second = attributor.attribute(
            ProcessIdentity(pid: 31, nettopProcessName: "2.1.314", executablePath: "/Users/u/.local/share/claude/versions/2.1.314")
        )
        let node = attributor.attribute(
            ProcessIdentity(
                pid: 32,
                nettopProcessName: "npm exec figma-developer-mcp --stdio",
                executablePath: "/Users/u/.local/share/mise/installs/node/22.22.0/bin/node"
            )
        )

        XCTAssertEqual(first.appKey, VirtualHost.otherKey)
        XCTAssertEqual(first.program?.key, "command:claude")
        XCTAssertEqual(second.program?.key, first.program?.key)
        XCTAssertEqual(first.program?.displayName, "claude")
        XCTAssertEqual(node.program?.key, "command:node")
        XCTAssertEqual(node.program?.displayName, "node")
    }

    func testSystemDaemonsGoToTheSystemHost() {
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

        XCTAssertEqual(system.appKey, VirtualHost.otherKey)
        XCTAssertEqual(system.category, .unclassified)
        XCTAssertEqual(system.program?.key, "command:curl")
        XCTAssertEqual(homebrew.program?.key, system.program?.key)
        XCTAssertEqual(system.program?.category, .unclassified)
        XCTAssertEqual(daemon.appKey, VirtualHost.systemKey)
        XCTAssertEqual(daemon.displayName, "macOS 系统")
        XCTAssertEqual(daemon.category, .systemProcess)
        XCTAssertEqual(daemon.program?.key, "command:mDNSResponder")
        XCTAssertEqual(daemon.program?.category, .systemProcess)
    }

    func testTruncatedProcessNameUsesExecutableFileName() {
        let attributed = ProcessAttributor().attribute(
            ProcessIdentity(
                pid: 33,
                nettopProcessName: "SafariSearchUpl",
                executablePath: "/System/Library/ExtensionKit/Extensions/SafariSearchUploadWorker.appex/Contents/MacOS/SafariSearchUploadWorker"
            )
        )

        XCTAssertEqual(attributed.appKey, VirtualHost.systemKey)
        XCTAssertEqual(attributed.program?.displayName, "SafariSearchUploadWorker")
        XCTAssertEqual(attributed.program?.category, .systemProcess)
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

    func testUnknownProgramKeyIsDeterministic() {
        let identity = ProcessIdentity(pid: nil, nettopProcessName: "")
        let attributor = ProcessAttributor()

        let first = attributor.attribute(identity)
        let second = attributor.attribute(identity)

        XCTAssertEqual(first.appKey, VirtualHost.otherKey)
        XCTAssertTrue(first.program?.key.hasPrefix("unknown:") == true)
        XCTAssertEqual(first.program?.key, second.program?.key)
        XCTAssertEqual(first.category, .unclassified)
    }

    func testNonAppBundlePathPollutionDoesNotProduceAppKey() {
        // NSRunningApplication 偶发把非 app 进程的可执行文件路径自身当成 bundleURL，
        // 此时 bundlePath == executablePath 且无 .app 后缀，不能把它当成应用
        // （曾导致 node 出现 app:/…/bin/node 分裂记录）。
        let identity = ProcessIdentity(
            pid: 40,
            processStartTime: Date(timeIntervalSince1970: 100),
            nettopProcessName: "node.40",
            executablePath: "/Users/nanvon/.local/share/fnm/node-versions/v24.17.0/installation/bin/node",
            bundlePath: "/Users/nanvon/.local/share/fnm/node-versions/v24.17.0/installation/bin/node"
        )

        let attributed = ProcessAttributor().attribute(identity)

        XCTAssertEqual(attributed.appKey, VirtualHost.otherKey)
        XCTAssertEqual(attributed.program?.key, "command:node")
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
            bundleID: "com.example.first",
            bundlePath: "/Applications/First.app"
        )
        let second = ProcessIdentity(
            pid: 2,
            processStartTime: Date(timeIntervalSince1970: 100),
            nettopProcessName: "second.2",
            bundleID: "com.example.second",
            bundlePath: "/Applications/Second.app"
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

    func testXPCServiceCountsAsTheResponsibleApplicationItself() {
        let raycast = ContainingApplication(
            bundleID: "com.raycast.macos",
            bundlePath: "/Applications/Raycast.app",
            displayName: "Raycast",
            executablePath: "/Applications/Raycast.app/Contents/MacOS/Raycast"
        )
        let attributed = ProcessAttributor().attribute(
            ProcessIdentity(
                pid: 700,
                nettopProcessName: "com.apple.WebKi",
                executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
                bundleID: "com.apple.WebKit.Networking",
                displayName: "Raycast Networking",
                ancestors: [ProcessAncestor(pid: 1, executablePath: "/sbin/launchd")],
                responsibleApplication: raycast
            )
        )

        XCTAssertEqual(attributed.appKey, "bundle:com.raycast.macos")
        XCTAssertEqual(attributed.displayName, "Raycast")
        XCTAssertEqual(attributed.category, .userApp)
        XCTAssertEqual(attributed.executablePath, "/Applications/Raycast.app/Contents/MacOS/Raycast")
        XCTAssertNil(attributed.program)
    }

    func testAdoptedChildUsesResponsibleApplicationAndKeepsItsProgram() {
        let attributed = ProcessAttributor().attribute(
            ProcessIdentity(
                pid: 705,
                nettopProcessName: "opencode",
                executablePath: "/Users/u/.opencode/bin/opencode",
                ancestors: [ProcessAncestor(pid: 1, executablePath: "/sbin/launchd")],
                responsibleApplication: ContainingApplication(
                    bundleID: "com.mitchellh.ghostty",
                    bundlePath: "/Applications/Ghostty.app",
                    displayName: "Ghostty"
                )
            )
        )

        XCTAssertEqual(attributed.appKey, "bundle:com.mitchellh.ghostty")
        XCTAssertEqual(attributed.program?.key, "command:opencode")
    }

    func testAuxiliaryApplicationIsAProgramOfItsMainApplication() {
        XCTAssertEqual(ProcessAttributor.auxiliaryApplicationHosts["com.google.GoogleUpdater"], "com.google.Chrome")
        let support = "/Users/u/Library/Application Support"
        let attributed = ProcessAttributor().attribute(
            ProcessIdentity(
                pid: 710,
                nettopProcessName: "EgoUpdater",
                executablePath: "\(support)/Citro Labs/EgoUpdater/0.6/EgoUpdater.app/Contents/MacOS/EgoUpdater",
                bundleID: "com.citrolabs.EgoUpdater",
                bundlePath: "\(support)/Citro Labs/EgoUpdater/0.6/EgoUpdater.app",
                displayName: "EgoUpdater",
                delegatingApplication: ContainingApplication(
                    bundleID: "com.citrolabs.ego.lite",
                    bundlePath: "/Applications/ego lite.app",
                    displayName: "ego lite"
                )
            )
        )

        XCTAssertEqual(attributed.appKey, "bundle:com.citrolabs.ego.lite")
        XCTAssertEqual(attributed.displayName, "ego lite")
        XCTAssertEqual(attributed.category, .userApp)
        XCTAssertEqual(attributed.program?.key, "bundle:com.citrolabs.EgoUpdater")
        XCTAssertEqual(attributed.program?.displayName, "EgoUpdater")
    }

    func testProgramIsTheOutermostToolBelowTheHost() {
        let opencode = ProcessAncestor(pid: 801, executablePath: "/Users/u/.opencode/bin/opencode")
        let topgrade = ProcessAncestor(pid: 802, executablePath: "/opt/homebrew/Cellar/topgrade/16.0/bin/topgrade")
        let tmux = ProcessAncestor(pid: 803, executablePath: "/opt/homebrew/bin/tmux")
        let attributor = ProcessAttributor()
        func curl(_ ancestors: [ProcessAncestor]) -> AttributedProcess {
            attributor.attribute(
                ProcessIdentity(pid: 810, nettopProcessName: "curl", executablePath: "/usr/bin/curl", ancestors: ancestors)
            )
        }

        let viaOpencode = curl([shell, opencode, shell, ghostty])
        XCTAssertEqual(viaOpencode.appKey, "bundle:com.mitchellh.ghostty")
        XCTAssertEqual(viaOpencode.program?.key, "command:opencode")
        XCTAssertEqual(viaOpencode.program?.executablePath, "/Users/u/.opencode/bin/opencode")
        XCTAssertEqual(curl([opencode, topgrade, shell, ghostty]).program?.key, "command:topgrade")
        // 终端里直接运行（含经过 tmux）的命令是它自己。
        XCTAssertEqual(curl([shell, ghostty]).program?.key, "command:curl")
        XCTAssertEqual(curl([shell, tmux, shell, ghostty]).program?.key, "command:curl")
    }

    func testGitHelperCountsAsGit() {
        let attributed = ProcessAttributor().attribute(
            ProcessIdentity(
                pid: 820,
                nettopProcessName: "git-remote-http",
                executablePath: "/opt/homebrew/Cellar/git/2.56.0/libexec/git-core/git-remote-http",
                ancestors: [
                    ProcessAncestor(pid: 819, executablePath: "/opt/homebrew/Cellar/git/2.56.0/bin/git"),
                    shell,
                    ghostty
                ]
            )
        )

        XCTAssertEqual(attributed.appKey, "bundle:com.mitchellh.ghostty")
        XCTAssertEqual(attributed.program?.key, "command:git")
        XCTAssertEqual(attributed.program?.displayName, "git")
    }

    func testSeededNamesSurviveRestartAndUnrelatedProxyDetection() {
        let cache = ProcessAttributionCache()
        let gh = AttributedProgram(
            key: "command:gh",
            displayName: "gh",
            category: .unclassified,
            executablePath: "/opt/homebrew/Cellar/gh/2.0/bin/gh"
        )
        cache.seed([
            RememberedProcessAttribution(
                processName: "gh",
                appKey: "bundle:com.mitchellh.ghostty",
                displayName: "Ghostty",
                category: .userApp,
                bundleID: "com.mitchellh.ghostty",
                bundlePath: "/Applications/Ghostty.app",
                executablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
                program: gh
            )
        ])
        cache.registerDetectedProxy(executablePath: "/Users/u/Library/Application Support/clashbar/core/mihomo")

        let exited = cache.attribute(ProcessIdentity(pid: 830, nettopProcessName: "gh"))
        XCTAssertEqual(exited.appKey, "bundle:com.mitchellh.ghostty")
        XCTAssertEqual(exited.pid, 830)
        XCTAssertEqual(exited.program, gh)
    }
}
