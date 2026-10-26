import XCTest
@testable import Minis

/// 中继协议 v1 纯逻辑测试（合并第 18(a) 条）：
/// RelayFrame 编解码 / RelayBackoff 序列 / RelayHeaderFilter 过滤 /
/// RelayEndpoint 地址拼装。这些类型只依赖 Foundation，
/// 同一批断言也在 Linux 上以独立 harness 跑过（见本步回执）。
final class BridgeRelayProtocolTests: XCTestCase {

    // MARK: - RelayFrame 编码

    func testHelloFrameMatchesProtocolShape() throws {
        let text = try RelayFrame.hello.encode()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "hello")
        XCTAssertEqual(object["app"] as? String, "openminis-bridge")
        XCTAssertEqual((object["v"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(object.count, 3, "hello 帧只许有 type/app/v 三个键")
    }

    func testPingFrameMatchesProtocolShape() throws {
        let text = try RelayFrame.ping.encode()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "ping")
        XCTAssertEqual(object.count, 1)
    }

    func testResponseFrameRoundTrip() throws {
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8).base64EncodedString()
        let frame = RelayFrame.response(
            id: "9E2B7C10-1111-4222-8333-444455556666",
            status: 200,
            headers: ["content-type": "application/json", "mcp-session-id": "sess-1"],
            bodyBase64: body)
        let decoded = try RelayFrame.decode(try frame.encode())
        XCTAssertEqual(decoded, frame)
    }

    func testErrorFrameRoundTrip() throws {
        let frame = RelayFrame.error(id: "abc", message: "local MCP service unavailable")
        XCTAssertEqual(try RelayFrame.decode(try frame.encode()), frame)
    }

    // MARK: - RelayFrame 解码（中继→手机方向）

    func testDecodeRequestFrameFromProtocolLiteral() throws {
        let body = Data("hello-body".utf8).base64EncodedString()
        let literal = "{\"type\":\"req\",\"id\":\"req-1\",\"headers\":{\"content-type\":\"application/json\",\"authorization\":\"Bearer x\"},\"body\":\"\(body)\"}"
        let frame = try RelayFrame.decode(literal)
        XCTAssertEqual(frame, .request(
            id: "req-1",
            headers: ["content-type": "application/json", "authorization": "Bearer x"],
            bodyBase64: body))
    }

    func testDecodeRequestFrameDefaultsMissingHeadersAndBody() throws {
        let frame = try RelayFrame.decode("{\"type\":\"req\",\"id\":\"req-2\"}")
        XCTAssertEqual(frame, .request(id: "req-2", headers: [:], bodyBase64: ""))
    }

    func testDecodeRejectsNonJSON() {
        XCTAssertThrowsError(try RelayFrame.decode("not json")) { error in
            XCTAssertEqual(error as? RelayFrameError, .notJSONObject)
        }
    }

    func testDecodeRejectsMissingType() {
        XCTAssertThrowsError(try RelayFrame.decode("{\"id\":\"x\"}")) { error in
            XCTAssertEqual(error as? RelayFrameError, .missingType)
        }
    }

    func testDecodeRejectsUnknownType() {
        XCTAssertThrowsError(try RelayFrame.decode("{\"type\":\"teleport\",\"id\":\"x\"}")) { error in
            XCTAssertEqual(error as? RelayFrameError, .unknownType("teleport"))
        }
    }

    func testDecodeRejectsResponseMissingStatus() {
        XCTAssertThrowsError(try RelayFrame.decode("{\"type\":\"res\",\"id\":\"x\",\"body\":\"\"}")) { error in
            XCTAssertEqual(error as? RelayFrameError, .missingField("status"))
        }
    }

    // MARK: - RelayBackoff

    func testBackoffSequenceDoublesThenCapsAt60() {
        var backoff = RelayBackoff()
        let sequence = (0..<8).map { _ in backoff.nextDelay() }
        XCTAssertEqual(sequence, [2, 4, 8, 16, 32, 60, 60, 60])
    }

    func testBackoffResetReturnsToInitial() {
        var backoff = RelayBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 2)
    }

    // MARK: - RelayHeaderFilter（本地请求方向）

    func testLocalRequestStripsHopByHopAndReframedHeaders() {
        let input = [
            "Content-Type": "application/json",
            "Mcp-Session-Id": "sess-9",
            "Authorization": "Bearer keep-me",
            "Host": "relay.example.workers.dev",
            "Content-Length": "1234",
            "Connection": "keep-alive, X-Debug-Trace",
            "Keep-Alive": "timeout=5",
            "Transfer-Encoding": "chunked",
            "TE": "trailers",
            "Upgrade": "websocket",
            "X-Debug-Trace": "1",
        ]
        let out = RelayHeaderFilter.headersForLocalRequest(input)
        XCTAssertEqual(out["Content-Type"], "application/json")
        XCTAssertEqual(out["Mcp-Session-Id"], "sess-9")
        XCTAssertEqual(out["Authorization"], "Bearer keep-me")
        for stripped in ["Host", "Content-Length", "Connection", "Keep-Alive",
                         "Transfer-Encoding", "TE", "Upgrade", "X-Debug-Trace"] {
            XCTAssertNil(out[stripped], "\(stripped) 应被剥掉")
        }
        XCTAssertEqual(out.count, 3)
    }

    // MARK: - RelayHeaderFilter（回中继方向）

    func testRelayResponseKeepsEndToEndHeaders() {
        let input = [
            "content-type": "text/event-stream",
            "content-length": "42",
            "mcp-session-id": "sess-9",
            "connection": "close",
            "transfer-encoding": "chunked",
        ]
        let out = RelayHeaderFilter.headersForRelayResponse(input)
        XCTAssertEqual(out["content-type"], "text/event-stream")
        XCTAssertEqual(out["content-length"], "42")
        XCTAssertEqual(out["mcp-session-id"], "sess-9")
        XCTAssertNil(out["connection"])
        XCTAssertNil(out["transfer-encoding"])
        XCTAssertEqual(out.count, 3)
    }

    // MARK: - RelayEndpoint

    func testNormalizedHostAcceptsBareHost() {
        XCTAssertEqual(RelayEndpoint.normalizedHost("xxx.workers.dev"), "xxx.workers.dev")
    }

    func testNormalizedHostStripsSchemeAndPath() {
        XCTAssertEqual(RelayEndpoint.normalizedHost("wss://xxx.workers.dev/device/abc"), "xxx.workers.dev")
        XCTAssertEqual(RelayEndpoint.normalizedHost("https://xxx.workers.dev/"), "xxx.workers.dev")
        XCTAssertEqual(RelayEndpoint.normalizedHost("  xxx.workers.dev  "), "xxx.workers.dev")
    }

    func testNormalizedHostRejectsEmptyAndWhitespace() {
        XCTAssertNil(RelayEndpoint.normalizedHost(""))
        XCTAssertNil(RelayEndpoint.normalizedHost("   "))
        XCTAssertNil(RelayEndpoint.normalizedHost("a b.workers.dev"))
    }

    func testDeviceURLMatchesProtocolShape() {
        let url = RelayEndpoint.deviceURL(host: "xxx.workers.dev", token: "abc-DEF_123")
        XCTAssertEqual(url?.absoluteString, "wss://xxx.workers.dev/device/abc-DEF_123")
    }

    func testDeviceURLKeepsExplicitPort() {
        let url = RelayEndpoint.deviceURL(host: "localhost:8787", token: "tok")
        XCTAssertEqual(url?.absoluteString, "wss://localhost:8787/device/tok")
    }

    func testDeviceURLRejectsMissingTokenOrHost() {
        XCTAssertNil(RelayEndpoint.deviceURL(host: "xxx.workers.dev", token: ""))
        XCTAssertNil(RelayEndpoint.deviceURL(host: "xxx.workers.dev", token: "   "))
        XCTAssertNil(RelayEndpoint.deviceURL(host: "", token: "tok"))
    }

    func testMaskedHostNeverContainsFullHost() {
        let host = "my-relay-1234.workers.dev"
        let masked = RelayEndpoint.maskedHost(host)
        XCTAssertFalse(masked.contains(host))
        XCTAssertTrue(masked.hasSuffix("ers.dev"))
        XCTAssertEqual(RelayEndpoint.maskedHost(""), "—")
        XCTAssertEqual(RelayEndpoint.maskedHost("short.dev"), "••••")
    }

    // MARK: - RelayRequestLedger（五-1 去重台账）

    private func ledgerFrame(id: String) -> RelayFrame {
        .response(id: id, status: 200, headers: ["content-type": "application/json"], bodyBase64: "e30=")
    }

    func testLedgerFirstBeginIsNewSecondBeginIsDuplicateInFlight() {
        let ledger = RelayRequestLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ledger.begin(id: "r1", now: t0), .newRequest)
        XCTAssertEqual(ledger.begin(id: "r1", now: t0), .duplicateInFlight)
    }

    func testLedgerCompletedRequestReplaysCachedFrame() {
        let ledger = RelayRequestLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ledger.begin(id: "r1", now: t0), .newRequest)
        ledger.complete(id: "r1", frame: ledgerFrame(id: "r1"), now: t0)
        XCTAssertEqual(ledger.begin(id: "r1", now: t0), .replay(ledgerFrame(id: "r1")))
    }

    func testLedgerErrorFrameIsAlsoReplayable() {
        let ledger = RelayRequestLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ledger.begin(id: "r1", now: t0), .newRequest)
        let err = RelayFrame.error(id: "r1", message: "local MCP service unavailable")
        ledger.complete(id: "r1", frame: err, now: t0)
        XCTAssertEqual(ledger.begin(id: "r1", now: t0), .replay(err))
    }

    func testLedgerReplayExpiresAfterTTL() {
        let ledger = RelayRequestLedger(completedTTL: 600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ledger.begin(id: "r1", now: t0), .newRequest)
        ledger.complete(id: "r1", frame: ledgerFrame(id: "r1"), now: t0)
        // TTL 内还是回放；过了 TTL 当新请求（台账不许无限期记账）。
        XCTAssertEqual(ledger.begin(id: "r1", now: t0.addingTimeInterval(599)), .replay(ledgerFrame(id: "r1")))
        XCTAssertEqual(ledger.begin(id: "r1", now: t0.addingTimeInterval(601)), .newRequest)
    }

    func testLedgerEvictsOldestBeyondCapacity() {
        let ledger = RelayRequestLedger(maxCompletedEntries: 2, completedTTL: 3600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for (i, id) in ["a", "b", "c"].enumerated() {
            let t = t0.addingTimeInterval(TimeInterval(i))
            XCTAssertEqual(ledger.begin(id: id, now: t), .newRequest)
            ledger.complete(id: id, frame: ledgerFrame(id: id), now: t)
        }
        // 容量 2：最早的 a 被淘汰（当新请求），b、c 还能回放。
        XCTAssertEqual(ledger.begin(id: "a", now: t0.addingTimeInterval(10)), .newRequest)
        XCTAssertEqual(ledger.begin(id: "b", now: t0.addingTimeInterval(10)), .replay(ledgerFrame(id: "b")))
        XCTAssertEqual(ledger.begin(id: "c", now: t0.addingTimeInterval(10)), .replay(ledgerFrame(id: "c")))
    }

    func testLedgerIdsAreIndependent() {
        let ledger = RelayRequestLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ledger.begin(id: "r1", now: t0), .newRequest)
        XCTAssertEqual(ledger.begin(id: "r2", now: t0), .newRequest)
        ledger.complete(id: "r2", frame: ledgerFrame(id: "r2"), now: t0)
        XCTAssertEqual(ledger.begin(id: "r1", now: t0), .duplicateInFlight)
        XCTAssertEqual(ledger.begin(id: "r2", now: t0), .replay(ledgerFrame(id: "r2")))
    }
}
