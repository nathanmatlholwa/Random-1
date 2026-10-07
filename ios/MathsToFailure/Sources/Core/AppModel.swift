import Foundation
import SwiftUI
import UIKit

enum AppTab: Hashable {
    case session, weakSpots, library, settings
}

/// Non-secret preferences. API keys are never stored here; they live in the Keychain.
struct AppSettings: Codable {
    /// One model for every job, or a separate model per job.
    var useOneModel = true
    var allModel = ModelChoice(provider: .claude, model: ModelCatalog.defaultModel(for: .claude))
    var roles: [String: ModelChoice] = [:]
    /// Model ids the user added because the provider has released something newer than the built-in list.
    var customModels: [ModelChoice] = []
    var verify = true
    var minutes = 30

    private static let storageKey = "mtf.settings.v1"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useOneModel = try c.decodeIfPresent(Bool.self, forKey: .useOneModel) ?? true
        allModel = try c.decodeIfPresent(ModelChoice.self, forKey: .allModel) ?? allModel
        roles = try c.decodeIfPresent([String: ModelChoice].self, forKey: .roles) ?? [:]
        customModels = try c.decodeIfPresent([ModelChoice].self, forKey: .customModels) ?? []
        verify = try c.decodeIfPresent(Bool.self, forKey: .verify) ?? true
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 30
    }

    func choice(for role: Role) -> ModelChoice {
        useOneModel ? allModel : (roles[role.rawValue] ?? role.defaultChoice)
    }

    static func load() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return s
        }
        return AppSettings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.storageKey)
        }
    }
}

private struct SeenRow: Decodable {
    let question_id: UUID?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var booting = true
    @Published var isSignedIn = false
    @Published var email: String?
    @Published var isLoading = false

    @Published var papers: [Paper] = []
    @Published var questions: [Question] = []
    @Published var skills: [String: SkillState] = [:]
    @Published var attempts: [AttemptRow] = []
    @Published var seenQuestionIDs: Set<UUID> = []

    @Published var settings: AppSettings
    @Published var selectedTab: AppTab = .session
    @Published var pendingFocusKey: String?
    @Published var banner: String?

    @Published var ingestBusy = false
    @Published var ingestStatus = ""
    @Published var ingestLog: [String] = []
    @Published var ingestDone = 0
    @Published var ingestTotal = 0
    private var ingestTask: Task<Void, Never>?

    let sb = SupabaseClient()
    let llm: LLMService
    let tutor: TutorService

    init() {
        let service = LLMService()
        self.llm = service
        self.tutor = TutorService(llm: service)
        self.settings = AppSettings.load()
    }

    // MARK: - settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var s = settings
        change(&s)
        settings = s
        s.save()
    }

    /// The model to use for a job. If the chosen provider has no key but the other does, the other is used.
    func choice(for role: Role) -> ModelChoice {
        let chosen = settings.choice(for: role)
        if LLMService.hasKey(chosen.provider) { return chosen }
        let other: Provider = chosen.provider == .claude ? .gemini : .claude
        if LLMService.hasKey(other) {
            return ModelChoice(provider: other, model: ModelCatalog.defaultModel(for: other))
        }
        return chosen
    }

    func report(_ error: Error) {
        if case AppError.notSignedIn = error { isSignedIn = false }
        banner = error.localizedDescription
    }

    // MARK: - account

    func bootstrap() async {
        isSignedIn = await sb.isSignedIn
        email = await sb.email
        if isSignedIn { await reload() }
        booting = false
    }

    func signIn(email: String, password: String) async throws {
        try await sb.signIn(email: email, password: password)
        self.email = await sb.email
        isSignedIn = true
        await reload()
    }

    /// Returns false when Supabase needs the email confirmed before signing in.
    func signUp(email: String, password: String) async throws -> Bool {
        let signedIn = try await sb.signUp(email: email, password: password)
        if signedIn {
            self.email = await sb.email
            isSignedIn = true
            await reload()
        }
        return signedIn
    }

    func signOut() async {
        await sb.signOut()
        isSignedIn = false
        email = nil
        papers = []; questions = []; skills = [:]; attempts = []; seenQuestionIDs = []
    }

    // MARK: - loading

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            papers = try await sb.selectAll("papers", query: [URLQueryItem(name: "order", value: "created_at.asc")], as: Paper.self)
            questions = try await sb.selectAll("questions", query: [URLQueryItem(name: "order", value: "created_at.asc")], as: Question.self)
            try await loadSkills()
            let recent = try await sb.rest("GET", "attempts", query: [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "150"),
            ])
            attempts = Array(try JSONDecoder().decode([AttemptRow].self, from: recent).reversed())
            let seen = try await sb.selectAll("attempts", query: [
                URLQueryItem(name: "select", value: "question_id"),
                URLQueryItem(name: "question_id", value: "not.is.null"),
            ], as: SeenRow.self)
            seenQuestionIDs = Set(seen.compactMap { $0.question_id })
        } catch {
            report(error)
        }
    }

    private func loadSkills() async throws {
        let rows = try await sb.selectAll("skills", query: [URLQueryItem(name: "order", value: "topic.asc")], as: SkillState.self)
        skills = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - helpers for the session

    var allErrorTags: [String] {
        var set = Set<String>()
        for s in skills.values { for k in s.errors.keys { set.insert(k) } }
        return Array(set.sorted().prefix(30))
    }

    func styleExamples(topic: String, skill: String) -> String {
        let same = questions.filter { $0.source == "paper" && $0.topic == topic }
        let ordered = same.sorted { ($0.skill == skill ? 0 : 1) < ($1.skill == skill ? 0 : 1) }
        let text = ordered.prefix(3).map { "Marks \($0.marks), level \($0.level): \($0.question)" }.joined(separator: "\n---\n")
        return text.isEmpty ? "(none)" : text
    }

    func recentQuestions(for skill: SkillState) -> [String] {
        attempts.filter { $0.skillId == skill.id }.suffix(5).map { $0.questionText }
    }

    func saveGenerated(topic: String, skill: String, level: Int, generated g: GeneratedQuestion) async throws -> Question {
        let q = Question(id: UUID(), paperId: nil, qnum: nil, source: "generated", topic: topic, skill: skill,
                         level: level, marks: g.marks, question: g.question, hasDiagram: false, memo: g.memo,
                         finalAnswer: g.finalAnswer, verified: g.verified)
        _ = try await sb.insert("questions", rows: [q])
        questions.append(q)
        return q
    }

    /// Applies the marked attempt to the skill and saves both to Supabase.
    func recordAttempt(skillKey: String, questionId: UUID?, questionText: String, generated: Bool, level: Int,
                       result: MarkResult, outOf: Int, disputed: Bool, overridden: Bool) async -> (failed: Bool, fraction: Double) {
        guard var s = skills[skillKey] else { return (false, 0) }
        let fraction = Engine.fraction(marks: result.total, outOf: outOf)
        let failed = Engine.apply(&s, fraction: fraction, tags: result.tags)
        skills[skillKey] = s
        let row = AttemptRow(id: UUID(), skillId: s.id, questionId: questionId, questionText: String(questionText.prefix(1500)),
                             generated: generated, level: level, marks: result.total, outOf: outOf, tags: result.tags,
                             firstError: result.firstError?.what, transcription: result.transcription,
                             disputed: disputed, overridden: overridden, createdAt: nil)
        attempts.append(row)
        if let q = questionId { seenQuestionIDs.insert(q) }
        do {
            try await sb.update("skills", id: s.id, row: s)
            _ = try await sb.insert("attempts", rows: [row])
        } catch {
            report(error)
        }
        return (failed, fraction)
    }

    // MARK: - papers

    private func log(_ text: String) { ingestLog.append(text) }

    /// Uploads each pair, then reads it in small chunks of questions so replies never overflow.
    /// Starts the batch in the background. It keeps running if you switch tabs.
    func startIngest(pairs: [StagedPair]) {
        guard !ingestBusy else { return }
        ingestBusy = true          // set now so the screen reacts the instant the button is pressed
        ingestLog = []
        ingestDone = 0
        ingestTotal = pairs.filter { $0.paper != nil && $0.memo != nil }.count
        ingestStatus = "Starting..."
        ingestTask = Task { await ingest(pairs: pairs) }
    }

    func cancelIngest() {
        ingestTask?.cancel()
        ingestStatus = "Stopping after the current step..."
    }

    private func ingest(pairs: [StagedPair]) async {
        // Keep the screen awake: iOS pauses network work once the app is no longer in front.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            ingestBusy = false
            ingestStatus = ""
            ingestTask = nil
        }
        for pair in pairs {
            if Task.isCancelled { log("Stopped. Papers already finished are kept."); break }
            guard let paper = pair.paper, let memo = pair.memo else {
                log("Skipped \(pair.name): it has no memorandum.")
                continue
            }
            do {
                let count = try await ingestOne(name: pair.name, paperData: paper.data, memoData: memo.data)
                log("\(pair.name): added \(count) questions.")
            } catch {
                if Task.isCancelled {
                    log("\(pair.name): stopped before it finished. Use Read again to finish it later.")
                    break
                }
                log("\(pair.name) failed: \(error.localizedDescription)")
                if case AppError.notSignedIn = error { report(error); break }
            }
            ingestDone += 1
        }
        try? await loadSkills()
    }

    private func ingestOne(name: String, paperData: Data, memoData: Data) async throws -> Int {
        guard let uid = await sb.userId else { throw AppError.notSignedIn }
        var finalName = name
        var n = 2
        while papers.contains(where: { $0.name == finalName }) { finalName = "\(name) (\(n))"; n += 1 }
        let pid = UUID()
        let stem = "\(uid)/\(pid.uuidString.lowercased())"
        ingestStatus = "\(finalName): uploading"
        try await sb.upload(path: stem + "-paper.pdf", data: paperData)
        try await sb.upload(path: stem + "-memo.pdf", data: memoData)
        let paper = Paper(id: pid, name: finalName, paperPath: stem + "-paper.pdf", memoPath: stem + "-memo.pdf",
                          styleNotes: "", status: "extracting", error: nil, questionCount: 0)
        _ = try await sb.insert("papers", rows: [paper])
        papers.append(paper)
        return try await extractPaper(id: pid, paperData: paperData, memoData: memoData)
    }

    private func extractPaper(id: UUID, paperData: Data, memoData: Data) async throws -> Int {
        guard let name = papers.first(where: { $0.id == id })?.name else { return 0 }
        do {
            let model = choice(for: .extraction)
            ingestStatus = "\(name): finding the questions"
            let numbers = try await tutor.listTopLevelQuestions(choice: model, paper: paperData)
            guard !numbers.isEmpty else { throw AppError.message("No questions were found in this paper.") }
            let chunks = stride(from: 0, to: numbers.count, by: 2).map { Array(numbers[$0..<min($0 + 2, numbers.count)]) }
            var total = 0
            var style = ""
            for (i, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                ingestStatus = "\(name): reading question \(chunk.joined(separator: " and ")) (part \(i + 1) of \(chunks.count))"
                let known = skills.values.map { "\($0.topic) :: \($0.skill)" }
                let result = try await tutor.extract(choice: model, paper: paperData, memo: memoData,
                                                     numbers: chunk, knownSkills: Array(known.prefix(80)))
                if style.isEmpty { style = result.style }
                let rows = result.questions.compactMap { makeQuestion($0, paperID: id) }
                if rows.isEmpty { continue }
                let data = try await sb.insert("questions", rows: rows, onConflict: "paper_id,qnum", ignoreDuplicates: true)
                let saved = try JSONDecoder().decode([Question].self, from: data)
                questions.append(contentsOf: saved)
                total += saved.count
                try await ensureSkills(for: saved)
            }
            try await patchPaper(id, ["status": "done", "error": NSNull(), "question_count": total, "style_notes": style])
            return total
        } catch {
            let reason = (error is CancellationError || Task.isCancelled) ? "Stopped before it finished." : error.localizedDescription
            try? await patchPaper(id, ["status": "failed", "error": reason])
            throw error
        }
    }

    private func patchPaper(_ id: UUID, _ fields: [String: Any]) async throws {
        let body = try JSONSerialization.data(withJSONObject: fields)
        _ = try await sb.rest("PATCH", "papers", query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")],
                              body: body, prefer: ["return=minimal"])
        if let i = papers.firstIndex(where: { $0.id == id }) {
            if let s = fields["status"] as? String { papers[i].status = s }
            if let c = fields["question_count"] as? Int { papers[i].questionCount = c }
            if let st = fields["style_notes"] as? String { papers[i].styleNotes = st }
            if fields["error"] is NSNull { papers[i].error = nil }
            else if let e = fields["error"] as? String { papers[i].error = e }
        }
    }

    private func makeQuestion(_ e: ExtractedQuestion, paperID: UUID) -> Question? {
        guard let text = e.question, !text.isEmpty, let rawMemo = e.memo, !rawMemo.isEmpty else { return nil }
        let memo = rawMemo.map { MemoStep(step: $0.step?.value ?? "", marks: max(0, $0.marks?.value ?? 0)) }
        let sum = memo.reduce(0) { $0 + $1.marks }
        let marks = sum > 0 ? sum : (e.marks?.value ?? 0)
        guard marks > 0 else { return nil }
        let topic = (e.topic ?? "").isEmpty ? Topics.all[0] : (e.topic ?? Topics.all[0])
        let skill = (e.skill ?? "").isEmpty ? "General" : (e.skill ?? "General")
        let level = min(5, max(1, e.level?.value ?? 3))
        return Question(id: UUID(), paperId: paperID, qnum: e.qnum?.value, source: "paper", topic: topic, skill: skill,
                        level: level, marks: marks, question: text, hasDiagram: e.has_diagram ?? false, memo: memo,
                        finalAnswer: e.final_answer?.value ?? "", verified: true)
    }

    private func ensureSkills(for qs: [Question]) async throws {
        var fresh: [SkillState] = []
        var queued = Set<String>()
        for q in qs where skills[q.skillKey] == nil && !queued.contains(q.skillKey) {
            queued.insert(q.skillKey)
            fresh.append(SkillState(id: UUID(), topic: q.topic, skill: q.skill))
        }
        guard !fresh.isEmpty else { return }
        _ = try await sb.insert("skills", rows: fresh, onConflict: "user_id,topic,skill", ignoreDuplicates: true)
        try await loadSkills()
    }

    /// Downloads the stored PDFs again and re-reads them, for example after switching to a stronger model.
    func reextract(_ paper: Paper) async {
        guard !ingestBusy, let pp = paper.paperPath, let mp = paper.memoPath else { return }
        ingestBusy = true
        ingestLog = []
        defer { ingestBusy = false; ingestStatus = "" }
        do {
            ingestStatus = "\(paper.name): downloading"
            let paperData = try await sb.download(path: pp)
            let memoData = try await sb.download(path: mp)
            _ = try await sb.rest("DELETE", "questions", query: [URLQueryItem(name: "paper_id", value: "eq.\(paper.id.uuidString.lowercased())")],
                                  prefer: ["return=minimal"])
            questions.removeAll { $0.paperId == paper.id }
            try await patchPaper(paper.id, ["status": "extracting", "error": NSNull(), "question_count": 0])
            let count = try await extractPaper(id: paper.id, paperData: paperData, memoData: memoData)
            log("\(paper.name): added \(count) questions.")
        } catch {
            log("\(paper.name) failed: \(error.localizedDescription)")
        }
    }

    func deletePaper(_ paper: Paper) async {
        do {
            try await sb.removeFiles(paths: [paper.paperPath, paper.memoPath].compactMap { $0 })
            try await sb.delete("papers", id: paper.id)    // questions are removed by the foreign key
            papers.removeAll { $0.id == paper.id }
            questions.removeAll { $0.paperId == paper.id }
        } catch {
            report(error)
        }
    }

    func questionCount(for paper: Paper) -> Int {
        questions.filter { $0.paperId == paper.id }.count
    }
}
