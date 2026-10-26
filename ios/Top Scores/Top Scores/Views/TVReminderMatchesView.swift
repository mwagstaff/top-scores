import SwiftUI

struct TVReminderMatchesView: View {
    let target: TVReminderTarget
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var matches: [Match] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading TV matches…")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Unable to load matches", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { attempt += 1 }
                    }
                } else if matches.count == 1 && target.matchIDs.count == 1, let match = matches.first {
                    MatchDetailView(match: match)
                } else {
                    List {
                        Section {
                            ForEach(matches) { match in
                                NavigationLink {
                                    MatchDetailView(match: match)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(match.homeTeam) v \(match.awayTeam)")
                                            .font(.headline)
                                        Text(match.tvChannels.map(\.name).joined(separator: ", "))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            if matches.count < target.matchIDs.count {
                                Text("Some matches are no longer available.")
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text(target.kickoff, format: .dateTime.day().month().hour().minute())
                        }
                    }
                }
            }
            .navigationTitle("Matches on TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: attempt) { await load() }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            guard let url = URL(string: preferences.apiBaseURL) else { throw URLError(.badURL) }
            // Fetch every page for the original date, independent of subsequently
            // changed Scores preferences or the date currently being browsed.
            let response = try await APIClient(baseURL: url).fetchMatchesInRange(
                preferences: preferences.snapshot, mode: .fixtures,
                startDate: target.kickoff, endDate: target.kickoff,
                includePreferenceFilters: false
            )
            try Task.checkCancellation()
            matches = target.matchIDs.compactMap { id in
                response.matches.first { $0.matchDetailsID == id }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
