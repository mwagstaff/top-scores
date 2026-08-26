import SwiftUI

// Shown directly below the live score card on the match detail screen: each
// team currently in a tracked league table gets a tappable Liquid Glass chip
// with its current position, jumping to that team's row on the Tables tab.
struct MatchTeamLeaguePositionsLink: View {
    let entries: [MatchTeamCompetitionEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !entries.isEmpty {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        ForEach(entries) { entry in
                            LeaguePositionChip(entry: entry)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                EmptyView()
            }
        }
    }
}

private struct LeaguePositionChip: View {
    let entry: MatchTeamCompetitionEntry

    private var ordinalPosition: String {
        Self.ordinal(entry.position)
    }

    private var accessibilityText: String {
        "\(entry.displayName), \(ordinalPosition) in \(entry.competitionName)"
    }

    var body: some View {
        Button {
            TablesNavigationCoordinator.shared.navigate(leagueID: entry.leagueID, teamName: entry.teamName)
        } label: {
            chipLabel
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("View league table")
    }

    private var chipLabel: some View {
        HStack(spacing: 6) {
            Text(entry.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(ordinalPosition)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static func ordinal(_ value: Int) -> String {
        let remainder100 = value % 100
        if remainder100 >= 11 && remainder100 <= 13 {
            return "\(value)th"
        }
        switch value % 10 {
        case 1: return "\(value)st"
        case 2: return "\(value)nd"
        case 3: return "\(value)rd"
        default: return "\(value)th"
        }
    }
}
