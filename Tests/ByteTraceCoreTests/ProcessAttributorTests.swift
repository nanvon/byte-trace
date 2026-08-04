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
