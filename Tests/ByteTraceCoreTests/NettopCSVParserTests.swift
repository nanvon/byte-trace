import XCTest

@testable import ByteTraceCore

final class NettopCSVParserTests: XCTestCase {
    private let header = "time,,interface,state,bytes_in,bytes_out,\n"

    func testChunkedInputUsesFirstFrameAsBaseline() {
        let input = """
        time,,interface,state,bytes_in,bytes_out,
        20:00:00.000,Dia.1,,,100,200,
        time,,interface,state,bytes_in,bytes_out,
        20:00:01.000,Dia.1,,,3,4,
        """

        var parser = NettopCSVParser(mode: .processSummary)
        var events: [NettopParserEvent] = []
        let data = Data(input.utf8)

        for offset in stride(from: 0, to: data.count, by: 3) {
            let end = min(offset + 3, data.count)
            events.append(contentsOf: parser.consume(data.subdata(in: offset..<end)))
        }
        events.append(contentsOf: parser.finish())

        XCTAssertEqual(parser.completeFrameCount, 2)
        XCTAssertEqual(parser.state, .collecting)

        guard case let .frameCompleted(rowCount, deltas, isBaseline) = events[0] else {
            return XCTFail("expected baseline frame")
        }
        XCTAssertEqual(rowCount, 1)
        XCTAssertTrue(deltas.isEmpty)
        XCTAssertTrue(isBaseline)

        guard case let .frameCompleted(secondRowCount, secondDeltas, secondIsBaseline) = events.last else {
            return XCTFail("expected collecting frame")
        }
        XCTAssertEqual(secondRowCount, 1)
        XCTAssertFalse(secondIsBaseline)
        XCTAssertEqual(
            secondDeltas,
            [
                NettopDelta(
                    sampledAt: "20:00:01.000",
                    processName: "Dia.1",
                    downloadBytes: 3,
                    uploadBytes: 4
                )
            ]
        )
    }

    func testCSVQuotesCommasAndEscapedQuotes() {
        let process = "Browser, Helper \"X\".1"
        let input = """
        \(header)20:00:00.000,"Browser, Helper ""X"".1",,,1,2,
        \(header)20:00:01.000,"Browser, Helper ""X"".1",,,5,6,
        """

        var parser = NettopCSVParser(mode: .processSummary)
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        guard case let .frameCompleted(_, deltas, false) = events.last else {
            return XCTFail("expected a collecting frame")
        }
        XCTAssertEqual(deltas.first?.processName, process)
        XCTAssertEqual(deltas.first?.downloadBytes, 5)
        XCTAssertEqual(deltas.first?.uploadBytes, 6)
    }

    func testRequiredColumnsCanBeReorderedAndExtended() {
        let reorderedHeader = "time,,bytes_out,extra,bytes_in,new,\n"
        let input = """
        \(header)20:00:00.000,App.1,,,1,2,
        \(reorderedHeader)20:00:01.000,App.1,17,extra,13,new,
        """

        var parser = NettopCSVParser()
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        XCTAssertTrue(events.contains { event in
            if case .schemaChanged = event { return true }
            return false
        })
        guard case let .frameCompleted(_, deltas, false) = events.last else {
            return XCTFail("expected a collecting frame")
        }
        XCTAssertEqual(deltas.first?.downloadBytes, 13)
        XCTAssertEqual(deltas.first?.uploadBytes, 17)
    }

    func testMalformedAndNegativeRowsAreSkipped() {
        let input = """
        \(header)20:00:00.000,App.1,,,1,2,
        \(header)20:00:01.000,App.1,,,oops,2,
        20:00:01.000,App.1,,,-1,2,
        20:00:01.000,App.1,,,0,0,
        """

        var parser = NettopCSVParser()
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        XCTAssertEqual(parser.malformedRowCount, 2)
        XCTAssertEqual(events.filter { $0 == .malformedRow }.count, 2)
        guard case let .frameCompleted(rowCount, deltas, false) = events.last else {
            return XCTFail("expected a collecting frame")
        }
        XCTAssertEqual(rowCount, 1)
        XCTAssertTrue(deltas.isEmpty)
    }

    func testMissingRequiredColumnStopsFrameParsing() {
        let invalidHeader = "time,,interface,state,bytes_in,\n"
        var parser = NettopCSVParser()

        let events = parser.consume(Data(invalidHeader.utf8))

        XCTAssertEqual(parser.state, .incompatible)
        XCTAssertEqual(parser.completeFrameCount, 0)
        XCTAssertEqual(
            events,
            [.incompatibleSchema(missingColumns: ["bytes_out"])]
        )
    }

    func testConnectionRowsAreAttributedToRecentProcessRow() {
        let input = """
        time,,interface,state,bytes_in,bytes_out,
        20:00:00.000,Dia.1,,,0,0,
        20:00:00.000,tcp4 127.0.0.1:57123<->127.0.0.1:59169,lo0,Established,100,200,
        time,,interface,state,bytes_in,bytes_out,
        20:00:01.000,Dia.1,,,0,0,
        20:00:01.000,tcp4 198.18.0.1:59051<->91.108.56.139:443,utun4,Established,3,4,
        """

        var parser = NettopCSVParser(mode: .connections)
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        XCTAssertEqual(parser.completeFrameCount, 2)
        guard case let .frameCompleted(_, deltas, false) = events.last else {
            return XCTFail("expected a collecting frame")
        }
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas.first?.processName, "Dia.1")
        XCTAssertEqual(deltas.first?.downloadBytes, 3)
        XCTAssertEqual(deltas.first?.uploadBytes, 4)
        XCTAssertEqual(deltas.first?.interface, "utun4")
        XCTAssertEqual(deltas.first?.connectionTarget, "91.108.56.139:443")
        XCTAssertEqual(deltas.first?.localEndpoint, NettopEndpoint(host: "198.18.0.1", port: 59051))
        XCTAssertEqual(deltas.first?.remoteEndpoint, NettopEndpoint(host: "91.108.56.139", port: 443))
    }

    func testLoopbackConnectionCarriesInterfaceAndTarget() {
        let input = """
        time,,interface,state,bytes_in,bytes_out,
        20:00:00.000,Dia.1,,,0,0,
        20:00:00.000,tcp4 127.0.0.1:57123<->127.0.0.1:59169,lo0,Established,100,200,
        time,,interface,state,bytes_in,bytes_out,
        20:00:01.000,Dia.1,,,0,0,
        20:00:01.000,tcp4 127.0.0.1:57123<->127.0.0.1:59169,lo0,Established,5,6,
        """

        var parser = NettopCSVParser(mode: .connections)
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        guard case let .frameCompleted(_, deltas, false) = events.last else {
            return XCTFail("expected a collecting frame")
        }
        XCTAssertEqual(deltas.first?.interface, "lo0")
        XCTAssertEqual(deltas.first?.connectionTarget, "127.0.0.1:59169")
        XCTAssertEqual(deltas.first?.localEndpoint, NettopEndpoint(host: "127.0.0.1", port: 57123))
        XCTAssertEqual(deltas.first?.remoteEndpoint, NettopEndpoint(host: "127.0.0.1", port: 59169))
        XCTAssertEqual(deltas.first?.connectionState, "Established")
        XCTAssertEqual(deltas.first?.downloadBytes, 5)
    }

    func testListenConnectionWithEmptyBytesIsNotMalformed() {
        let input = """
        time,,interface,state,bytes_in,bytes_out,
        20:00:00.000,Dia.1,,,0,0,
        20:00:00.000,tcp4 127.0.0.1:8021<->*:*,lo0,Listen,,,
        time,,interface,state,bytes_in,bytes_out,
        20:00:01.000,Dia.1,,,0,0,
        20:00:01.000,tcp4 127.0.0.1:8021<->*:*,lo0,Listen,,,
        """

        var parser = NettopCSVParser(mode: .connections)
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        XCTAssertEqual(parser.malformedRowCount, 0)
        guard case let .frameCompleted(rowCount, deltas, false) = events.last else {
            return XCTFail("expected a collecting frame")
        }
        XCTAssertEqual(rowCount, 1)
        XCTAssertTrue(deltas.isEmpty)
    }

    func testProcessRowsWithoutConnectionsFallBackToLegacyBehavior() {
        // 旧 -P 风格输出（整帧只有进程行、无连接行）回退用进程行产出 delta。
        let input = """
        time,,interface,state,bytes_in,bytes_out,
        20:00:00.000,Dia.1,,,100,200,
        time,,interface,state,bytes_in,bytes_out,
        20:00:01.000,Dia.1,,,3,4,
        """

        var parser = NettopCSVParser(mode: .processSummary)
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        guard case let .frameCompleted(_, deltas, false) = events.last else {
            return XCTFail("expected a collecting frame")
        }
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas.first?.processName, "Dia.1")
        XCTAssertEqual(deltas.first?.downloadBytes, 3)
        XCTAssertEqual(deltas.first?.interface, nil)
        XCTAssertEqual(deltas.first?.connectionTarget, nil)
    }

    func testInterfaceEmptyConnectionRowsAreIgnoredAndDoNotBreakAttribution() {
        // `udp4 *:*<->*:*` 这类连接行 interface 列为空，既不能当进程行，
        // 也不能污染后续连接行的归属；且不能作为兜底进程行产出 delta。
        let input = """
        time,,interface,state,bytes_in,bytes_out,
        20:00:00.000,Dia.1,,,0,0,
        20:00:00.000,udp4 *:56321<->*:*,,,0,773,
        20:00:00.000,tcp4 198.18.0.1:59051<->91.108.56.139:443,utun4,Established,3,4,
        time,,interface,state,bytes_in,bytes_out,
        20:00:01.000,Dia.1,,,0,0,
        20:00:01.000,udp4 *:56321<->*:*,,,0,773,
        20:00:01.000,tcp4 198.18.0.1:59051<->91.108.56.139:443,utun4,Established,5,6,
        """

        var parser = NettopCSVParser(mode: .connections)
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        XCTAssertEqual(parser.malformedRowCount, 0)
        guard case let .frameCompleted(_, deltas, false) = events.last else {
            return XCTFail("expected a collecting frame")
        }
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas.first?.processName, "Dia.1")
        XCTAssertEqual(deltas.first?.downloadBytes, 5)
        XCTAssertEqual(deltas.first?.interface, "utun4")
        XCTAssertEqual(deltas.first?.connectionTarget, "91.108.56.139:443")
    }

    func testConnectionModeDoesNotFallBackToProcessRows() {
        let input = """
        time,,interface,state,bytes_in,bytes_out,
        20:00:00.000,Dia.1,,,100,200,
        time,,interface,state,bytes_in,bytes_out,
        20:00:01.000,Dia.1,,,3,4,
        """

        var parser = NettopCSVParser(mode: .connections)
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        guard case let .frameCompleted(rowCount, deltas, false) = events.last else {
            return XCTFail("expected a collecting frame")
        }
        XCTAssertEqual(rowCount, 0)
        XCTAssertTrue(deltas.isEmpty)
    }

    func testIPv6LoopbackTargetParsing() {
        let input = """
        time,,interface,state,bytes_in,bytes_out,
        20:00:00.000,Dia.1,,,0,0,
        20:00:00.000,tcp6 ::1.8021<->*.*,lo0,Listen,,,
        20:00:00.000,tcp6 fe80::8af:5f9:677:e110%en0.60929<->fe80::8af:5f9:677:e110%en0.50231,en0,Established,7,8,
        time,,interface,state,bytes_in,bytes_out,
        20:00:01.000,Dia.1,,,0,0,
        20:00:01.000,tcp6 ::1.8021<->*.*,lo0,Listen,,,
        20:00:01.000,tcp6 fe80::8af:5f9:677:e110%en0.60929<->fe80::8af:5f9:677:e110%en0.50231,en0,Established,9,10,
        """

        var parser = NettopCSVParser(mode: .connections)
        let events = parser.consume(Data(input.utf8)) + parser.finish()

        guard case let .frameCompleted(_, deltas, false) = events.last else {
            return XCTFail("expected a collecting frame")
        }
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas.first?.interface, "en0")
        XCTAssertEqual(
            deltas.first?.connectionTarget,
            "fe80::8af:5f9:677:e110%en0.50231"
        )
    }
}
