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

        var parser = NettopCSVParser()
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

        var parser = NettopCSVParser()
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
}
