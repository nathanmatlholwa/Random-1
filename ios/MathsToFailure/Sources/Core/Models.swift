import Foundation

enum Topics {
    static let all = [
        "Algebra, equations and inequalities",
        "Sequences and series",
        "Functions, graphs and inverses",
        "Finance, growth and decay",
        "Differential calculus",
        "Counting and probability",
        "Statistics and regression",
        "Analytical geometry",
        "Trigonometry",
        "Euclidean geometry",
    ]
}

struct MemoStep: Codable, Hashable {
    var step: String
    var marks: Int
}

// MARK: - Database rows (explicit coding keys, so error-tag dictionary keys are never rewritten)

struct Paper: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var paperPath: String?
    var memoPath: String?
    var styleNotes: String
    var status: String          // uploaded, extracting, done, failed
    var error: String?
    var questionCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, status, error
        case paperPath = "paper_path"
        case memoPath = "memo_path"
        case styleNotes = "style_notes"
        case questionCount = "question_count"
    }
}

struct Question: Codable, Identifiable, Hashable {
    var id: UUID
    var paperId: UUID?
    var qnum: String?
    var source: String          // paper or generated
    var topic: String
    var skill: String
    var level: Int
    var marks: Int
    var question: String
    var hasDiagram: Bool
    var memo: [MemoStep]
    var finalAnswer: String
    var verified: Bool

    var skillKey: String { Engine.key(topic, skill) }

    enum CodingKeys: String, CodingKey {
        case id, qnum, source, topic, skill, level, marks, question, memo, verified
        case paperId = "paper_id"
        case hasDiagram = "has_diagram"
        case finalAnswer = "final_answer"
    }
}

struct SkillState: Codable, Identifiable, Hashable {
    var id: UUID
    var topic: String
    var skill: String
    var level: Int = 1
    var mastery: Double = 0.5
    var attempts: Int = 0
    var streak: Int = 0
    var failStreak: Int = 0
    var failedAt: Int?
    var errors: [String: Int] = [:]
    var lastAttemptAt: String?

    var key: String { Engine.key(topic, skill) }

    enum CodingKeys: String, CodingKey {
        case id, topic, skill, level, mastery, attempts, streak, errors
        case failStreak = "fail_streak"
        case failedAt = "failed_at"
        case lastAttemptAt = "last_attempt_at"
    }

    /// failed_at must be sent as an explicit null when cleared, otherwise a PATCH would leave the old value.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(topic, forKey: .topic)
        try c.encode(skill, forKey: .skill)
        try c.encode(level, forKey: .level)
        try c.encode(mastery, forKey: .mastery)
        try c.encode(attempts, forKey: .attempts)
        try c.encode(streak, forKey: .streak)
        try c.encode(failStreak, forKey: .failStreak)
        try c.encode(failedAt, forKey: .failedAt)
        try c.encode(errors, forKey: .errors)
        try c.encodeIfPresent(lastAttemptAt, forKey: .lastAttemptAt)
    }
}

struct TranscriptLine: Codable, Hashable {
    var line: Int
    var text: String
    var ok: Bool
    var comment: String
}

struct AttemptRow: Codable, Identifiable, Hashable {
    var id: UUID
    var skillId: UUID
    var questionId: UUID?
    var questionText: String
    var generated: Bool
    var level: Int
    var marks: Int
    var outOf: Int
    var tags: [String]
    var firstError: String?
    var transcription: [TranscriptLine]?
    var disputed: Bool
    var overridden: Bool
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, generated, level, marks, tags, transcription, disputed, overridden
        case skillId = "skill_id"
        case questionId = "question_id"
        case questionText = "question_text"
        case outOf = "out_of"
        case firstError = "first_error"
        case createdAt = "created_at"
    }
}

// MARK: - Marking results (in memory)

struct AwardedLine: Hashable {
    var line: Int
    var step: String
    var max: Int
    var marks: Int
    var reason: String
}

struct FirstError: Hashable {
    var line: Int?
    var what: String
    var fix: String
}

struct MarkResult {
    var legible: Bool
    var transcription: [TranscriptLine]
    var awarded: [AwardedLine]
    var total: Int
    var firstError: FirstError?
    var tags: [String]
    var confidence: String
}
