import SwiftUI

struct MatchLineupStatusBadge: View {
    let status: String
    var body: some View {
        if status == "predicted" || status == "confirmed" {
            Label(status == "predicted" ? "AI predicted" : "Confirmed",
                  systemImage: status == "predicted" ? "sparkles" : "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(status == "predicted" ? Color.primary : Color.green)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background((status == "predicted" ? Color.orange : Color.green).opacity(0.15), in: Capsule())
                .accessibilityLabel(status == "predicted" ? "AI predicted lineups" : "Confirmed lineups")
        }
    }
}

struct MatchPreviewSection: View {
    let preview: MatchPreviewContent
    @State private var expanded = false
    private var intro: String { preview.text.components(separatedBy: "\n\n").first ?? preview.text }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Match preview").font(.headline)
            Label("AI-generated", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
            Text(expanded ? preview.text : intro).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if intro != preview.text {
                Button(expanded ? "Show less" : "Read full preview") { expanded.toggle() }
                    .font(.subheadline).frame(minHeight: 44)
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
        }
        .matchContextCard()
    }
}

struct MatchHeadToHeadSection: View {
    let data: MatchHeadToHead
    let homeTeam: String
    let awayTeam: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Head-to-head").font(.headline)
            if data.totalMatches == 0 {
                Text("No meetings available.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("\(data.totalMatches) recorded \(data.totalMatches == 1 ? "meeting" : "meetings")")
                    .font(.caption).foregroundStyle(.secondary)
                let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                layout {
                    summary(data.homeWins, label: "\(homeTeam) wins")
                    summary(data.draws, label: "Draws")
                    summary(data.awayWins, label: "\(awayTeam) wins")
                }
                let meetings = Array(data.recentMatches.prefix(10))
                if !meetings.isEmpty {
                    Text("Latest \(meetings.count) \(meetings.count == 1 ? "meeting" : "meetings")")
                        .font(.subheadline.weight(.semibold))
                    ForEach(meetings) { meeting in
                        Divider()
                        if let match = meeting.match {
                            NavigationLink { MatchDetailView(match: match, showFantasyBadge: false) } label: {
                                HStack(spacing: 10) {
                                    row(meeting)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary).accessibilityHidden(true)
                                }
                            }
                                .buttonStyle(.plain).accessibilityHint("Opens match details")
                        } else { row(meeting) }
                    }
                }
            }
        }
        .matchContextCard()
    }

    private func summary(_ count: Int?, label: String) -> some View {
        VStack(spacing: 4) {
            Text(count.map(String.init) ?? "–").font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }

    private func row(_ meeting: MatchHeadToHeadMeeting) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let date = MatchContext.parseDate(meeting.date) {
                Text(date, format: .dateTime.day().month(.abbreviated).year())
                    .font(.caption).foregroundStyle(.secondary)
            }
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                Text(meeting.homeTeam).frame(maxWidth: .infinity, alignment: .leading)
                Text(meeting.scoreText).fontWeight(.bold).monospacedDigit().fixedSize()
                Text(meeting.awayTeam).frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            }.font(.subheadline)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct MatchFunFactsSection: View {
    let facts: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fun facts").font(.headline)
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 { Divider() }
                Text(fact).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }
        .matchContextCard()
    }
}

private extension View {
    func matchContextCard() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
