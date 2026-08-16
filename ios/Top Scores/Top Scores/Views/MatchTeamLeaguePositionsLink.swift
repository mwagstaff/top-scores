import SwiftUI

// Shown directly below the live score card on the match detail screen: each
// team currently in a tracked league table gets a tappable Liquid Glass chip
// with its current position, jumping to that team's row on the Tables tab.
struct MatchTeamLeaguePositionsLink: View {
    let match: Match
    let apiBaseURL: String

    @State private var entries: [LeaguePositionEntry] = []

    private var taskKey: String {
        "\(apiBaseURL)|\(match.league)|\(match.homeTeam)|\(match.awayTeam)"
    }

    var body: some View {
        // Explicit if/else (rather than a bare `if`) so the VStack's content
        // is never an Optional-view-only child — a bare `if` with no `else`
        // here was empirically found to prevent `.task` below from ever
        // firing on a real device, even though the modifier is attached to
        // the stable outer VStack and not the conditional content itself.
        VStack(alignment: .leading, spacing: 0) {
            if !entries.isEmpty {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        ForEach(entries) { entry in
                            LeaguePositionChip(entry: entry, leagueName: match.league)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                EmptyView()
            }
        }
        .task(id: taskKey) {
            await loadEntries()
        }
    }

    private func loadEntries() async {
        // Mirror the web client: ensure tables are actually loaded rather than
        // relying on whatever happens to already be cached. `refresh` itself
        // serves the in-memory cache when it's still fresh, and de-dupes
        // concurrent calls, so this stays cheap once the catalog is warm —
        // but on a cold app launch (before the deferred startup prefetch has
        // run) it falls through to a real network fetch instead of silently
        // showing nothing.
        guard let response = try? await LeagueTablesCatalog.shared.refresh(apiBaseURL: apiBaseURL),
              let league = response.leagues.first(where: {
                  $0.leagueName.localizedCaseInsensitiveCompare(match.league) == .orderedSame
              })
        else {
            entries = []
            return
        }

        let allRows = league.rows + league.groups.flatMap(\.rows)
        entries = [match.homeTeam, match.awayTeam].compactMap { team in
            let canonical = TeamIdentityStore.shared.canonicalName(for: team)
            guard let row = allRows.first(where: {
                TeamIdentityStore.shared.canonicalName(for: $0.team).caseInsensitiveCompare(canonical) == .orderedSame
            }) else {
                return nil
            }
            return LeaguePositionEntry(
                id: "\(league.leagueID)-\(team)",
                leagueID: league.leagueID,
                teamName: team,
                displayName: canonical,
                position: row.position
            )
        }
    }
}

private struct LeaguePositionEntry: Identifiable {
    let id: String
    let leagueID: String
    let teamName: String
    let displayName: String
    let position: Int
}

private struct LeaguePositionChip: View {
    let entry: LeaguePositionEntry
    let leagueName: String

    private var ordinalPosition: String {
        Self.ordinal(entry.position)
    }

    private var accessibilityText: String {
        "\(entry.displayName), \(ordinalPosition) in \(leagueName)"
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
