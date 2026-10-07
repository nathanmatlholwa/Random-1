import SwiftUI
import UniformTypeIdentifiers

struct LibraryTab: View {
    @EnvironmentObject var app: AppModel
    @State private var picking = false
    @State private var loadingFiles = false
    @State private var staged: [StagedPair] = []
    @State private var spare: [PickedPDF] = []
    @State private var summary = ""
    @State private var pickError: String?
    @State private var toDelete: Paper?

    private var readyPairs: [StagedPair] { staged.filter { $0.paper != nil && $0.memo != nil } }
    private var missingMemo: Int { staged.filter { $0.memo == nil }.count }
    private var paperQuestions: [Question] { app.questions.filter { $0.source == "paper" } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if app.ingestBusy { progressSection }
                    importSection
                    if !staged.isEmpty || !spare.isEmpty { stagedSection }
                    if !app.ingestBusy && !app.ingestLog.isEmpty { logSection }
                    papersSection
                    bankSection
                }
                .onChange(of: staged.count) { _, count in
                    // After choosing files, jump straight to the list so the Upload button is in view.
                    if count > 0 { withAnimation { proxy.scrollTo("staged-top", anchor: .top) } }
                }
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

    /// Always at the top while a batch is running, so it is obvious that work is happening.
    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProgressView()
                    Text(app.ingestTotal > 0
                         ? "Paper \(min(app.ingestDone + 1, app.ingestTotal)) of \(app.ingestTotal)"
                         : "Working...")
                        .font(.headline)
                    Spacer()
                    Button("Stop", role: .destructive) { app.cancelIngest() }
                        .buttonStyle(.bordered)
                }
                if app.ingestTotal > 0 {
                    ProgressView(value: Double(app.ingestDone), total: Double(app.ingestTotal))
                }
                Text(app.ingestStatus).font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(app.ingestLog.suffix(4).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.footnote.monospaced())
                }
                Text("Keep the app open. Each paper takes a few minutes. Finished papers are saved as they go.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: { Text("Uploading and reading") }
    }

    private var importSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Step 1. Choose the papers and their memorandums together. Step 2. Check the list that appears and press Upload and read.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { picking = true } label: {
                    Label("Choose PDFs", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.ingestBusy || loadingFiles)
                if loadingFiles {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Opening your files...").font(.subheadline)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: { Text("Add papers") }
    }

    private var stagedSection: some View {
        Section {
            Text(summary).font(.subheadline.weight(.medium)).id("staged-top")

            Button {
                let pairs = readyPairs
                staged = []
                spare = []
                summary = ""
                app.startIngest(pairs: pairs)
            } label: {
                Text(readyPairs.isEmpty
                     ? "Nothing ready to upload"
                     : "Upload and read \(readyPairs.count) paper\(readyPairs.count == 1 ? "" : "s")")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(readyPairs.isEmpty || app.ingestBusy)

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
                            Label(spare.isEmpty ? "No memorandum found. This paper will be skipped." : "Choose its memorandum",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .disabled(spare.isEmpty)
                    }
                }
            }
            .onDelete { staged.remove(atOffsets: $0) }

            if !spare.isEmpty {
                Text("Memorandums with no matching paper: " + spare.map { $0.name }.joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Step 2. Ready to add") } footer: {
            Text("Reading uses your API key and makes several model calls per paper. Swipe a row to remove it.")
        }
    }

    private var logSection: some View {
        Section("Last upload") {
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
        refreshSummary()
    }

    private func refreshSummary() {
        let total = staged.count + spare.count
        var parts = ["\(readyPairs.count) paper\(readyPairs.count == 1 ? "" : "s") matched with a memorandum"]
        if missingMemo > 0 { parts.append("\(missingMemo) without a memorandum") }
        if !spare.isEmpty { parts.append("\(spare.count) memorandum\(spare.count == 1 ? "" : "s") with no paper") }
        summary = "\(total) file\(total == 1 ? "" : "s") loaded. " + parts.joined(separator: ", ") + "."
    }

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            pickError = error.localizedDescription
        case .success(let urls):
            loadingFiles = true
            Task {
                // Reading many PDFs is slow, so it happens off the main thread and the screen stays responsive.
                let fresh = await Task.detached(priority: .userInitiated) { () -> [PickedPDF] in
                    var out: [PickedPDF] = []
                    for url in urls {
                        let opened = url.startAccessingSecurityScopedResource()
                        defer { if opened { url.stopAccessingSecurityScopedResource() } }
                        if let data = try? Data(contentsOf: url) {
                            out.append(PickedPDF(name: url.lastPathComponent, data: data))
                        }
                    }
                    return out
                }.value
                loadingFiles = false
                if fresh.isEmpty {
                    pickError = "None of the selected files could be read. Check that they are PDFs stored on this device or in iCloud Drive."
                    return
                }
                let existing = staged.flatMap { [$0.paper, $0.memo].compactMap { $0 } } + spare
                var all = existing
                for f in fresh where !all.contains(where: { $0.name == f.name }) { all.append(f) }
                let paired = PaperPairing.pair(all)
                staged = paired.pairs
                spare = paired.spareMemos
                refreshSummary()
            }
        }
    }
}
