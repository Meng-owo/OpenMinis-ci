import XCTest

/// [S3-2][evolution] Injector tests — pure render/gating surface only.
/// No UserDefaults writes, no store I/O.
final class EvolutionInjectorTests: XCTestCase {

    private func lesson(_ id: String, status: EvolutionLessonStatus, priority: Int,
                        recommendation: String = "先诊断再重试",
                        tool: String? = "shell_execute") -> EvolutionLesson {
        EvolutionLesson(id: id, scope: "global", personaId: nil, taskSignature: tool,
                        conditions: "条件", recommendation: recommendation, antiPattern: nil,
                        evidenceActions: "[]", status: status, successCount: 1, failureCount: 1,
                        version: 1, parentId: nil, lastVerifiedAt: nil, injectPriority: priority)
    }

    // MARK: - OPT-1 relevance gate

    func testUnrelatedToolTagIsFilteredOut() {
        let tagged = lesson("shell", status: .verified, priority: 9)
        let generic = lesson("gen", status: .verified, priority: 1, tool: nil)
        let out = EvolutionInjector.render(
            lessons: [tagged, generic], budgetTokens: 400,
            activeTools: ["browser_navigate"])
        XCTAssertEqual(out.split(separator: "\n").count, 3)   // header + generic + footer
        XCTAssertTrue(out.contains("工具：先诊断再重试"))      // generic kept
        XCTAssertFalse(out.contains("shell_execute"))          // tagged dropped
    }

    func testEmptyActiveToolsKeepsOnlyGenericAndDoesNotCrash() {
        let tagged = lesson("shell", status: .verified, priority: 9)
        let generic = lesson("gen", status: .verified, priority: 1, tool: nil)
        let out = EvolutionInjector.render(
            lessons: [tagged, generic], budgetTokens: 400,
            activeTools: [])
        XCTAssertEqual(out.split(separator: "\n").count, 3)
        XCTAssertTrue(out.contains("工具：先诊断再重试"))
        XCTAssertFalse(out.contains("shell_execute"))
    }

    func testMatchingActiveToolPassesTaggedLesson() {
        let tagged = lesson("shell", status: .verified, priority: 1, tool: "shell_execute")
        let out = EvolutionInjector.render(
            lessons: [tagged], budgetTokens: 400,
            activeTools: ["shell_execute"])
        XCTAssertTrue(out.contains("shell_execute"))
    }

    func testNilActiveToolsKeepsEverything() {
        let tagged = lesson("shell", status: .verified, priority: 9)
        let generic = lesson("gen", status: .verified, priority: 1, tool: nil)
        let out = EvolutionInjector.render(
            lessons: [tagged, generic], budgetTokens: 400,
            activeTools: nil)
        XCTAssertEqual(out.split(separator: "\n").count, 4)   // both kept
        XCTAssertTrue(out.contains("shell_execute"))
        XCTAssertTrue(out.contains("工具：先诊断再重试"))
        // 2-arg render keeps the same default behavior.
        XCTAssertEqual(EvolutionInjector.render(lessons: [tagged, generic], budgetTokens: 400), out)
    }

    func testFilterEmptiesToNothingRatherThanPadding() {
        let tagged = lesson("shell", status: .verified, priority: 9)
        let out = EvolutionInjector.render(
            lessons: [tagged], budgetTokens: 400,
            activeTools: ["browser_navigate"])
        XCTAssertEqual(out, "")   // 宁缺毋滥 — no off-domain padding
    }

    func testOnlyActiveInjects() {
        XCTAssertFalse(EvolutionInjector.injects(mode: .off))
        XCTAssertFalse(EvolutionInjector.injects(mode: .shadow))
        XCTAssertTrue(EvolutionInjector.injects(mode: .active))
    }

    func testEmptyInputRendersEmpty() {
        XCTAssertEqual(EvolutionInjector.render(lessons: [], budgetTokens: 400), "")
    }

    func testConflictsAndDeprecatedAreNeverEligible() {
        let bad = [
            lesson("a", status: .conflicts, priority: 9),
            lesson("b", status: .deprecated, priority: 9),
        ]
        XCTAssertEqual(EvolutionInjector.render(lessons: bad, budgetTokens: 400), "")
    }

    func testVerifiedOutranksCandidateAndWrapsInTags() {
        let out = EvolutionInjector.render(lessons: [
            lesson("c1", status: .candidate, priority: 5),
            lesson("v1", status: .verified, priority: 1),
        ], budgetTokens: 400)
        XCTAssertTrue(out.hasPrefix("<evolution-tips>"))
        XCTAssertTrue(out.hasSuffix("</evolution-tips>"))
        XCTAssertEqual(out, out.trimmingCharacters(in: .whitespacesAndNewlines))
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 4)   // header + 2 entries + footer
        XCTAssertTrue(lines[1].contains("[已验证]"))
        XCTAssertTrue(lines[1].contains("shell_execute"))
        XCTAssertFalse(lines[1].contains("v1"))
        XCTAssertTrue(lines[2].contains("[候选]"))
    }

    func testTopKAndBudgetCap() {
        let many = (1...8).map { lesson("l\($0)", status: .candidate, priority: 8 - $0) }
        let out = EvolutionInjector.render(lessons: many, budgetTokens: 400)
        let lines = out.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertLessThanOrEqual(lines.count, 3)
        XCTAssertEqual(EvolutionInjector.render(lessons: many, budgetTokens: 0), "")

        // A budget too small for even one full line yields nothing rather
        // than a torn line.
        let tight = EvolutionInjector.render(lessons: many, budgetTokens: 1)
        XCTAssertTrue(tight.isEmpty || tight.hasPrefix("<evolution-tips>"))
    }

    func testRankIsStableAndDeterministic() {
        let input = [
            lesson("b", status: .candidate, priority: 5),
            lesson("a", status: .candidate, priority: 5),
            lesson("z", status: .verified, priority: 0),
        ]
        let ranked = EvolutionInjector.rank(input)
        XCTAssertEqual(ranked.map(\.id), ["z", "a", "b"])
    }
}
