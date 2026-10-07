import SwiftUI

struct WeakSpotsTab: View {
    @EnvironmentObject var app: AppModel

    private var weakest: [SkillState] {
        app.skills.values.filter { $0.attempts > 0 }.sorted { $0.mastery < $1.mastery }.prefix(3).map { $0 }
    }

    private var topics: [String] {
        Array(Set(app.skills.values.map { $0.topic })).sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                if app.skills.isEmpty {
                    Section {
                        Text("Nothing here yet. Add a paper in Library, then do a session.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Weakest right now") {
                        if weakest.isEmpty {
                            Text("Finish a session to see your weakest skills.").foregroundStyle(.secondary)
                        }
                        ForEach(weakest) { s in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(s.skill).font(.headline)
                                    Text(s.topic).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Press this") { press(s) }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    ForEach(topics, id: \.self) { topic in
                        Section(topic) {
                            ForEach(skills(in: topic)) { s in skillRow(s) }
                        }
                    }
                    Section("Recent attempts") {
                        ForEach(app.attempts.suffix(8).reversed()) { a in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("\(a.marks)/\(a.outOf)").bold().monospacedDigit()
                                    Text(skillName(a.skillId))
                                    Spacer()
                                    Text("level \(a.level)").font(.caption).foregroundStyle(.secondary)
                                }
                                if let e = a.firstError, !e.isEmpty {
                                    Text(e).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Weak spots")
            .refreshable { await app.reload() }
        }
    }

    private func skills(in topic: String) -> [SkillState] {
        app.skills.values.filter { $0.topic == topic }.sorted { $0.mastery < $1.mastery }
    }

    private func skillName(_ id: UUID) -> String {
        app.skills.values.first(where: { $0.id == id })?.skill ?? "Skill"
    }

    private func press(_ s: SkillState) {
        app.pendingFocusKey = s.key
        app.selectedTab = .session
    }

    private func skillRow(_ s: SkillState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(s.skill).font(.headline)
                Spacer()
                GaugeView(level: s.level, failedAt: s.failedAt)
            }
            HStack(spacing: 10) {
                ProgressView(value: s.mastery)
                    .tint(s.mastery < 0.5 ? Theme.fail : Theme.pass)
                    .frame(maxWidth: 160)
                Text(s.attempts == 0 ? "untested" : "\(Int((s.mastery * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                Text("\(s.attempts) attempt\(s.attempts == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                if let f = s.failedAt { Chip(text: "failed at level \(f)", tint: Theme.fail) }
            }
            let errs = s.errors.sorted { $0.value > $1.value }.prefix(4)
            if !errs.isEmpty {
                Text(errs.map { "\($0.key) x\($0.value)" }.joined(separator: "   "))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.fail)
            }
            Button("Press this skill") { press(s) }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
