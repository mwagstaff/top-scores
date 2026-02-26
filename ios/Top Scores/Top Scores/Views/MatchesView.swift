import SwiftUI

enum MatchesViewMode: String {
    case fixtures
    case results

    var title: String {
        switch self {
        case .fixtures:
            return "Fixtures"
        case .results:
            return "Results"
        }
    }

    var loadingText: String {
        switch self {
        case .fixtures:
            return "Loading fixtures"
        case .results:
            return "Loading results"
        }
    }

    var refreshAccessibilityLabel: String {
        switch self {
        case .fixtures:
            return "Refresh fixtures"
        case .results:
            return "Refresh results"
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .fixtures:
            return "No fixtures to show"
        case .results:
            return "No results to show"
        }
    }

    var emptyStateSubtitle: String {
        switch self {
        case .fixtures:
            return "Fixtures appear here from today onwards."
        case .results:
            return "Results appear here from today backwards."
        }
    }

    var refreshProgressText: String {
        switch self {
        case .fixtures:
            return "Refreshing fixtures"
        case .results:
            return "Refreshing results"
        }
    }
}

struct MatchesView: View {
    let mode: MatchesViewMode

    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var matchesStore: MatchesStore
    @State private var showToast = false
    @State private var toastMessage = ""

    private var showAllMatches: Bool {
        preferences.showAllMatches
    }

    private let refreshFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    headerView
                    Group {
                        if matchesStore.isLoading && matchesStore.groupedMatches.isEmpty {
                            VStack(spacing: 16) {
                                ProgressView()
                                Text(mode.loadingText)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if matchesStore.groupedMatches.isEmpty {
                            emptyState
                        } else {
                            matchesList
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .background(Color(.systemBackground))
                .overlay(alignment: .top) {
                    if showToast {
                        ToastView(message: toastMessage)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
        }
        .onAppear {
            let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
            matchesStore.configure(with: snapshot, mode: mode)
            reportMissingTeamLogosIfNeeded(days: matchesStore.groupedMatches)
        }
        .onChange(of: preferences.snapshot) { _, _ in
            let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
            matchesStore.configure(with: snapshot, mode: mode)
        }
        .onChange(of: preferences.showAllMatches) { _, newValue in
            let snapshot = newValue ? preferences.unfilteredSnapshot : preferences.snapshot
            matchesStore.configure(with: snapshot, mode: mode)
            toastMessage = newValue ? "Viewing all matches (unfiltered)" : "Viewing preferred matches only"
            withAnimation {
                showToast = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation {
                    showToast = false
                }
            }
        }
        .onChange(of: matchesStore.groupedMatches) { _, days in
            reportMissingTeamLogosIfNeeded(days: days)
        }
        .onDisappear {
            matchesStore.stopAutoRefresh()
        }
    }

    private var matchesList: some View {
        List {
            ForEach(matchesStore.groupedMatches) { day in
                Section {
                    ForEach(day.leagues) { league in
                        Text(league.league)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 2, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)

                        ForEach(league.matches) { match in
                            NavigationLink {
                                MatchDetailView(match: match, highlightToday: day.isToday)
                            } label: {
                                MatchRow(match: match, highlightToday: day.isToday, showLeague: false)
                            }
                            .onAppear {
                                Task {
                                    let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
                                    await matchesStore.prefetchIfNeeded(
                                        currentMatch: match,
                                        preferences: snapshot,
                                        mode: mode
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    Text(day.displayDate)
                        .font(.title3)
                        .fontWeight(.semibold)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaPadding(.bottom, 80)
        .refreshable {
            let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
            await matchesStore.refresh(preferences: snapshot, mode: mode)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(mode.emptyStateTitle)
                .font(.title3)
            Text(mode.emptyStateSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("Top Scores")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Spacer()
                Button {
                    preferences.showAllMatches.toggle()
                } label: {
                    Image(systemName: showAllMatches ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.title3)
                        .padding(10)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .accessibilityLabel(showAllMatches ? "Show preferred matches only" : "Show all matches")
            }

            if matchesStore.errorMessage != nil || matchesStore.isLoading || matchesStore.lastUpdated != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = matchesStore.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if matchesStore.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(mode.refreshProgressText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if let lastUpdated = matchesStore.lastUpdated {
                        let cachedSuffix = matchesStore.isUsingCache ? " (cached)" : ""
                        Text("Updated \(refreshFormatter.string(from: lastUpdated))\(cachedSuffix)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private func reportMissingTeamLogosIfNeeded(days: [MatchDay]) {
        let allTeamNames = days
            .flatMap(\.leagues)
            .flatMap(\.matches)
            .flatMap { [$0.homeTeam, $0.awayTeam] }

        let missingTeamNames = LogoResolver.shared.missingTeamNames(in: allTeamNames)
        guard !missingTeamNames.isEmpty else { return }
        guard let baseURL = URL(string: preferences.apiBaseURL) else { return }

        Task {
            let client = APIClient(baseURL: baseURL)
            do {
                try await client.reportMissingTeamLogos(missingTeamNames)
            } catch {
                NSLog("Missing logo audit post failed error=%@", String(describing: error))
            }
        }
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.8))
            )
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

#Preview {
    MatchesView(mode: .fixtures)
        .environmentObject(PreferencesStore())
        .environmentObject(MatchesStore())
}
