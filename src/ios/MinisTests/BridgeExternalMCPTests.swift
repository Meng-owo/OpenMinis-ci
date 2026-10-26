import Foundation
import XCTest

@testable import Minis

/// 第 17 条 App 侧 XCTest：新会话经 App 的对外 MCP 服务走一遍真实回环 HTTP，
/// 断言 tools/list 只返回「搜」「命令」两个元工具（内部工具绝不外露）。
///
/// 与 BridgeCore 的 WireEndToEndTests 同构，但走 App target 的
/// BridgeExternalMCPService + URLSession 高层客户端（协议层细节归内核层
/// 的原始 socket 测试验）。App target 只能在 CI（Xcode）跑。
final class BridgeExternalMCPTests: XCTestCase {

    private var service: BridgeExternalMCPService!
    private var session: URLSession!

    override func setUpWithError() throws {
        service = BridgeExternalMCPService()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    override func tearDown() async throws {
        service.stop()
        session.invalidateAndCancel()
        service = nil
        session = nil
    }

    /// 默认关闭：单例在无人启动时必须未运行、无端口——
    /// App 启动现有行为零变化的直接证据。
    func testSharedDefaultsToOff() {
        XCTAssertFalse(BridgeExternalMCPService.shared.isRunning)
        XCTAssertNil(BridgeExternalMCPService.shared.boundPort)
    }

    func testNewSessionListsExactlyTwoMetaTools() async throws {
        XCTAssertFalse(service.isRunning)
        XCTAssertNil(service.boundPort)

        try service.ensureRunning()
        XCTAssertTrue(service.isRunning)
        let port = try XCTUnwrap(service.boundPort)
        XCTAssertGreaterThan(port, 0)
        // 幂等：再调一次不报错、端口不变。
        XCTAssertNoThrow(try service.ensureRunning())
        XCTAssertEqual(service.boundPort, port)

        // 1. initialize 开新会话
        let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"external-mcp-test","version":"1.0"}}}"#
        let (initData, initResponse) = try await post(body: initBody, port: port)
        XCTAssertEqual(initResponse.statusCode, 200)
        let sessionID = try XCTUnwrap(
            initResponse.value(forHTTPHeaderField: "Mcp-Session-Id"),
            "initialize 响应必须带回会话 id")
        let initResult = try resultObject(in: initData)
        let serverInfo = try XCTUnwrap(initResult["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "bridge")

        // 2. 初始化完成通知
        let (_, notifyResponse) = try await post(
            body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            port: port, sessionID: sessionID)
        XCTAssertEqual(notifyResponse.statusCode, 202)

        // 3. tools/list：只许有两个工具
        let (listData, listResponse) = try await post(
            body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            port: port, sessionID: sessionID)
        XCTAssertEqual(listResponse.statusCode, 200)
        let listResult = try resultObject(in: listData)
        let tools = try XCTUnwrap(listResult["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["搜", "命令"], "对外只许出现「搜」「命令」两个元工具")

        // 4. stop 后回到关闭态
        service.stop()
        XCTAssertFalse(service.isRunning)
        XCTAssertNil(service.boundPort)
    }

    // MARK: - HTTP

    private func post(
        body: String, port: Int, sessionID: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Accept 同内核线级测试：SDK 本机模式要求 application/json + SSE 都在清单里。
        // Host 由 URLSession 按 URL 自动写成 127.0.0.1:端口，正合校验名单的带端口模式。
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        return (data, httpResponse)
    }

    /// 取响应正文里的 JSON-RPC 消息并抽出 result：宿主发回来的是 SSE
    /// （一行一条 data:），也兼容整段 JSON 直回两种形状。
    private func resultObject(in data: Data) throws -> [String: Any] {
        let message = try lastJSONMessage(in: data)
        return try XCTUnwrap(message["result"] as? [String: Any], "消息里没有 result")
    }

    private func lastJSONMessage(in data: Data) throws -> [String: Any] {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8), "响应不是 UTF-8")
        if let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        {
            return dict
        }
        let payloads = text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("data: ") }
            .map { String($0.dropFirst("data: ".count)) }
            .filter { !$0.isEmpty }
        let last = try XCTUnwrap(payloads.last, "SSE 响应里没有消息事件：\(text)")
        let object = try JSONSerialization.jsonObject(with: Data(last.utf8))
        return try XCTUnwrap(object as? [String: Any], "消息不是 JSON 对象：\(last)")
    }
}
