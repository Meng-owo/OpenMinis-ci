import XCTest

/// [S7][evolution] 回归契约——所有未来改动都必须守住的机器可检不变量。
/// 真机侧「10 任务 × 2 轮对比」协议见回执文档；这里锁定能离线跑的部分。
final class EvolutionRegressionContractTests: XCTestCase {

    // MARK: - 模式闸门（off / shadow 永不注入）

    func testOffAndShadowNeverInject() {
        for mode in EvolutionMode.allCases where mode != .active {
            XCTAssertFalse(EvolutionInjector.injects(mode: mode), "\(mode) 必须零注入")
        }
        XCTAssertTrue(EvolutionInjector.injects(mode: .active))
    }

    func testModeRawValuesAreFrozen() {
        XCTAssertEqual(EvolutionMode.off.rawValue, "off")
        XCTAssertEqual(EvolutionMode.shadow.rawValue, "shadow")
        XCTAssertEqual(EvolutionMode.active.rawValue, "active")
    }

    func testLessonStatusRawValuesFrozen() {
        XCTAssertEqual(EvolutionLessonStatus.candidate.rawValue, "candidate")
        XCTAssertEqual(EvolutionLessonStatus.verified.rawValue, "verified")
        XCTAssertEqual(EvolutionLessonStatus.deprecated.rawValue, "deprecated")
        XCTAssertEqual(EvolutionLessonStatus.conflicts.rawValue, "conflicts")
    }

    // MARK: - 提炼器门槛冻结

    func testExtractorThresholdsAreFrozen() {
        XCTAssertEqual(EvolutionExtractor.Thresholds.failureClusterMin, 3)
        XCTAssertEqual(EvolutionExtractor.Thresholds.recoveryMin, 2)
        XCTAssertEqual(EvolutionExtractor.Thresholds.recoveryWindowSteps, 6)
    }

    // MARK: - 渲染帧与预算

    func testRenderFrameAndBudget() {
        XCTAssertEqual(EvolutionInjector.render(lessons: [], budgetTokens: 400), "")
        XCTAssertEqual(EvolutionInjector.render(lessons: [], budgetTokens: 0), "")
        let lesson = EvolutionLesson(
            id: "contract-1", scope: "global", personaId: nil, taskSignature: "shell_execute",
            conditions: "c", recommendation: "r", antiPattern: nil, evidenceActions: "[]",
            status: .verified, successCount: 1, failureCount: 1, version: 1,
            parentId: nil, lastVerifiedAt: nil, injectPriority: 1)
        let out = EvolutionInjector.render(lessons: [lesson], budgetTokens: 400)
        XCTAssertTrue(out.hasPrefix("<evolution-tips>"))
        XCTAssertTrue(out.hasSuffix("</evolution-tips>"))
        XCTAssertLessThanOrEqual(out.count, 400 * 4)
    }

    // MARK: - 全链路离线走查（记录→提炼→裁决→可注入）

    func testFullPipelineOfflineWalkthrough() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("evo-s7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try EvolutionStore(url: dir.appendingPathComponent("evolution.db"))

        // 1) 记录：同一个工具三次失败（三条 run）。
        for i in 0..<3 {
            await store.insert(EvolutionAction(
                id: "f\(i)", runId: "r\(i)", seq: 1, toolName: "shell_execute", profile: "",
                status: .fail, errorClass: "tool_error", errorDigest: nil,
                durationMs: 12, retryCount: 0, resultDigest: nil
            ), createdAt: Date().addingTimeInterval(Double(i)))
        }

        // 2) 提炼：一次整理产出候选。
        await EvolutionExtractionQueue().runPass(on: store)
        let candidates = await store.lessons(status: .candidate)
        XCTAssertEqual(candidates.count, 1)
        let lessonId = try XCTUnwrap(candidates.first?.id)

        // 3) 人工裁决：通过 → 已验证。
        _ = await store.updateLessonStatus(id: lessonId, status: .verified)
        let verified = await store.lessons(status: .verified)
        XCTAssertEqual(verified.count, 1)

        // 4) 可注入面：渲染包含该条；但 shadow 闸门依然零注入。
        let fragment = EvolutionInjector.render(lessons: verified, budgetTokens: 400)
        XCTAssertTrue(fragment.contains("已验证"))
        XCTAssertTrue(fragment.contains("shell_execute"))
        XCTAssertFalse(EvolutionInjector.injects(mode: .shadow))

        // 5) 只增不改：整个链路没有任何物理删除发生。
        let counts = await store.counts()
        XCTAssertGreaterThanOrEqual(counts["actions"] ?? 0, 3)
        XCTAssertGreaterThanOrEqual(counts["lessons"] ?? 0, 1)
    }
}
