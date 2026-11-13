import XCTest

@testable import ByteTraceCore

final class DomainNameTests: XCTestCase {
    func testNormalizesHostNames() {
        let examples = [
            " www.GitHub.com. ": "github.com",
            "rr3---sn-abc.googlevideo.com": "googlevideo.com",
            "news.sina.com.cn": "sina.com.cn",
            "com.cn": "com.cn",
            "localhost": "localhost",
            "xn--fiq228c.com": "xn--fiq228c.com"
        ]
        for (host, expected) in examples {
            XCTAssertEqual(DomainName.registrable(host), expected)
        }
    }

    func testRejectsIPAddressesAndMalformedHosts() {
        for host in ["1.2.3.4", "001.002.003.004", "::1", "[2001:db8::1]", "", " ", "a..example.com", "example.com/path"] {
            XCTAssertNil(DomainName.registrable(host))
        }
    }
}
