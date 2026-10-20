import SwiftUI
import Observation

struct WatchTablesPayload: Decodable {
    let leagues: [WatchLeagueTable]
}

struct WatchLeagueTable: Decodable, Identifiable {
    let leagueID: String
    let leagueName: String
    let groups: [Group]?
    let rows: [Row]?
    var id: String { leagueID }

    struct Group: Decodable {
        let name: String?
        let rows: [Row]
    }

    struct Row: Decodable, Identifiable {
        let position: Int
        let team: String
        let points: Int
        let live: Bool?
        var id: String { "\(position)-\(team)" }
    }

    enum CodingKeys: String, CodingKey {
        case leagueID = "league_id", leagueName = "league_name", groups, rows
    }

    var sections: [Group] {
        let populatedGroups = (groups ?? []).filter { !$0.rows.isEmpty }
        return populatedGroups.isEmpty ? [Group(name: nil, rows: rows ?? [])] : populatedGroups
    }

    var hasRows: Bool { sections.contains { !$0.rows.isEmpty } }
}

struct WatchTableCompetitionCatalog: Decodable {
    let competitions: [Entry]
    struct Entry: Decodable {
        let id: String?
        let name: String
        let aliases: [String]?
        let weight: Double
    }

    func sorted(_ leagues: [WatchLeagueTable]) -> [WatchLeagueTable] {
        func key(_ name: String) -> String {
            name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        }
        func weight(_ league: WatchLeagueTable) -> Double {
            competitions.first {
                $0.id == league.leagueID ||
                ([$0.name] + ($0.aliases ?? [])).contains { key($0) == key(league.leagueName) }
            }?.weight ?? 0
        }
        return leagues.filter(\.hasRows).sorted {
            let left = weight($0), right = weight($1)
            if left != right { return left > right }
            return $0.leagueName.localizedCaseInsensitiveCompare($1.leagueName) == .orderedAscending
        }
    }
}

@MainActor @Observable
final class WatchTablesStore {
    private(set) var leagues: [WatchLeagueTable] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var catalog: WatchTableCompetitionCatalog?
    private var lastRefreshAt: Date?

    func refresh(baseURL: String) async {
        guard !isLoading, let url = URL(string: baseURL) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = WatchAPIClient(baseURL: url)
            if catalog == nil {
                catalog = try await client.fetchTableCompetitionCatalog()
            }
            let payload = try await client.fetchTables()
            try Task.checkCancellation()
            leagues = catalog?.sorted(payload.leagues) ?? payload.leagues.filter(\.hasRows)
            errorMessage = nil
            lastRefreshAt = Date()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            errorMessage = "Couldn't update tables. Try again."
        }
    }

    func refreshWhileVisible(baseURL: String) async {
        while !Task.isCancelled {
            // Picker and detail can briefly overlap during navigation.
            if lastRefreshAt.map({ Date().timeIntervalSince($0) >= 25 }) ?? true {
                await refresh(baseURL: baseURL)
            }
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
        }
    }
}

struct WatchTablesView: View {
    @EnvironmentObject private var matchesStore: WatchMatchesStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = WatchTablesStore()

    var body: some View {
        List {
            if store.leagues.isEmpty, store.isLoading {
                ProgressView("Loading tables")
            }
            ForEach(store.leagues) { league in
                NavigationLink {
                    WatchLeagueTableView(store: store, leagueID: league.id, title: league.leagueName)
                } label: {
                    HStack(spacing: 10) {
                        if let image = WatchCompetitionLogoResolver.image(for: league.leagueName) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)
                        }
                        Text(league.leagueName).font(.body).lineLimit(2)
                    }
                }
            }
            if let message = store.errorMessage {
                Text(message).font(.caption)
                Button("Retry") { Task { await store.refresh(baseURL: matchesStore.apiBaseURL) } }
            } else if store.leagues.isEmpty, !store.isLoading {
                Text("No tables available").font(.caption)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Tables")
        .task(id: "\(scenePhase)-\(matchesStore.apiBaseURL)") {
            guard scenePhase == .active else { return }
            await store.refreshWhileVisible(baseURL: matchesStore.apiBaseURL)
        }
    }
}

private struct WatchLeagueTableView: View {
    let store: WatchTablesStore
    let leagueID: String
    let title: String
    @EnvironmentObject private var matchesStore: WatchMatchesStore
    @Environment(\.scenePhase) private var scenePhase

    private var league: WatchLeagueTable? { store.leagues.first { $0.id == leagueID } }

    var body: some View {
        List {
            if let league {
                ForEach(Array(league.sections.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group.rows.sorted { $0.position < $1.position }) { row in
                            NavigationLink {
                                WatchTableTeamMatchView(team: row.team)
                            } label: {
                                WatchTableRow(row: row)
                            }
                            .listRowInsets(EdgeInsets(top: 7, leading: 5, bottom: 7, trailing: 5))
                            .listRowBackground(WatchTableRowBackground(isLive: row.live == true))
                            .accessibilityHint("Opens the current or latest match")
                        }
                    } header: {
                        if let name = group.name { Text(name) }
                    }
                }
            } else {
                Text("No standings available")
            }
            if let message = store.errorMessage {
                Text(message).font(.caption)
                Button("Retry") { Task { await store.refresh(baseURL: matchesStore.apiBaseURL) } }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .task(id: "\(scenePhase)-\(matchesStore.apiBaseURL)") {
            guard scenePhase == .active else { return }
            await store.refreshWhileVisible(baseURL: matchesStore.apiBaseURL)
        }
    }
}

private struct WatchTableRow: View {
    let row: WatchLeagueTable.Row

    var body: some View {
        HStack(spacing: 6) {
            Text("\(row.position)")
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            Group {
                if let image = WatchTeamLogoResolver.shared.image(for: row.team) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "shield").resizable().scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
            Text(WatchTeamNameResolver.shared.displayName(for: row.team, providerShortName: nil))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("\(row.points)").fontWeight(.semibold)
        }
        .font(.caption)
        .monospacedDigit()
        .listRowInsets(EdgeInsets(top: 7, leading: 5, bottom: 7, trailing: 5))
        .listRowBackground(WatchTableRowBackground(isLive: row.live == true))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.position), \(row.team), \(row.points) points\(row.live == true ? ", playing live" : "")")
    }
}

#Preview {
    NavigationStack {
        List {
            WatchTableRow(row: .init(position: 1, team: "Arsenal", points: 24, live: true))
            WatchTableRow(row: .init(position: 2, team: "Manchester City", points: 22, live: false))
        }
    }
}

private struct WatchTableRowBackground: View {
    let isLive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.32, green: 0.82, blue: 0.51).opacity(isLive ? 0.14 : 0))
            }
    }
}

enum WatchTableMatchSelection {
    // The API filters by the team's canonical name and aliases, across competitions.
    static func currentOrLatest(in matches: [WatchMatch]) -> WatchMatch? {
        matches.filter { $0.isInProgress || WatchMatchCollections.isFinished($0) }
            .sorted {
                if $0.isInProgress != $1.isInProgress { return $0.isInProgress }
                let left = $0.dateTime ?? .distantPast
                let right = $1.dateTime ?? .distantPast
                if left != right { return left > right }
                return $0.id < $1.id
            }
            .first
    }
}

private struct WatchTableTeamMatchView: View {
    let team: String
    @EnvironmentObject private var matchesStore: WatchMatchesStore
    @State private var match: WatchMatch?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var retryID = 0

    var body: some View {
        Group {
            if let match {
                WatchMatchDetailView(match: match)
            } else {
                VStack(spacing: 10) {
                    if isLoading {
                        ProgressView("Loading match")
                    } else if let errorMessage {
                        Text(errorMessage).font(.caption)
                        Button("Retry") { retryID += 1 }
                    } else {
                        Text("No current or completed match available for \(team).")
                            .font(.caption)
                    }
                }
                .multilineTextAlignment(.center)
                .padding()
                .navigationTitle(team)
            }
        }
        .task(id: "\(matchesStore.apiBaseURL)-\(retryID)") {
            isLoading = true
            errorMessage = nil
            defer { isLoading = false }
            do {
                guard let url = URL(string: matchesStore.apiBaseURL) else {
                    throw WatchAPIClientError.invalidHTTPResponse
                }
                let latest = try await WatchAPIClient(baseURL: url).fetchCurrentOrLatestMatch(team: team)
                try Task.checkCancellation()
                match = latest
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorMessage = "Couldn't load the match. Try again."
            }
        }
    }
}
