import Foundation

// MARK: - Shapes the models return

struct ExtractedMemo: Decodable {
    var step: FlexString?
    var marks: FlexInt?
}

struct ExtractedQuestion: Decodable {
    var qnum: FlexString?
    var topic: String?
    var skill: String?
    var level: FlexInt?
    var marks: FlexInt?
    var question: String?
    var has_diagram: Bool?
    var memo: [ExtractedMemo]?
    var final_answer: FlexString?
}

private struct ExtractionDTO: Decodable {
    var questions: [ExtractedQuestion]?
    var style_notes: String?
}

private struct QuestionListDTO: Decodable {
    var questions: [FlexString]?
}

private struct GeneratedDTO: Decodable {
    var question: String?
    var marks: FlexInt?
    var memo: [ExtractedMemo]?
    var final_answer: FlexString?
    var form: String?
}

private struct SolveDTO: Decodable {
    var final_answer: FlexString?
}

private struct CompareDTO: Decodable {
    var agree: Bool?
}

private struct MarkDTO: Decodable {
    struct Line: Decodable {
        var line: FlexInt?
        var text: FlexString?
        var ok: Bool?
        var comment: String?
    }
    struct Award: Decodable {
        var line: FlexInt?
        var marks: FlexInt?
        var reason: String?
    }
    struct FirstErr: Decodable {
        var line: FlexInt?
        var what: String?
        var fix: String?
    }
    var legible: Bool?
    var transcription: [Line]?
    var awarded: [Award]?
    var first_error: FirstErr?
    var error_tags: [String]?
    var confidence: String?
}

struct GeneratedQuestion {
    var question: String
    var memo: [MemoStep]
    var marks: Int
    var finalAnswer: String
    var form: String
    var verified: Bool
    var checked: Bool
}

// MARK: - Service

/// Every model-backed job in the app: reading papers, writing and checking questions, marking.
final class TutorService {
    private let llm: LLMService

    init(llm: LLMService) { self.llm = llm }

    // Reading papers

    func listTopLevelQuestions(choice: ModelChoice, paper: Data) async throws -> [String] {
        let text = try await llm.complete(choice, system: Prompts.base,
                                          parts: [.pdf(paper, cache: false), .text(Prompts.listQuestions())],
                                          maxTokens: 1500)
        let dto = try LLMJSON.decode(text, as: QuestionListDTO.self)
        return (dto.questions ?? []).map { $0.value }
    }

    func extract(choice: ModelChoice, paper: Data, memo: Data, numbers: [String],
                 knownSkills: [String]) async throws -> (questions: [ExtractedQuestion], style: String) {
        let text = try await llm.complete(
            choice, system: Prompts.base,
            parts: [.pdf(paper, cache: false), .pdf(memo, cache: true),
                    .text(Prompts.extract(numbers: numbers, knownSkills: knownSkills))],
            maxTokens: 14000)
        let dto = try LLMJSON.decode(text, as: ExtractionDTO.self)
        return (dto.questions ?? [], dto.style_notes ?? "")
    }

    // Writing and checking questions

    func generate(choice: ModelChoice, topic: String, skill: String, level: Int, pressing: Bool, challenge: Bool,
                  errorTags: [String], examples: String, recent: [String]) async throws -> GeneratedQuestion {
        let prompt = Prompts.generate(topic: topic, skill: skill, level: level, pressing: pressing, challenge: challenge,
                                      errorTags: errorTags, examples: examples, recent: recent)
        let text = try await llm.complete(choice, system: Prompts.base, parts: [.text(prompt)], maxTokens: 3500)
        let dto = try LLMJSON.decode(text, as: GeneratedDTO.self)
        guard let q = dto.question, !q.isEmpty, let rawMemo = dto.memo, !rawMemo.isEmpty else {
            throw AppError.badResponse("The model returned an incomplete question. Try again.")
        }
        let memo = rawMemo.map { MemoStep(step: $0.step?.value ?? "", marks: $0.marks?.value ?? 0) }
        let total = memo.reduce(0) { $0 + $1.marks }
        return GeneratedQuestion(question: q, memo: memo, marks: max(total, 1),
                                 finalAnswer: dto.final_answer?.value ?? "", form: dto.form ?? "",
                                 verified: false, checked: false)
    }

    /// Solves the question blind, then compares with the memo's final answer.
    func verify(choice: ModelChoice, question: GeneratedQuestion) async throws -> Bool {
        let solvedText = try await llm.complete(choice, system: Prompts.base,
                                                parts: [.text(Prompts.solve(question: question.question))], maxTokens: 3500)
        let solved = try LLMJSON.decode(solvedText, as: SolveDTO.self)
        let cmpText = try await llm.complete(
            choice, system: Prompts.base,
            parts: [.text(Prompts.compare(question: question.question, memoAnswer: question.finalAnswer,
                                          independent: solved.final_answer?.value ?? ""))],
            maxTokens: 800)
        let cmp = try LLMJSON.decode(cmpText, as: CompareDTO.self)
        return cmp.agree ?? false
    }

    // Marking

    func mark(choice: ModelChoice, question: String, marks: Int, memo: [MemoStep], finalAnswer: String,
              images: [Data], typed: String, knownTags: [String], extra: String) async throws -> MarkResult {
        var parts: [Part] = images.map { .image($0) }
        parts.append(.text(Prompts.mark(question: question, marks: marks, memo: memo, finalAnswer: finalAnswer,
                                        typed: typed, knownTags: knownTags, extra: extra)))
        let text = try await llm.complete(choice, system: Prompts.base, parts: parts, maxTokens: 4500)
        let dto = try LLMJSON.decode(text, as: MarkDTO.self)
        return TutorService.normalise(dto, memo: memo)
    }

    private static func normalise(_ dto: MarkDTO, memo: [MemoStep]) -> MarkResult {
        let raw = dto.awarded ?? []
        var awarded: [AwardedLine] = []
        for (i, m) in memo.enumerated() {
            let match = raw.first(where: { ($0.line?.value ?? -1) == i + 1 }) ?? (i < raw.count ? raw[i] : nil)
            let given = match?.marks?.value ?? 0
            awarded.append(AwardedLine(line: i + 1, step: m.step, max: m.marks,
                                       marks: min(max(given, 0), m.marks), reason: match?.reason ?? ""))
        }
        let transcript = (dto.transcription ?? []).enumerated().map { i, l in
            TranscriptLine(line: l.line?.value ?? i + 1, text: l.text?.value ?? "", ok: l.ok ?? true, comment: l.comment ?? "")
        }
        var first: FirstError?
        if let f = dto.first_error, let what = f.what, !what.isEmpty {
            first = FirstError(line: f.line?.value, what: what, fix: f.fix ?? "")
        }
        let tags = (dto.error_tags ?? []).map { TutorService.cleanTag($0) }.filter { !$0.isEmpty }
        return MarkResult(legible: dto.legible ?? true, transcription: transcript, awarded: awarded,
                          total: awarded.reduce(0) { $0 + $1.marks }, firstError: first,
                          tags: Array(tags.prefix(5)), confidence: dto.confidence ?? "medium")
    }

    static func cleanTag(_ raw: String) -> String {
        var out = ""
        for ch in raw.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch) } else if !out.hasSuffix("_") { out.append("_") }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
