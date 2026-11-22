import SwiftUI

struct NextGoalCard: View {
    let goal: NextGoal
    let homeTeam: String
    let awayTeam: String
    var homeScore: Int?
    var awayScore: Int?
    @ObservedObject private var colors = TeamColorCatalog.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func color(_ side: String) -> Color {
        if side == "no_goal" { return .gray }
        return MatchAnalysisPalette.colors(side, catalog: colors, homeTeam: homeTeam,
                                           awayTeam: awayTeam, colorScheme: colorScheme).background
    }

    var body: some View {
        if let expiry = goal.expiresAt {
            TimelineView(.explicit([Date.now, expiry].sorted())) { context in
                card(expired: context.date >= expiry)
            }
        } else {
            card(expired: false)
        }
    }

    @ViewBuilder private func card(expired: Bool) -> some View {
        let changedScore = goal.score.map { score in
            homeScore != nil && awayScore != nil && (score.home != homeScore || score.away != awayScore)
        } ?? false
        let updating = changedScore || expired || goal.status == .updating
        let shares = goal.shares(home: homeTeam, away: awayTeam)
        let calls = goal.status == .settled ? goal.calls ?? [] : []
        if !shares.isEmpty || goal.status == .warmingUp || (goal.status == .settled && !calls.isEmpty) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Next goal").font(.headline)
                if let message = changedScore ? "Updating after goal…" : expired ? "Updating…" : goal.message {
                    if goal.status == .warmingUp {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text(message).font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                if !shares.isEmpty {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(shares) { share in
                                color(share.id).frame(width: geometry.size.width * share.value)
                            }
                        }
                    }
                    .frame(height: 10)
                    .clipShape(Capsule())
                    .opacity(updating ? 0.5 : 1)
                    .animation(reduceMotion ? nil : .smooth, value: goal.probabilities)
                    ViewThatFits(in: .horizontal) {
                        if !dynamicTypeSize.isAccessibilitySize {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(shares) { share in
                                    let alignment: HorizontalAlignment = share.id == "home" ? .leading : share.id == "away" ? .trailing : .center
                                    VStack(alignment: alignment, spacing: 3) {
                                        Text(share.label)
                                        Text(share.percent).monospacedDigit()
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                    .fontWeight(share.value == shares.map(\.value).max() ? .bold : .regular)
                                    if share.id != "away" { Spacer(minLength: 0) }
                                }
                            }
                        }
                        VStack(spacing: 6) {
                            ForEach(shares) { share in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(share.label)
                                    Spacer()
                                    Text(share.percent).monospacedDigit().fixedSize()
                                }
                                .fontWeight(share.value == shares.map(\.value).max() ? .bold : .regular)
                            }
                        }
                    }
                    .font(.subheadline)
                    if let note = goal.note(updating: updating) { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(calls.indices, id: \.self) { index in Text(calls[index].summary).font(.subheadline) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.12), lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }
}
