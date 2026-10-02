import XCTest
@testable import WaifuClaw

final class AgentProviderTests: XCTestCase {
    func testParserEmitsTextThenFinishedForTerminalChunk() throws {
        var parser = OpenAICompatibleSSEParser()

        XCTAssertTrue(try parser.consume(line: "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}").isEmpty)
        let textEvents = try parser.consume(line: "")
        let terminalEvents = try consumeFrame(
            "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
            parser: &parser
        )

        guard case .text(let text)? = textEvents.first else {
            return XCTFail("Expected a streamed text event")
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(terminalEvents.count, 1)
        guard case .finished? = terminalEvents.first else {
            return XCTFail("Expected a terminal event")
        }
        XCTAssertTrue(try parser.finishInput().isEmpty)
    }

    func testParserAssemblesToolCallAcrossChunksBeforeEmitting() throws {
        var parser = OpenAICompatibleSSEParser()

        _ = try consumeFrame(
            "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_\",\"type\":\"function\",\"function\":{\"name\":\"read_\",\"arguments\":\"{\\\"path\\\":\\\"\"}}]},\"finish_reason\":null}]}",
            parser: &parser
        )
        _ = try consumeFrame(
            "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"123\",\"function\":{\"name\":\"file\",\"arguments\":\"README.md\\\"}\"}}]},\"finish_reason\":null}]}",
            parser: &parser
        )
        let events = try consumeFrame(
            "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
            parser: &parser
        )

        XCTAssertEqual(events.count, 2)
        guard case .toolCall(let call) = events[0] else {
            return XCTFail("Expected a completed tool call")
        }
        XCTAssertEqual(call.id, "call_123")
        XCTAssertEqual(call.name, "read_file")
        XCTAssertEqual(call.argumentsJSON, "{\"path\":\"README.md\"}")
        guard case .finished = events[1] else {
            return XCTFail("Expected finished after the completed tool call")
        }
    }

    func testParserFinishesFromDoneSentinel() throws {
        var parser = OpenAICompatibleSSEParser()

        XCTAssertTrue(try parser.consume(line: "data: [DONE]").isEmpty)
        let events = try parser.consume(line: "")

        XCTAssertEqual(events.count, 1)
        guard case .finished = events[0] else {
            return XCTFail("Expected finished for [DONE]")
        }
    }

    private func consumeFrame(
        _ json: String,
        parser: inout OpenAICompatibleSSEParser
    ) throws -> [AgentProviderEvent] {
        XCTAssertTrue(try parser.consume(line: "data: \(json)").isEmpty)
        return try parser.consume(line: "")
    }
}
