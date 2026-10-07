import SwiftUI
import UniformTypeIdentifiers

struct LibraryTab: View {
    @EnvironmentObject var app: AppModel
    @State private var picking = false
    @State private var staged: [StagedPair] = []
    @State private var spare: [PickedPDF] = []
    @State private var pickError: String?
    @State private var toDelete: Paper?

    private var readyPairs: [StagedPair] { staged.filter { $0.paper != nil && $0.memo != nil } }
    private var paperQuestions: [Question] { app.questions.filter { $0.source == "paper" } }

    var body: some View {
        NavigationStack {
            List {
                importSection
                if !staged.isEmpty || !spare.isEmpty { stagedSection }
                if app.ingestBusy || !app.ingestLog.isEmpty { progressSection }
                papersSection
                bankSection
            }
            .navigationTitle("Library")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                handle(result)
            }
            .confirmationDialog("Delete this paper?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                                titleVisibility: .visible, presenting: toDelete) { paper in
                Button("Delete paper and its questions", role: .destructive) {
                    Task { await app.deletePaper(paper) }
                }
            } message: { paper in
                Text("\(paper.name) and the questions taken from it will be removed. Your progress is kept.")
            }
            .alert("Could not open files", isPresented: Binding(get: { pickError != nil }, set: { if !$0 { pickError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(pickError ?? "") }
        }
    }

    // MARK: sections

    private var importSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add as many question papers as you like. Choose the papers and their memorandums together. The app matches them by file name, uploads the originals to your private storage, and reads every question and mark allocation.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { picking = true } label: {
                    Label("Choose PDFs", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.ingestBusy)
            }
            .padding(.vertical, 4)
        } header: { Text("Add papers") }
    }

    private var stagedSection: some View {
        Section {
            ForEach($staged) { $pair in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $pair.name).font(.headline)
                    HStack {
                        Image(systemName: "doc.text")
                        Text(pair.paper?.name ?? "").lineLimit(1).font(.footnote)
                    }
                    if let memo = pair.memo {
                        HStack {
                            Image(systemName: "checkmark.seal").foregroundStyle(Theme.pass)
                            Text(memo.name).lineLimit(1).font(.footnote)
                        }
                    } else {
                        Menu {
                            ForEach(spare) { m in
                                Button(m.name) { assign(m, to: pair.id) }
                            }
                        } label: {
                            Label(spare.isEmpty ? "No memorandum found" : "Choose its memorandum", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .disabled(spare.isEmpty)
                    }
                }
            }
            .onDelete { staged.remove(atOffsets: $0) }

            if !spare.isEmpty {
                Text("Unmatched memorandums: " + spare.map { $0.name }.joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                let pairs = readyPairs
                staged = []
                spare = []
                Task { await app.ingest(pairs: pairs) }
            } label: {
                Text(readyPairs.isEmpty ? "Nothing ready yet" : "Upload and read \(readyPairs.count) paper\(readyPairs.count == 1 ? "" : "s")")
                    .bold()
            }
            .disabled(readyPairs.isEmpty || app.ingestBusy)
        } header: { Text("Ready to add") } footer: {
            Text("Reading a paper takes a minute or two and uses your API key. Swipe a row to remove it.")
        }
    }

    private var progressSection: some View {
        Section("Progress") {
            if app.ingestBusy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(app.ingestStatus).font(.subheadline)
                }
            }
            ForEach(Array(app.ingestLog.enumerated()), id: \.offset) { _, line in
                Text(line).font(.footnote.monospaced())
            }
        }
    }

    private var papersSection: some View {
        Section("Your papers") {
            if app.papers.isEmpty {
                Text("No papers yet.").foregroundStyle(.secondary)
            }
            ForEach(app.papers) { paper in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(paper.name).font(.headline)
                        Spacer()
                        statusChip(paper)
                    }
                    Text("\(app.questionCount(for: paper)) questions").font(.footnote).foregroundStyle(.secondary)
                    if let e = paper.error, paper.status == "failed" {
                        Text(e).font(.footnote).foregroundStyle(Theme.fail)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { toDelete = paper }
                    Button("Read again") { Task { await app.reextract(paper) } }.tint(.blue)
                }
            }
        }
    }

    private var bankSection: some View {
        Section {
            let diagrams = paperQuestions.filter { $0.hasDiagram }.count
            Text("\(paperQuestions.count) questions from your papers across \(app.skills.count) skills.")
            if diagrams > 0 {
                Text("\(diagrams) need a figure, so they are used as style examples only and are never asked directly.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Topics.all, id: \.self) { topic in
                let n = paperQuestions.filter { $0.topic == topic }.count
                if n > 0 {
                    HStack { Text(topic); Spacer(); Text("\(n)").monospacedDigit().foregroundStyle(.secondary) }
                }
            }
        } header: { Text("Question bank") } footer: {
            Text("Swipe a paper and choose Read again to re-read it, for example after switching to a stronger model in Settings.")
        }
    }

    private func statusChip(_ paper: Paper) -> some View {
        switch paper.status {
        case "done": return Chip(text: "Ready", tint: Theme.pass)
        case "failed": return Chip(text: "Failed", tint: Theme.fail)
        default: return Chip(text: "Reading", tint: .orange)
        }
    }

    // MARK: actions

    private func assign(_ memo: PickedPDF, to id: UUID) {
        guard let i = staged.firstIndex(where: { $0.id == id }) else { return }
        staged[i].memo = memo
        spare.removeAll { $0.id == memo.id }
    }

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            pickError = error.localizedDescription
        case .success(let urls):
            var fresh: [PickedPDF] = []
            for url in urls {
                let opened = url.startAccessingSecurityScopedResource()
                defer { if opened { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    fresh.append(PickedPDF(name: url.lastPathComponent, data: data))
                }
            }
            let existing = staged.flatMap { [$0.paper, $0.memo].compactMap { $0 } } + spare
            var all = existing
            for f in fresh where !all.contains(where: { $0.name == f.name }) { all.append(f) }
            let paired = PaperPairing.pair(all)
            staged = paired.pairs
            spare = paired.spareMemos
        }
    }
}
