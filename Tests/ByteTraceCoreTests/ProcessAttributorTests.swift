import XCTest

@testable import ByteTraceCore

final class ProcessAttributorTests: XCTestCase {
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

    func testGenericCLIIsNotMergedWithParentApplication() {
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

        XCTAssertEqual(attributed.appKey, "exec:/usr/bin/curl")
        XCTAssertNil(attributed.bundleID)
        XCTAssertEqual(attributed.category, .systemProcess)
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

    func testUnknownKeyIsDeterministic() {
        let identity = ProcessIdentity(pid: nil, nettopProcessName: "")
        let attributor = ProcessAttributor()

        let first = attributor.attribute(identity)
        let second = attributor.attribute(identity)

        XCTAssertTrue(first.appKey.hasPrefix("unknown:"))
        XCTAssertEqual(first.appKey, second.appKey)
        XCTAssertEqual(first.category, .unclassified)
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
}
