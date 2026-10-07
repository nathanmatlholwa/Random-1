import XCTest
@testable import MathsToFailure

final class EngineTests: XCTestCase {
    func testLevelRisesUntilFirstFailureThenHoldsUntilTwoPasses() {
        var s = SkillState(id: UUID(), topic: "T", skill: "S")
        Engine.apply(&s, fraction: 1.0, tags: [])
        XCTAssertEqual(s.level, 2)

        Engine.apply(&s, fraction: 0.2, tags: ["sign_error"])
        XCTAssertEqual(s.failedAt, 2)
        XCTAssertEqual(s.level, 2)
        XCTAssertEqual(s.errors["sign_error"], 1)

        Engine.apply(&s, fraction: 1.0, tags: [])
        XCTAssertEqual(s.level, 2)
        XCTAssertNotNil(s.failedAt)

        Engine.apply(&s, fraction: 0.9, tags: [])
        XCTAssertEqual(s.level, 3)
        XCTAssertNil(s.failedAt)
    }

    func testThreeFailuresInARowStepTheLevelDown() {
        var s = SkillState(id: UUID(), topic: "T", skill: "S")
        s.level = 3
        for _ in 0..<3 { Engine.apply(&s, fraction: 0.1, tags: []) }
        XCTAssertEqual(s.level, 2)
        XCTAssertEqual(s.failedAt, 2)
    }

    func testMiddleScoresHoldTheLevelAndRecordErrors() {
        var s = SkillState(id: UUID(), topic: "T", skill: "S")
        s.level = 2
        Engine.apply(&s, fraction: 0.6, tags: ["wrong_quadrant"])
        XCTAssertEqual(s.level, 2)
        XCTAssertNil(s.failedAt)
        XCTAssertEqual(s.errors["wrong_quadrant"], 1)
    }

    func testPickSkillFavoursTheWeakSkill() {
        var weak = SkillState(id: UUID(), topic: "T", skill: "weak")
        weak.mastery = 0.1
        weak.attempts = 4
        weak.failedAt = 2
        var strong = SkillState(id: UUID(), topic: "T", skill: "strong")
        strong.mastery = 0.95
        strong.attempts = 4
        var weakCount = 0
        for i in 0..<100 {
            if Engine.pickSkill(from: [weak, strong], roll: Double(i) / 100.0) == weak.key { weakCount += 1 }
        }
        XCTAssertGreaterThan(weakCount, 70)
    }
}

final class LLMJSONTests: XCTestCase {
    func testRepairsControlCharactersLeftByLatexBackslashes() {
        XCTAssertEqual(LLMJSON.repairString("\u{0C}rac{1}{2}"), "\\frac{1}{2}")
        XCTAssertEqual(LLMJSON.repairString("\theta + \times"), "\\theta + \\times")
        XCTAssertEqual(LLMJSON.repairString("\u{08}eta"), "\\beta")
    }

    func testDoesNotTouchOrdinaryNewlines() {
        XCTAssertEqual(LLMJSON.repairString("line one\nequation two"), "line one\nequation two")
    }

    func testParsesLatexWithUnknownEscapes() throws {
        let raw = #"{"question":"Solve $\alpha + 1 = 2$","marks":2}"#
        let obj = try LLMJSON.parseObject(raw) as? [String: Any]
        XCTAssertEqual(obj?["question"] as? String, "Solve $\\alpha + 1 = 2$")
    }

    func testParsesInsideCodeFencesAndAfterChatter() throws {
        let raw = "Here you go:\n```json\n{\"ok\": true}\n```"
        let obj = try LLMJSON.parseObject(raw) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
    }

    func testFlexibleNumbers() throws {
        struct Box: Decodable { let a: FlexInt; let b: FlexInt; let c: FlexString }
        let box = try LLMJSON.decode(#"{"a":"4","b":3.0,"c":2.1}"#, as: Box.self)
        XCTAssertEqual(box.a.value, 4)
        XCTAssertEqual(box.b.value, 3)
        XCTAssertEqual(box.c.value, "2.1")
    }
}

final class PairingTests: XCTestCase {
    func testPairsPapersWithTheirMemos() {
        let names = ["Paper 1 2023.pdf", "Paper 1 2023 Memo.pdf", "Paper 2 2023.pdf",
                     "Paper 2 2023 Memorandum.pdf", "Stray Memo.pdf"]
        let files = names.map { PickedPDF(name: $0, data: Data()) }
        let result = PaperPairing.pair(files)
        XCTAssertEqual(result.pairs.count, 2)
        XCTAssertTrue(result.pairs.allSatisfy { $0.memo != nil })
        XCTAssertEqual(result.spareMemos.count, 1)
    }
}
