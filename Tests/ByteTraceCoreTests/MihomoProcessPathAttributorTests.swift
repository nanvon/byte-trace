import Foundation
import XCTest
@testable import ByteTraceCore

final class MihomoProcessPathAttributorTests: XCTestCase {
    func testMissingOrRelativePathUsesUnknownSentinel() {
        let attributor = MihomoProcessPathAttributor()
        XCTAssertEqual(attributor.attribute(processPath: nil).appKey, "mihomo:unknown-process")
        XCTAssertEqual(attributor.attribute(processPath: "node").appKey, "mihomo:unknown-process")
    }

    func testCLIPathUsesExistingExecAttribution() {
        let attributed = MihomoProcessPathAttributor().attribute(processPath: "/usr/bin/curl")
        XCTAssertEqual(attributed.appKey, "exec:/usr/bin/curl")
        XCTAssertEqual(attributed.category, .systemProcess)
    }

    func testNestedHelperUsesOutermostApplicationBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ByteTrace-MihomoAttribution-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("Browser.app")
        let helperExecutable = app
            .appendingPathComponent("Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper")
        try FileManager.default.createDirectory(
            at: helperExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: helperExecutable)
        try writeInfoPlist(
            at: app.appendingPathComponent("Contents/Info.plist"),
            bundleID: "com.example.browser",
            name: "Browser"
        )
        try writeInfoPlist(
            at: app.appendingPathComponent("Contents/Frameworks/Browser Helper.app/Contents/Info.plist"),
            bundleID: "com.example.browser.helper",
            name: "Browser Helper"
        )

        let attributed = MihomoProcessPathAttributor().attribute(
            processPath: helperExecutable.path
        )
        XCTAssertEqual(attributed.appKey, "bundle:com.example.browser")
        XCTAssertEqual(attributed.bundlePath, app.path)
        XCTAssertEqual(attributed.displayName, "Browser")
    }

    private func writeInfoPlist(at url: URL, bundleID: String, name: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleID,
                "CFBundleName": name,
                "CFBundleExecutable": name
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }
}
