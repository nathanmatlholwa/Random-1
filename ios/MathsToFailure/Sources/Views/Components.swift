import SwiftUI

enum Theme {
    static let fail = Color(red: 0.86, green: 0.30, blue: 0.07)
    static let pass = Color(red: 0.05, green: 0.55, blue: 0.47)
}

/// Five load steps for a skill. The step where it failed is marked in orange.
struct GaugeView: View {
    let level: Int
    let failedAt: Int?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(for: i))
                    .frame(width: 22, height: 12)
                    .overlay(alignment: .trailing) {
                        if failedAt == i {
                            Rectangle().fill(Theme.fail).frame(width: 3, height: 20)
                                .rotationEffect(.degrees(12))
                                .offset(x: 2)
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(level) of 5" + (failedAt.map { ", failed at level \($0)" } ?? ""))
    }

    private func color(for i: Int) -> Color {
        if failedAt == i { return Theme.fail }
        return i <= level ? Color.accentColor : Color.secondary.opacity(0.25)
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CalloutBox<Content: View>: View {
    var tint: Color = Theme.fail
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(tint.opacity(0.12))
            .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 5) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .tracking(0.8)
    }
}
