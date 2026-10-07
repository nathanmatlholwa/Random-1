import Foundation
import SwiftUI

/// Runs one timed practice session: picks what to press, prepares questions, marks work, and records results.
@MainActor
final class SessionController: ObservableObject {
    enum Phase { case loading, question, marking, result, unreadable, error, summary }

    enum Mode: String, CaseIterable, Identifiable {
        case mixed, papersOnly, challenge
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mixed: return "Mixed"
            case .papersOnly: return "My papers"
            case .challenge: return "Challenge"
            }
        }
        var detail: String {
            switch self {
            case .mixed: return "Questions from your papers and new ones aimed at your weak skills."
            case .papersOnly: return "Only questions taken from the papers you uploaded."
            case .challenge: return "Always new, hard questions written for you, at the top difficulty."
            }
        }
    }

    struct Item {
        var question: String
        var marks: Int
        var memo: [MemoStep]
        var finalAnswer: String
        var form: String
        var verified: Bool
        var checked: Bool
        var bankID: UUID?
        var fromPaper: Bool
        var key: String
        var topic: String
        var skill: String
        var level: Int
    }

    struct Current {
        var item: Item
        var images: [Data] = []
        var typed = ""
        var result: MarkResult?
        var disputed = false
        var overridden = false
    }

    struct Done: Identifiable {
        let id = UUID()
        var skill: String
        var topic: String
        var level: Int
        var marks: Int
        var outOf: Int
        var failed: Bool
        var firstError: String
    }

    @Published var phase: Phase = .loading
    @Published var status = "Choosing what to press..."
    @Published var current: Current?
    @Published var errorText = ""
    @Published var notice: String?
    @Published var results: [Done] = []

    let startedAt = Date()
    let endsAt: Date
    let focusKey: String?
    let mode: Mode

    private let app: AppModel
    private var lastKey: String?
    private var pressCount = 0
    private var queuedKey: String?
    private var queuedTask: Task<Item, Error>?
    private var ended = false
    private var committing = false

    init(app: AppModel, minutes: Int, mode: Mode, focusKey: String?) {
        self.app = app
        self.endsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        self.mode = mode
        self.focusKey = focusKey
    }

    var isOver: Bool { Date() >= endsAt }

    func start() { nextQuestion() }

    // MARK: - choosing and preparing

    private func eligibleSkills() -> [SkillState] {
        let all = Array(app.skills.values)
        guard mode == .papersOnly else { return all }
        return all.filter { s in
            app.questions.contains { $0.source == "paper" && $0.skillKey == s.key && !$0.hasDiagram }
        }
    }

    private func pickKey(excluding: String?) -> String? {
        Engine.pickSkill(from: eligibleSkills(), excluding: excluding, last: lastKey)
    }

    func nextQuestion() {
        phase = .loading
        status = "Choosing what to press..."
        Task { await loadNext() }
    }

    private func targetLevel(for key: String) -> Int {
        mode == .challenge ? 5 : (app.skills[key]?.level ?? 1)
    }

    private func loadNext() async {
        do {
            // After a failure, keep pressing the same skill (up to four questions in a row).
            var press = false
            if focusKey == nil, let lk = lastKey, let s = app.skills[lk], s.failedAt != nil, pressCount < 4 {
                press = true
            }
            let key: String
            if let f = focusKey {
                key = f
            } else if press, let k = lastKey {
                key = k
            } else if let q = queuedKey {
                key = q
            } else if let k = pickKey(excluding: nil) {
                key = k
            } else {
                throw AppError.message("There are no skills to practise yet. Add a paper in Library first.")
            }
            pressCount = press ? pressCount + 1 : 0

            var item: Item?
            if let task = queuedTask, queuedKey == key {
                status = "Loading the next question..."
                item = try? await task.value
                queuedTask = nil
                queuedKey = nil
                if let i = item, i.level != targetLevel(for: key) { item = nil }
            }
            if item == nil {
                item = try await prepare(key: key) { [weak self] text in self?.status = text }
            }
            guard !ended, var ready = item else { return }

            if !ready.fromPaper && ready.bankID == nil {
                let g = GeneratedQuestion(question: ready.question, memo: ready.memo, marks: ready.marks,
                                          finalAnswer: ready.finalAnswer, form: ready.form,
                                          verified: ready.verified, checked: ready.checked)
                if let saved = try? await app.saveGenerated(topic: ready.topic, skill: ready.skill, level: ready.level, generated: g) {
                    ready.bankID = saved.id
                }
            }
            lastKey = key
            current = Current(item: ready)
            phase = .question
            prefetch(after: key)
        } catch {
            guard !ended else { return }
            errorText = error.localizedDescription
            phase = .error
        }
    }

    private func prefetch(after key: String) {
        let next = focusKey ?? pickKey(excluding: key)
        guard let nextKey = next else { return }
        queuedKey = nextKey
        queuedTask = Task { [weak self] () -> Item in
            guard let self = self else { throw AppError.message("Session ended.") }
            return try await self.prepare(key: nextKey, report: nil)
        }
    }

    private func item(from q: Question, key: String, skill: SkillState) -> Item {
        Item(question: q.question, marks: q.marks, memo: q.memo, finalAnswer: q.finalAnswer,
             form: "\(q.qnum ?? "")", verified: true, checked: false, bankID: q.id, fromPaper: true,
             key: key, topic: skill.topic, skill: skill.skill, level: q.level)
    }

    private func prepare(key: String, report: ((String) -> Void)?) async throws -> Item {
        guard let s = app.skills[key] else { throw AppError.message("That skill no longer exists.") }
        let level = targetLevel(for: key)
        let candidates = app.questions.filter { $0.source == "paper" && $0.skillKey == key && !$0.hasDiagram }
        let unseen = candidates.filter { !app.seenQuestionIDs.contains($0.id) && abs($0.level - level) <= 1 }

        switch mode {
        case .papersOnly:
            let pool = unseen.isEmpty ? candidates : unseen
            if let q = pool.randomElement() { return item(from: q, key: key, skill: s) }
        case .mixed:
            if s.failedAt == nil, let q = unseen.randomElement(), Bool.random() {
                return item(from: q, key: key, skill: s)
            }
        case .challenge:
            break
        }
        return try await generateItem(skill: s, level: level, report: report)
    }

    private func generateItem(skill s: SkillState, level: Int, report: ((String) -> Void)?) async throws -> Item {
        let genChoice = app.choice(for: .generation)
        let verifyChoice = app.choice(for: .verification)
        let verify = app.settings.verify
        let tries = verify ? 3 : 1
        let tags = s.errors.sorted { $0.value > $1.value }.prefix(4).map { $0.key }
        let examples = app.styleExamples(topic: s.topic, skill: s.skill)
        let recent = app.recentQuestions(for: s)
        var last: GeneratedQuestion?
        for attempt in 0..<tries {
            report?(attempt == 0 ? "Writing a question aimed at your weak point..."
                                 : "The answer check failed. Writing another (\(attempt + 1) of \(tries))...")
            var g = try await app.tutor.generate(choice: genChoice, topic: s.topic, skill: s.skill, level: level,
                                                 pressing: s.failedAt != nil, challenge: mode == .challenge,
                                                 errorTags: Array(tags), examples: examples, recent: recent)
            if verify {
                report?("Checking the memorandum by solving it independently...")
                g.verified = try await app.tutor.verify(choice: verifyChoice, question: g)
                g.checked = true
            }
            last = g
            if !verify || g.verified { break }
        }
        guard let g = last else { throw AppError.message("Could not write a question. Try again.") }
        return Item(question: g.question, marks: g.marks, memo: g.memo, finalAnswer: g.finalAnswer, form: g.form,
                    verified: g.verified, checked: g.checked, bankID: nil, fromPaper: false,
                    key: s.key, topic: s.topic, skill: s.skill, level: level)
    }

    // MARK: - working and marking

    func addImage(_ jpeg: Data) { current?.images.append(jpeg) }
    func removeImage(at index: Int) {
        guard let c = current, c.images.indices.contains(index) else { return }
        current?.images.remove(at: index)
    }

    func submit() {
        guard let cur = current else { return }
        guard !cur.images.isEmpty else { notice = "Add your working first."; return }
        phase = .marking
        status = "Reading your handwriting and marking against the memorandum..."
        Task {
            do {
                let r = try await app.tutor.mark(
                    choice: app.choice(for: .marking), question: cur.item.question, marks: cur.item.marks,
                    memo: cur.item.memo, finalAnswer: cur.item.finalAnswer, images: cur.images,
                    typed: cur.typed.trimmingCharacters(in: .whitespacesAndNewlines),
                    knownTags: app.allErrorTags, extra: "")
                guard !ended else { return }
                current?.result = r
                phase = r.legible ? .result : .unreadable
            } catch {
                guard !ended else { return }
                phase = .question
                notice = error.localizedDescription
            }
        }
    }

    func dispute(note: String) {
        guard let cur = current, let prev = cur.result else { return }
        phase = .marking
        status = "Re-marking with your objection..."
        let lines = prev.transcription.map { "\($0.line): \($0.text)" }.joined(separator: "\n")
        let marks = prev.awarded.map { "line \($0.line): \($0.marks)/\($0.max)" }.joined(separator: ", ")
        let extra = """
        The student disputes the first marking.
        Previous transcription:
        \(lines)
        Previous marks: \(marks)
        Student's objection: \(note.isEmpty ? "(no reason given)" : note)
        Re-mark from the images, independently. Re-read the handwriting rather than trusting the earlier transcription. Change the marks only where the working justifies it.

        """
        Task {
            do {
                let r = try await app.tutor.mark(
                    choice: app.choice(for: .marking), question: cur.item.question, marks: cur.item.marks,
                    memo: cur.item.memo, finalAnswer: cur.item.finalAnswer, images: cur.images,
                    typed: cur.typed.trimmingCharacters(in: .whitespacesAndNewlines),
                    knownTags: app.allErrorTags, extra: extra)
                guard !ended else { return }
                current?.result = r
                current?.disputed = true
            } catch {
                notice = error.localizedDescription
            }
            if !ended { phase = .result }
        }
    }

    func overrideMarks(_ value: Int) {
        guard let cur = current else { return }
        let v = min(max(value, 0), cur.item.marks)
        current?.result?.total = v
        if v >= cur.item.marks { current?.result?.firstError = nil }
        current?.overridden = true
    }

    // MARK: - finishing

    private func commitCurrent() async {
        guard let cur = current, let res = cur.result, !committing else { return }
        committing = true
        let out = await app.recordAttempt(
            skillKey: cur.item.key, questionId: cur.item.bankID, questionText: cur.item.question,
            generated: !cur.item.fromPaper, level: cur.item.level, result: res, outOf: cur.item.marks,
            disputed: cur.disputed, overridden: cur.overridden)
        results.append(Done(skill: cur.item.skill, topic: cur.item.topic, level: cur.item.level, marks: res.total,
                            outOf: cur.item.marks, failed: out.failed, firstError: res.firstError?.what ?? ""))
        current?.result = nil
        committing = false
    }

    func finishQuestion() {
        Task {
            await commitCurrent()
            if isOver { phase = .summary } else { nextQuestion() }
        }
    }

    func endSession() {
        ended = true
        queuedTask?.cancel()
        Task {
            if phase == .result { await commitCurrent() }
            phase = .summary
        }
    }
}
