import Foundation
import XCTest

@testable import ByteTraceCore

final class ProcessLauncherTests: XCTestCase {
    func testLauncherSkipsShellsAndUsesNearestTool() {
        let identity = ProcessIdentity(
            pid: 300,
            nettopProcessName: "curl",
            executablePath: "/usr/bin/curl",
            ancestors: [
                ProcessAncestor(pid: 299, executablePath: "/bin/zsh"),
                ProcessAncestor(pid: 298, executablePath: "/Users/me/.local/share/claude/versions/2.1.314"),
                ProcessAncestor(pid: 297, executablePath: "/bin/zsh"),
                ProcessAncestor(
                    pid: 200,
                    executablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
                    bundleID: "com.mitchellh.ghostty",
                    bundlePath: "/Applications/Ghostty.app",
                    displayName: "Ghostty"
                )
            ]
        )
        let attributed = ProcessAttributor().attribute(identity)
        XCTAssertEqual(attributed.launcherName, "claude")
        XCTAssertEqual(attributed.appKey, "exec:/usr/bin/curl")
    }

    func testLauncherUsesAppNameAndIgnoresSameExecutableAndLaunchd() {
        let viaTerminal = ProcessIdentity(
            pid: 400,
            nettopProcessName: "node",
            executablePath: "/Users/me/.local/share/mise/installs/node/22.1.0/bin/node",
            ancestors: [
                ProcessAncestor(pid: 399, executablePath: "/Users/me/.local/share/mise/installs/node/22.1.0/bin/node"),
                ProcessAncestor(pid: 398, executablePath: "/usr/bin/login"),
                ProcessAncestor(
                    pid: 397,
                    executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                    bundleID: "com.apple.Terminal",
                    bundlePath: "/System/Applications/Utilities/Terminal.app",
                    displayName: "终端"
                )
            ]
        )
        XCTAssertEqual(ProcessAttributor.launcherName(for: viaTerminal), "终端")

        let daemon = ProcessIdentity(
            pid: 500,
            nettopProcessName: "nsurlsessiond",
            executablePath: "/usr/libexec/nsurlsessiond",
            ancestors: [ProcessAncestor(pid: 1, executablePath: "/sbin/launchd")]
        )
        XCTAssertNil(ProcessAttributor().attribute(daemon).launcherName)
    }

    func testAppHelpersHaveNoLauncher() {
        let identity = ProcessIdentity(
            pid: 600,
            nettopProcessName: "Google Chrome H",
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
            ancestors: [
                ProcessAncestor(
                    pid: 599,
                    executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                    bundleID: "com.google.Chrome",
                    bundlePath: "/Applications/Google Chrome.app",
                    displayName: "Google Chrome"
                )
            ]
        )
        XCTAssertNil(ProcessAttributor().attribute(identity).launcherName)
    }

    func testSystemProcessDescriptions() {
        XCTAssertEqual(
            SystemProcessDescriptions.description(forExecutablePath: "/usr/sbin/mDNSResponder"),
            "局域网/Bonjour：DNS 解析与局域网设备发现"
        )
        XCTAssertNotNil(SystemProcessDescriptions.description(forExecutablePath: "/usr/libexec/nsurlsessiond"))
        XCTAssertNil(SystemProcessDescriptions.description(forExecutablePath: "/usr/bin/curl"))
        XCTAssertNil(SystemProcessDescriptions.description(forExecutablePath: nil))
    }

    func testStoreKeepsLatestLauncherPerApp() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        try store.recordLaunchers(["exec:/usr/bin/curl": "终端"])
        try store.recordLaunchers(["exec:/usr/bin/curl": "claude", "exec:/opt/x": "Raycast"])
        XCTAssertEqual(try store.launcherNames(), ["exec:/usr/bin/curl": "claude", "exec:/opt/x": "Raycast"])
        try store.clearAll()
        XCTAssertEqual(try store.launcherNames(), [:])
    }
}
