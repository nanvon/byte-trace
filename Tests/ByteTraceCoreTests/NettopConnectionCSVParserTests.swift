import XCTest

@testable import ByteTraceCore

final class NettopConnectionCSVParserTests: XCTestCase {
    func testSocketRowsInheritProcessAndSkipBaseline() {
        let input = """
        time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
        10:00,Example.1,,,100,50,0,0,0,,,,,,,,,,,,
        09:59,tcp4 192.168.1.2:50000<->93.184.216.34:443,en0,Established,100,50,0,0,0,10.00 ms,,,,,,,,,,,
        time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
        10:01,Example.1,,,10,20,0,0,0,,,,,,,,,,,,
        10:00,tcp4 192.168.1.2:50000<->93.184.216.34:443,en0,Established,10,20,0,0,0,10.00 ms,,,,,,,,,,,
        """

        var parser = NettopConnectionCSVParser()
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        XCTAssertEqual(parser.completeFrameCount, 2)
        XCTAssertEqual(parser.malformedRowCount, 0)
        XCTAssertEqual(events.count, 2)

        guard case let .frameCompleted(_, baselineSummaries, baselineDeltas, isBaseline) = events[0] else {
            return XCTFail("expected baseline frame")
        }
        XCTAssertTrue(isBaseline)
        XCTAssertTrue(baselineDeltas.isEmpty)
        XCTAssertEqual(baselineSummaries, [
            NettopProcessSummary(
                processName: "Example.1",
                downloadBytes: 100,
                uploadBytes: 50
            )
        ])

        guard case let .frameCompleted(_, summaries, deltas, isSecondBaseline) = events[1] else {
            return XCTFail("expected collecting frame")
        }
        XCTAssertFalse(isSecondBaseline)
        XCTAssertEqual(summaries, [
            NettopProcessSummary(
                processName: "Example.1",
                downloadBytes: 10,
                uploadBytes: 20
            )
        ])
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas[0].processName, "Example.1")
        XCTAssertEqual(deltas[0].remoteEndpoint, "93.184.216.34:443")
        XCTAssertEqual(deltas[0].interfaceName, "en0")
        XCTAssertEqual(deltas[0].state, "Established")
        XCTAssertEqual(deltas[0].downloadBytes, 10)
        XCTAssertEqual(deltas[0].uploadBytes, 20)
    }

    func testEmptyConnectionCountersBecomeZeroAndAreNotEmittedAsDelta() {
        let input = """
        time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
        10:00,Example.1,,,100,50,0,0,0,,,,,,,,,,,,
        09:59,tcp4 192.168.1.2:50000<->*:*,en0,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,
        time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
        10:01,Example.1,,,10,20,0,0,0,,,,,,,,,,,,
        10:00,tcp4 192.168.1.2:50000<->*:*,en0,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,
        """

        var parser = NettopConnectionCSVParser()
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        guard case let .frameCompleted(rowCount, _, deltas, isBaseline) = events[0] else {
            return XCTFail("expected baseline frame")
        }
        XCTAssertEqual(rowCount, 1)
        XCTAssertTrue(isBaseline)
        XCTAssertTrue(deltas.isEmpty)

        guard case let .frameCompleted(_, _, secondDeltas, secondIsBaseline) = events[1] else {
            return XCTFail("expected collecting frame")
        }
        XCTAssertFalse(secondIsBaseline)
        XCTAssertTrue(secondDeltas.isEmpty)
        XCTAssertEqual(parser.malformedRowCount, 0)
    }

    func testConnectionBeforeProcessSummaryIsMalformed() {
        let input = """
        time,,interface,state,bytes_in,bytes_out
        10:00,tcp4 192.168.1.2:50000<->93.184.216.34:443,en0,Established,100,50
        """

        var parser = NettopConnectionCSVParser()
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        XCTAssertEqual(parser.malformedRowCount, 1)
        XCTAssertTrue(events.contains { event in
            if case .malformedRow = event { return true }
            return false
        })
        XCTAssertEqual(parser.completeFrameCount, 1)
    }

    func testMissingConnectionColumnsAreIncompatible() {
        let input = "time,,bytes_in,bytes_out\n"
        var parser = NettopConnectionCSVParser()

        let events = parser.consume(Data(input.utf8))

        XCTAssertEqual(
            events,
            [.incompatibleSchema(missingColumns: ["interface", "state"])]
        )
        XCTAssertEqual(parser.state, .incompatible)
    }

    func testEndpointClassifierSeparatesHostnameIPAddressAndUnknown() {
        XCTAssertEqual(
            NettopEndpointClassifier.classify("example.com:443"),
            .hostname
        )
        XCTAssertEqual(
            NettopEndpointClassifier.classify("93.184.216.34:443"),
            .ipAddress
        )
        XCTAssertEqual(
            NettopEndpointClassifier.classify("2408:8756:3af0:2042::e.8080"),
            .ipAddress
        )
        XCTAssertEqual(
            NettopEndpointClassifier.classify("[::1]:443"),
            .ipAddress
        )
        XCTAssertEqual(NettopEndpointClassifier.classify("*:*"), .unknown)
        XCTAssertEqual(NettopEndpointClassifier.classify(nil), .unknown)
    }
}
