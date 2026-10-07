import SwiftUI
import PhotosUI
import UIKit

struct SessionTab: View {
    @EnvironmentObject var app: AppModel
    @State private var session: SessionController?
    @State private var mode: SessionController.Mode = .mixed

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    ActiveSessionView(session: session) { self.session = nil }
                } else {
                    idle
                }
            }
            .navigationTitle("Maths to Failure")
        }
        .onChange(of: app.pendingFocusKey) { _, _ in consumePending() }
        .onAppear { consumePending() }
    }

    private func consumePending() {
        guard let key = app.pendingFocusKey else { return }
        app.pendingFocusKey = nil
        start(focus: key)
    }

    private func start(focus: String?) {
        guard LLMService.hasKey(.claude) || LLMService.hasKey(.gemini) else {
            app.banner = "Add an API key in Settings first."
            app.selectedTab = .settings
            return
        }
        guard !app.skills.isEmpty else {
            app.banner = "Add a paper and its memorandum in Library first."
            app.selectedTab = .library
            return
        }
        let s = SessionController(app: app, minutes: app.settings.minutes, mode: mode, focusKey: focus)
        session = s
        s.start()
    }

    private var idle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    Text("Press until it breaks").font(.title2.bold())
                    Text("Pick a time limit. The app finds your weakest skills, raises the difficulty until you fail, then keeps asking about that exact skill in new forms until you hold it.")
                        .foregroundStyle(.secondary)

                    SectionLabel("Time limit")
                    Picker("Time limit", selection: Binding(
                        get: { app.settings.minutes },
                        set: { m in app.updateSettings { $0.minutes = m } }
                    )) {
                        ForEach([15, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.segmented)

                    SectionLabel("Questions")
                    Picker("Questions", selection: $mode) {
                        ForEach(SessionController.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(mode.detail).font(.footnote).foregroundStyle(.secondary)

                    Button { start(focus: nil) } label: {
                        Text("Start session").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(app.skills.isEmpty)

                    Text("\(app.skills.count) skills from \(app.questions.filter { $0.source == "paper" }.count) paper questions"
                         + (failedCount > 0 ? ", \(failedCount) at a failure point" : ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if app.skills.isEmpty {
                    CalloutBox(tint: .orange) {
                        Text("Nothing to practise yet").font(.headline)
                        Text("Go to Library, add your question papers with their memorandums, and the app will learn your questions.")
                    }
                }
                Text("Marking is done by an AI model reading your working. It marks against your memorandum, but it can still be wrong. If a mark looks wrong, use the disagree button on the result screen.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var failedCount: Int { app.skills.values.filter { $0.failedAt != nil }.count }
}

// MARK: - active session

struct ActiveSessionView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: SessionController
    var onClose: () -> Void

    @State private var showPencil = false
    @State private var showCamera = false
    @State private var showDispute = false
    @State private var showOverride = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if session.phase != .summary { header }
                switch session.phase {
                case .loading, .marking: progress
                case .error: errorView
                case .question: questionView
                case .unreadable: unreadableView
                case .result: resultView
                case .summary: summaryView
                }
            }
            .padding()
        }
        .alert("Notice", isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(session.notice ?? "") }
        .sheet(isPresented: $showPencil) {
            PencilSheet { session.addImage($0) }
        }
        #if !targetEnvironment(macCatalyst)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let jpeg = ImageTools.jpeg(from: image) { session.addImage(jpeg) }
            }
            .ignoresSafeArea()
        }
        #endif
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let jpeg = ImageTools.jpeg(from: data) {
                        session.addImage(jpeg)
                    }
                }
                photoItems = []
            }
        }
    }

    // MARK: header

    private var header: some View {
        Card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    if let cur = session.current, let skill = app.skills[cur.item.key] {
                        Text(skill.topic).font(.caption).foregroundStyle(.secondary)
                        Text(skill.skill).font(.headline)
                        GaugeView(level: skill.level, failedAt: skill.failedAt)
                    } else {
                        Text("Session in progress").font(.headline)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, session.endsAt.timeIntervalSince(context.date))
                        Text(String(format: "%02d:%02d", Int(left) / 60, Int(left) % 60))
                            .font(.title.monospacedDigit())
                            .foregroundStyle(left < 120 ? Theme.fail : Color.primary)
                    }
                    Button("End session", role: .destructive) { session.endSession() }
                        .buttonStyle(.bordered)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if context.date >= session.endsAt {
                    CalloutBox {
                        Text("Time is up. Finish the question you are on, then you will see your summary.")
                    }
                }
            }
        }
    }

    private var progress: some View {
        Card {
            Text(session.phase == .marking ? "Marking" : "Preparing").font(.title3.bold())
            ProgressView()
            Text(session.status).foregroundStyle(.secondary)
        }
    }

    private var errorView: some View {
        Card {
            Text("Something went wrong").font(.title3.bold())
            CalloutBox { Text(session.errorText) }
            HStack {
                Button("Try again") { session.nextQuestion() }.buttonStyle(.borderedProminent)
                Button("End session") { session.endSession() }.buttonStyle(.bordered)
            }
        }
    }

    // MARK: question

    private var questionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let cur = session.current {
                Card {
                    HStack {
                        Chip(text: "Level \(cur.item.level)")
                        if cur.item.fromPaper {
                            Chip(text: cur.item.form.isEmpty ? "From your papers" : "From your papers, Q\(cur.item.form)", tint: Theme.pass)
                        } else {
                            Chip(text: "New question")
                        }
                        if cur.item.checked && !cur.item.verified {
                            Chip(text: "Answer unconfirmed", tint: .orange)
                        }
                        Spacer()
                        Text("[\(cur.item.marks)]").font(.headline.monospacedDigit())
                    }
                    MathText(text: cur.item.question, fontSize: 19)
                }
                Card {
                    Text("Your working").font(.headline)
                    Text("Write it with Apple Pencil here, or photograph or screenshot work done elsewhere.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button { showPencil = true } label: { Label("Write with Pencil", systemImage: "pencil.tip") }
                            .buttonStyle(.borderedProminent)
                        PhotosPicker(selection: $photoItems, maxSelectionCount: 6, matching: .images) {
                            Label("Photos", systemImage: "photo")
                        }
                        .buttonStyle(.bordered)
                        #if !targetEnvironment(macCatalyst)
                        if CameraPicker.isAvailable {
                            Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                                .buttonStyle(.bordered)
                        }
                        #endif
                    }
                    if !cur.images.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(Array(cur.images.enumerated()), id: \.offset) { index, data in
                                    ZStack(alignment: .topTrailing) {
                                        if let ui = UIImage(data: data) {
                                            Image(uiImage: ui).resizable().scaledToFit()
                                                .frame(height: 150)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                                        }
                                        Button { session.removeImage(at: index) } label: {
                                            Image(systemName: "xmark.circle.fill").font(.title2)
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.7))
                                        }
                                        .padding(4)
                                    }
                                }
                            }
                        }
                    }
                    TextField("Final answer, typed (optional)", text: Binding(
                        get: { session.current?.typed ?? "" },
                        set: { session.current?.typed = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button { session.submit() } label: {
                        Text(session.isOver ? "Submit and finish" : "Submit for marking")
                            .font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(cur.images.isEmpty)
                }
            }
        }
    }

    private var unreadableView: some View {
        Card {
            Text("Could not read your work").font(.title3.bold())
            CalloutBox {
                Text("The handwriting was not clear enough to mark fairly, so nothing was recorded. Retake the photo with more light and the page flat, or write larger.")
            }
            Button("Add a new page") { session.current?.images = []; session.phase = .question }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: result

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let cur = session.current, let res = cur.result {
                let fraction = Engine.fraction(marks: res.total, outOf: cur.item.marks)
                Card {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(res.total)").font(.system(size: 54, weight: .heavy))
                        Text("/ \(cur.item.marks)").font(.title).foregroundStyle(.secondary)
                        Spacer()
                        if fraction >= 0.75 { Chip(text: "Held. Difficulty goes up.", tint: Theme.pass) }
                        else if fraction < 0.5 { Chip(text: "Failure point. This skill is pressed next.", tint: Theme.fail) }
                        else { Chip(text: "Partly there. Same level again.") }
                    }
                    if res.confidence == "low" {
                        Chip(text: "Low marking confidence. Check what was read below.", tint: .orange)
                    }
                    if cur.disputed { Chip(text: "Re-marked after your objection") }
                    if cur.overridden { Chip(text: "Self-assessed mark") }
                }

                if let fe = res.firstError {
                    CalloutBox {
                        Text("First mistake" + (fe.line.map { ", line \($0)" } ?? "")).font(.headline)
                        MathText(text: fe.what)
                        if !fe.fix.isEmpty {
                            SectionLabel("Correct step")
                            MathText(text: fe.fix)
                        }
                    }
                } else {
                    CalloutBox(tint: Theme.pass) { Text("No errors found in your working.") }
                }

                Card {
                    SectionLabel("What the marker read from your work")
                    Text("If a line is misread the marks may be wrong. Disagree or set your own mark below.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array(res.transcription.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(line.line)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                MathText(text: line.text)
                                if !line.comment.isEmpty {
                                    Text(line.comment).font(.footnote).foregroundStyle(line.ok ? Color.secondary : Theme.fail)
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((line.ok ? Color.secondary : Theme.fail).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                Card {
                    SectionLabel("Mark breakdown")
                    ForEach(res.awarded, id: \.line) { a in
                        HStack(alignment: .top) {
                            Text("\(a.line)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 22)
                            Text(a.reason.isEmpty ? a.step : a.reason).font(.subheadline)
                            Spacer()
                            Text("\(a.marks)/\(a.max)").font(.subheadline.monospacedDigit())
                        }
                    }
                    DisclosureGroup("Show the memorandum") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(cur.item.memo.enumerated()), id: \.offset) { i, m in
                                HStack(alignment: .top) {
                                    Text("\(i + 1).").font(.caption.monospaced())
                                    MathText(text: m.step)
                                    Text("[\(m.marks)]").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            MathText(text: "Final answer: " + cur.item.finalAnswer)
                        }
                        .padding(.top, 6)
                    }
                }

                Card {
                    Button { session.finishQuestion() } label: {
                        Text(session.isOver ? "Finish session" : "Next question").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    HStack {
                        Button("I disagree with the marking") { showDispute = true }.buttonStyle(.bordered)
                        Button("Set my own mark") { showOverride = true }.buttonStyle(.bordered)
                    }
                }
                .sheet(isPresented: $showDispute) { DisputeSheet { session.dispute(note: $0) } }
                .sheet(isPresented: $showOverride) {
                    OverrideSheet(maxMarks: cur.item.marks, current: res.total) { session.overrideMarks($0) }
                }
            }
        }
    }

    // MARK: summary

    private var summaryView: some View {
        let total = session.results.reduce(0) { $0 + $1.marks }
        let outOf = session.results.reduce(0) { $0 + $1.outOf }
        let fails = session.results.filter { $0.failed }
        let minutes = max(1, Int(Date().timeIntervalSince(session.startedAt) / 60))
        return VStack(alignment: .leading, spacing: 16) {
            Card {
                Text("Session summary").font(.title2.bold())
                HStack(alignment: .firstTextBaseline) {
                    Text("\(total)").font(.system(size: 54, weight: .heavy))
                    Text("/ \(outOf)").font(.title).foregroundStyle(.secondary)
                    Spacer()
                    Chip(text: "\(fails.count) failure point\(fails.count == 1 ? "" : "s") found", tint: fails.isEmpty ? Theme.pass : Theme.fail)
                }
                Text("\(session.results.count) questions in \(minutes) min").foregroundStyle(.secondary)
            }
            if !fails.isEmpty {
                Card {
                    SectionLabel("Where you broke")
                    ForEach(fails) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(f.skill) (level \(f.level))").font(.headline)
                            if !f.firstError.isEmpty { MathText(text: f.firstError, fontSize: 15) }
                        }
                    }
                }
            }
            if !session.results.isEmpty {
                Card {
                    SectionLabel("Questions")
                    ForEach(session.results) { r in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(r.skill)
                                Text("\(r.topic), level \(r.level)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(r.marks)/\(r.outOf)").monospacedDigit()
                        }
                    }
                }
            }
            HStack {
                Button { onClose() } label: { Text("Back to start").font(.headline) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("See weak spots") { onClose(); app.selectedTab = .weakSpots }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
    }
}

// MARK: - sheets

private struct DisputeSheet: View {
    var onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Why do you disagree?") {
                    TextEditor(text: $note).frame(minHeight: 140)
                }
                Section {
                    Text("For example: line 3 says x = 4 but I wrote x = -4. The marker will re-read your handwriting and mark again.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Dispute marking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Re-mark") { onSubmit(note.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }.bold()
                }
            }
        }
    }
}

private struct OverrideSheet: View {
    let maxMarks: Int
    var onSet: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: Int

    init(maxMarks: Int, current: Int, onSet: @escaping (Int) -> Void) {
        self.maxMarks = maxMarks
        self.onSet = onSet
        _value = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your mark") {
                    Stepper("\(value) out of \(maxMarks)", value: $value, in: 0...maxMarks)
                }
                Section {
                    Text("This is recorded as a self-assessed mark and still counts towards your skill levels.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Set my own mark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this mark") { onSet(value); dismiss() }.bold()
                }
            }
        }
    }
}
