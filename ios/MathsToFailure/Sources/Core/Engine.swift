import Foundation

/// The adaptive rules. Pure functions with no network or UI, so they can be unit tested.
enum Engine {
    static let levelDescriptions: [Int: String] = [
        1: "routine, one idea, 2 to 3 marks",
        2: "standard, two linked steps, 3 to 5 marks",
        3: "typical exam question, several steps, 5 to 7 marks",
        4: "hard, needs insight or combines ideas, 6 to 9 marks",
        5: "unfamiliar problem solving of the kind found at the end of an IEB paper, 8 to 12 marks",
    ]

    static func key(_ topic: String, _ skill: String) -> String { topic + "||" + skill }

    /// Updates a skill after one marked attempt.
    /// - Level rises on each pass until the first failure.
    /// - After a failure the level holds and the skill is pressed until two passes in a row.
    /// - Three failures in a row step the level down by one to rebuild.
    /// Returns whether the attempt counted as a failure (under 50%).
    @discardableResult
    static func apply(_ s: inout SkillState, fraction: Double, tags: [String], at date: Date = Date()) -> Bool {
        let failed = fraction < 0.5
        s.attempts += 1
        s.mastery = min(1, max(0, s.mastery * 0.6 + fraction * 0.4))
        s.lastAttemptAt = ISO8601DateFormatter().string(from: date)

        if fraction >= 0.75 {
            s.streak += 1
            s.failStreak = 0
            if s.failedAt == nil {
                s.level = min(5, s.level + 1)
            } else if s.streak >= 2 {
                s.level = min(5, s.level + 1)
                s.failedAt = nil
                s.streak = 0
            }
        } else if failed {
            s.failedAt = s.level
            s.streak = 0
            s.failStreak += 1
            if s.failStreak >= 3 && s.level > 1 {
                s.level -= 1
                s.failedAt = s.level
                s.failStreak = 0
            }
        } else {
            s.streak = 0
            s.failStreak = 0
        }

        if fraction < 0.75 {
            for t in tags { s.errors[t, default: 0] += 1 }
        }
        return failed
    }

    /// Weighted random choice that favours weak, failed and untested skills.
    static func weight(for s: SkillState, isLast: Bool) -> Double {
        var w = 0.15 + 2 * pow(1 - s.mastery, 2)
        if s.failedAt != nil { w += 1 }
        if s.attempts == 0 { w += 0.6 }
        if isLast { w *= 0.5 }
        return w
    }

    static func pickSkill(from skills: [SkillState], excluding: String? = nil, last: String? = nil, roll: Double = Double.random(in: 0..<1)) -> String? {
        let pool = skills.filter { $0.key != excluding }
        guard !pool.isEmpty else { return nil }
        let weights = pool.map { weight(for: $0, isLast: $0.key == last) }
        var r = roll * weights.reduce(0, +)
        for (i, w) in weights.enumerated() {
            r -= w
            if r <= 0 { return pool[i].key }
        }
        return pool[pool.count - 1].key
    }

    static func fraction(marks: Int, outOf: Int) -> Double {
        outOf > 0 ? Double(marks) / Double(outOf) : 0
    }
}
