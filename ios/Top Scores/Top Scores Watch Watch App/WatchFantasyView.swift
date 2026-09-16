import SwiftUI

struct WatchFantasyView: View {
    @EnvironmentObject private var matchesStore: WatchMatchesStore

    var body: some View {
        List {
            if let snapshot = matchesStore.fantasySnapshot {
                WatchFantasySquadSections(snapshot: snapshot)
                Section {
                    NavigationLink {
                        WatchFantasyLeaguesView()
                    } label: {
                        Label("View tables", systemImage: "list.number")
                    }
                }
                if let raw = snapshot.syncedAt, let date = WatchFantasyPresentation.parseDate(raw) {
                    Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    Text("Your FPL team")
                        .font(.headline)
                    Text("Open FPL in Top Scores on your iPhone to link or refresh your team.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Refresh from iPhone") { matchesStore.refresh() }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("FPL")
        .onAppear { matchesStore.refresh() }
    }
}

private struct WatchFantasySquadSections: View {
    let snapshot: WatchFantasySnapshot

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Text(snapshot.deadlineGameweekID.map { "GW\($0) deadline" } ?? "Next deadline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(WatchFantasyPresentation.deadline(snapshot.deadlineTime, now: context.date))
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Section(snapshot.gameweekTitle) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.scoreDisplay)
                    .font(.title2.bold())
                    .monospacedDigit()
                Text(snapshot.scoreDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        Section("Starting XI") {
            ForEach(snapshot.players.filter(\.isStarter)) { player in
                WatchFantasyPlayerRow(player: player, expected: snapshot.scorePhase == "expected")
            }
        }
        Section("Bench") {
            ForEach(snapshot.players.filter { !$0.isStarter }) { player in
                WatchFantasyPlayerRow(player: player, expected: snapshot.scorePhase == "expected")
            }
        }
    }
}

private struct WatchFantasyPlayerRow: View {
    let player: WatchFantasyPlayer
    let expected: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var score: String {
        expected ? WatchFantasyPresentation.points(player.expectedPoints) : "\(player.points)"
    }

    var body: some View {
        HStack(spacing: 6) {
            WatchFantasyImage(url: player.profileImageURL, initials: "", isPlayer: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.surname.flatMap { $0.isEmpty ? nil : $0 } ?? WatchFantasyPresentation.surname(player.displayName))
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if dynamicTypeSize.isAccessibilitySize {
                    opponentLabel
                    scoreLabel
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        opponentLabel
                        Spacer(minLength: 0)
                        scoreLabel
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(player.displayName), \(player.opponent ?? "opponent unavailable"), \(score)\(expected ? " expected points" : " points")\(player.isCaptain ? ", captain" : "")")
        .listRowInsets(EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5))
    }

    private var scoreLabel: some View {
        Text(score)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .fixedSize()
    }

    private var opponentLabel: some View {
        Text(WatchFantasyPresentation.opponent(player.opponent))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

private struct WatchFantasyImage: View {
    let url: String?
    let initials: String
    var isPlayer = false
    @State private var loader = WatchFantasyImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if isPlayer {
                Image(systemName: "person.fill").foregroundStyle(.secondary)
            } else {
                Text(initials)
                    .font(.system(size: 9, weight: .bold)).minimumScaleFactor(0.7)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.3), in: Circle())
            }
        }
        .frame(width: 26, height: 30)
        .task(id: url) { await loader.load(urlString: url) }
        .accessibilityHidden(true)
    }
}

private struct WatchFantasyLeaguesView: View {
    @EnvironmentObject private var matchesStore: WatchMatchesStore

    var body: some View {
        List {
            let leagues = matchesStore.fantasySnapshot?.leagues ?? []
            if leagues.isEmpty {
                Text("Open FPL on your iPhone to sync your rivals and leagues.")
                    .font(.caption)
            }
            ForEach(leagues.sorted { lhs, rhs in
                if lhs.id == 0 { return rhs.id != 0 }
                if rhs.id == 0 { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }) { league in
                NavigationLink {
                    WatchFantasyLeagueView(league: league)
                } label: {
                    Label(league.name, systemImage: league.id == 0 ? "person.2.fill" : "trophy")
                        .font(.caption)
                }
            }
        }
        .navigationTitle("FPL tables")
    }
}

private struct WatchFantasyLeagueView: View {
    let league: WatchFantasyLeague
    @EnvironmentObject private var matchesStore: WatchMatchesStore
    @State private var store: WatchFantasyLeagueStore

    init(league: WatchFantasyLeague) {
        self.league = league
        _store = State(initialValue: WatchFantasyLeagueStore(entries: league.entries))
    }

    private var rows: [WatchFantasyStanding] {
        if league.id == 0 {
            return matchesStore.fantasySnapshot?.leagues?.first { $0.id == 0 }?.entries ?? league.entries
        }
        return store.entries
    }

    var body: some View {
        List {
            Section("Season points") {
                ForEach(rows) { row in
                    WatchFantasyStandingRow(
                        row: row,
                        isCurrentUser: row.entry == matchesStore.fantasySnapshot?.managerEntryID,
                        badgeURL: WatchFantasyImageLoader.normalizedURL(row.clubBadgeSrc) != nil
                            ? row.clubBadgeSrc : knownBadge(for: row.entry)
                    )
                }
                if rows.isEmpty && !store.isLoading && store.errorMessage == nil {
                    Text("No standings available yet.").font(.caption)
                }
            }
            if league.id != 0 {
                Section {
                    if store.isLoading {
                        ProgressView("Loading standings")
                    } else if let error = store.errorMessage {
                        Text(error).font(.caption2)
                        Button("Retry") { loadMore() }
                    } else if store.hasNext {
                        Button("Load more") { loadMore() }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(league.name)
        .task { await store.loadNextPage(leagueID: league.id) }
        .onDisappear { loadTask?.cancel() }
    }

    @State private var loadTask: Task<Void, Never>?

    private func loadMore() {
        loadTask?.cancel()
        loadTask = Task { await store.loadNextPage(leagueID: league.id) }
    }

    private func knownBadge(for entryID: Int) -> String? {
        matchesStore.fantasySnapshot?.leagues?.lazy.flatMap(\.entries)
            .first { $0.entry == entryID && WatchFantasyImageLoader.normalizedURL($0.clubBadgeSrc) != nil }?.clubBadgeSrc
    }
}

private struct WatchFantasyStandingRow: View {
    let row: WatchFantasyStanding
    let isCurrentUser: Bool
    let badgeURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 5) {
                Text("\(row.rank)").font(.caption2.monospacedDigit())
                WatchFantasyImage(url: badgeURL, initials: WatchFantasyPresentation.initials(row.entryName))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.entryName).font(.caption.weight(.semibold))
                    Text(row.playerName).font(.caption2).foregroundStyle(.secondary)
                    if isCurrentUser {
                        Text("You").font(.caption2.bold()).foregroundStyle(Color.accentColor)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Text(row.total.map { "\($0) pts" } ?? "— pts")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                Image(systemName: row.trend)
                    .font(.caption2.bold())
                    .foregroundStyle(row.trend == "arrow.up" ? Color.green : row.trend == "arrow.down" ? Color.red : Color.secondary)
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 5, bottom: 6, trailing: 5))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10)
                .fill(isCurrentUser ? Color.accentColor.opacity(0.22) : Color(white: 0.13))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isCurrentUser ? Color.accentColor.opacity(0.75) : Color.clear, lineWidth: 1)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isCurrentUser ? "Your team, " : "")Position \(row.rank), \(row.entryName), \(row.playerName), \(row.total.map(String.init) ?? "unavailable") points, \(row.trendDescription)")
    }
}

#Preview("FPL squad") {
    NavigationStack {
        List {
            WatchFantasySquadSections(snapshot: WatchFantasySnapshot(
                gameweekTitle: "Gameweek 5",
                players: (1...15).map { index in
                    WatchFantasyPlayer(elementID: index, displayName: index == 1 ? "Salah" : "Fernandes", teamName: "Liverpool", points: 6, isCaptain: index == 1, isViceCaptain: false, isStarter: index <= 11, opponent: "BHA (H)", expectedPoints: 4.6)
                },
                deadlineTime: "2026-09-18T17:30:00Z", deadlineGameweekID: 5,
                scorePhase: "expected", expectedPoints: 69.3
            ))
        }
        .navigationTitle("FPL")
    }
}
