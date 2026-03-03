import SwiftUI
import UIKit

struct FantasyPlayerDetailsSheet: View {
    let selection: FantasySelectedPlayerSelection
    let apiBaseURL: String

    @ObservedObject var fantasyViewModel: FantasyViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var details: FantasyPlayerDetailsData?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading player details...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let details {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            playerHeader(details)
                            availabilitySection(details)
                            metricsSection(details)
                            fixturesSection(details)
                            historySection(details)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .refreshable {
                        await loadDetails()
                    }
                } else {
                    unavailableState
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(selection.player.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .task(id: selection.id) {
            await loadDetails()
        }
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Player details unavailable")
                .font(.headline)
            Text(errorMessage ?? "Unable to load player details right now.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await loadDetails() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private func playerHeader(_ details: FantasyPlayerDetailsData) -> some View {
        HStack(spacing: 12) {
            teamLogoView(teamName: details.teamName, size: 62)

            VStack(alignment: .leading, spacing: 3) {
                Text(details.position)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(details.playerName)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(details.teamName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.72), Color.purple.opacity(0.72)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
    }

    private func availabilitySection(_ details: FantasyPlayerDetailsData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status Update")
                .font(.headline)

            if details.statusUpdates.isEmpty {
                Text("No availability issues reported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(details.statusUpdates) { update in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: update.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(update.severity == .warning ? Color.yellow : Color.secondary)
                            .padding(.top, 2)
                        Text(update.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func metricsSection(_ details: FantasyPlayerDetailsData) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Key stats")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(details.metrics, id: \.title) { metric in
                    VStack(spacing: 3) {
                        Text(metric.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(metric.value)
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemGroupedBackground))
                    )
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func fixturesSection(_ details: FantasyPlayerDetailsData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fixtures")
                .font(.headline)

            if details.upcomingFixtures.isEmpty {
                Text("No upcoming fixtures")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(details.upcomingFixtures) { fixture in
                    HStack(spacing: 8) {
                        Text("GW\(fixture.gameweek)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                        if fixture.isBlank {
                            noGameIcon(size: 18)
                        } else {
                            teamLogoView(teamName: fixture.opponentTeamName, size: 18)
                        }
                        Text(fixtureOpponentText(fixture))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        fixtureDifficultyBadge(fixture)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func historySection(_ details: FantasyPlayerDetailsData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Previous 10 gameweeks")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    historyHeader
                    ForEach(Array(details.historyRows.enumerated()), id: \.element.id) { index, row in
                        historyRow(row)
                        if index < details.historyRows.count - 1 {
                            Divider()
                                .overlay(Color.secondary.opacity(0.28))
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.tertiarySystemGroupedBackground))
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var historyHeader: some View {
        HStack(spacing: 8) {
            headerCell("GW", width: 40)
            Text("Opponent")
                .font(.caption.weight(.semibold))
                .frame(width: 176, alignment: .leading)
            headerCell("Pts", width: 44)
            headerCell("St", width: 34)
            headerCell("MP", width: 40)
            headerCell("GS", width: 34)
            headerCell("A", width: 34)
            headerCell("xG", width: 46)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func historyRow(_ row: FantasyPlayerDetailsData.HistoryRow) -> some View {
        HStack(spacing: 8) {
            Text("\(row.gameweek)")
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .leading)

            HStack(spacing: 6) {
                teamLogoView(teamName: row.opponentTeamName, size: 16)
                Text("\(row.opponentTeamName) (\(row.wasHome ? "H" : "A"))")
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(width: 176, alignment: .leading)

            pointsHeatmapCell(row.points, width: 44)
            valueCell(row.starts, width: 34)
            valueCell(row.minutes, width: 40)
            valueCell(row.goalsScored, width: 34)
            valueCell(row.assists, width: 34)
            Text(row.expectedGoals)
                .font(.caption.monospacedDigit())
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .frame(width: width, alignment: .trailing)
    }

    private func valueCell(_ value: Int, width: CGFloat) -> some View {
        Text("\(value)")
            .font(.caption.monospacedDigit())
            .frame(width: width, alignment: .trailing)
    }

    private func pointsHeatmapCell(_ points: Int, width: CGFloat) -> some View {
        Text("\(points)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(Color.white)
            .frame(width: width, alignment: .center)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pointsHeatmapColor(points).opacity(0.92))
            )
    }

    private func teamLogoView(teamName: String, size: CGFloat) -> some View {
        Group {
            if let logo = LogoResolver.shared.image(for: teamName) {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: max(4, size * 0.2), style: .continuous)
                .fill(Color(.systemBackground))
        )
    }

    private func noGameIcon(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(4, size * 0.2), style: .continuous)
                .fill(Color.red.opacity(0.18))
            Image(systemName: "xmark.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.red)
                .padding(size * 0.16)
        }
        .frame(width: size, height: size)
    }

    private func fixtureOpponentText(_ fixture: FantasyPlayerDetailsData.UpcomingFixture) -> String {
        guard !fixture.isBlank else { return "No game" }
        let side = fixture.isHome == true ? "H" : "A"
        return "\(fixture.opponentTeamName) (\(side))"
    }

    private func fixtureDifficultyBadge(_ fixture: FantasyPlayerDetailsData.UpcomingFixture) -> some View {
        let text = fixture.difficulty.map { "D\($0)" } ?? "-"
        let color = fixtureDifficultyColor(fixture.difficulty)

        return Text(text)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(fixture.difficulty == nil ? Color.secondary : Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(fixture.difficulty == nil ? 0.2 : 0.9))
            )
    }

    private func fixtureDifficultyColor(_ difficulty: Int?) -> Color {
        guard let difficulty else { return Color.gray }
        switch difficulty {
        case ...1: return Color.green
        case 2: return Color(red: 0.29, green: 0.71, blue: 0.27)
        case 3: return Color(red: 0.95, green: 0.68, blue: 0.16)
        case 4: return Color(red: 0.91, green: 0.37, blue: 0.15)
        default: return Color(red: 0.78, green: 0.16, blue: 0.14)
        }
    }

    private func pointsHeatmapColor(_ points: Int) -> Color {
        switch points {
        case ..<1:
            return Color(red: 0.78, green: 0.16, blue: 0.14) // red
        case 1...2:
            return Color(red: 0.91, green: 0.37, blue: 0.15) // orange-red
        case 3...4:
            return Color(red: 0.95, green: 0.68, blue: 0.16) // amber
        case 5...7:
            return Color(red: 0.29, green: 0.71, blue: 0.27) // green
        default:
            return Color.green
        }
    }

    private func loadDetails() async {
        isLoading = true
        errorMessage = nil

        do {
            let loaded = try await fantasyViewModel.loadPlayerDetails(
                elementID: selection.player.elementID,
                gameweekID: selection.gameweekID,
                apiBaseURL: apiBaseURL
            )
            details = loaded
        } catch {
            details = nil
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
