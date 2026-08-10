import XCTest
@testable import ByteTraceCore

final class PublicSuffixListTests: XCTestCase {
    private let list = PublicSuffixList(
        list: """
        com
        uk
        co.uk
        *.ck
        !www.ck
        github.io
        """
    )

    func testOrdinaryAndMultiLabelPublicSuffixes() {
        XCTAssertEqual(list.registrableDomain(for: "api.github.com"), "github.com")
        XCTAssertEqual(list.registrableDomain(for: "a.example.co.uk"), "example.co.uk")
    }

    func testPrivateWildcardAndExceptionRules() {
        XCTAssertEqual(list.registrableDomain(for: "a.user.github.io"), "user.github.io")
        XCTAssertEqual(list.registrableDomain(for: "a.test.ck"), "a.test.ck")
        XCTAssertEqual(list.registrableDomain(for: "a.www.ck"), "www.ck")
    }

    func testNormalizationAndUnidentifiedHosts() {
        XCTAssertEqual(list.registrableDomain(for: " API.GITHUB.COM. "), "github.com")
        XCTAssertNil(list.registrableDomain(for: "127.0.0.1"))
        XCTAssertNil(list.registrableDomain(for: "::1"))
        XCTAssertNil(list.registrableDomain(for: "localhost"))
        XCTAssertNil(list.registrableDomain(for: "bad host.example"))
        XCTAssertNil(list.registrableDomain(for: "-bad.example"))
        XCTAssertNil(list.registrableDomain(for: "bad_.example"))
        XCTAssertNil(list.registrableDomain(for: nil))
        XCTAssertEqual(list.siteKey(for: "127.0.0.1"), PublicSuffixList.unidentifiedSiteKey)
    }

    func testBundledListIncludesCurrentPublicAndPrivateRules() throws {
        let bundled = try PublicSuffixList.bundled()
        XCTAssertEqual(bundled.registrableDomain(for: "api.github.com"), "github.com")
        XCTAssertEqual(bundled.registrableDomain(for: "a.user.github.io"), "user.github.io")
    }
}
