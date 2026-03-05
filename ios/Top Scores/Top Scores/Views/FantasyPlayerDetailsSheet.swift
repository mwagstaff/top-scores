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
    @State private var transferRecommendations: FantasyTransferRecommendationsResponse?
    @State private var isLoadingTransferRecommendations = false
    @State private var transferRecommendationsErrorMessage: String?
    @State private var expandedRecommendationRows: Set<String> = []
    @State private var recommendationDetailsByElementID: [Int: FantasyPlayerDetailsData] = [:]
    @State private var loadingRecommendationDetailElementIDs: Set<Int> = []
    @State private var recommendationDetailErrorsByElementID: [Int: String] = [:]

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
                            if !details.statusUpdates.isEmpty {
                                availabilitySection(details)
                            }
                            metricsSection(details)
                            if !details.latestPointsBreakdown.isEmpty {
                                latestPointsBreakdownSection(details)
                            }
                            fixturesSection(details)
                            historySection(details)
                            transferRecommendationsSection
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

    private func latestPointsBreakdownSection(_ details: FantasyPlayerDetailsData) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
        let maxAbsPoints = max(
            details.latestPointsBreakdown.map { abs($0.points) }.max() ?? 1,
            1
        )

        return VStack(alignment: .leading, spacing: 8) {
            Text("Latest GW points breakdown")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(details.latestPointsBreakdown) { item in
                    pointsBreakdownCard(item: item, maxAbsPoints: maxAbsPoints)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func pointsBreakdownCard(
        item: FantasyPlayerDetailsData.PointsBreakdownItem,
        maxAbsPoints: Int
    ) -> some View {
        let isNegative = item.points < 0
        let magnitude = CGFloat(abs(item.points))
        let denominator = CGFloat(max(maxAbsPoints, 1))
        let progress = max(0.0, min(1.0, magnitude / denominator))

        return VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            HStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.10))

                        Capsule(style: .continuous)
                            .fill(
                                isNegative
                                    ? Color.red.opacity(0.88)
                                    : Color.green.opacity(0.88)
                            )
                            .frame(width: max(4, proxy.size.width * progress))
                    }
                }
                .frame(height: 8)

                Text("\(item.points)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isNegative ? Color.red : Color.primary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private func fixturesSection(_ details: FantasyPlayerDetailsData) -> some View {
        let gameweekWidth: CGFloat = 34
        let difficultyWidth: CGFloat = 74
        let xpWidth: CGFloat = 44

        VStack(alignment: .leading, spacing: 8) {
            Text("Fixtures")
                .font(.headline)

            if details.upcomingFixtures.isEmpty {
                Text("No upcoming fixtures")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    transferRecommendationHeaderCell("GW", width: gameweekWidth, alignment: .leading)
                    transferRecommendationHeaderCell("Opponent", alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    transferRecommendationHeaderCell("Difficulty", width: difficultyWidth, alignment: .leading)
                    transferRecommendationHeaderCell("xP", width: xpWidth, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(Array(details.upcomingFixtures.prefix(5).enumerated()), id: \.element.id) { index, fixture in
                    HStack(spacing: 8) {
                        Text("\(fixture.gameweek)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: gameweekWidth, alignment: .leading)

                        if fixture.isBlank {
                            HStack(spacing: 6) {
                                noGameIcon(size: 14)
                                Text("No game")
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 6) {
                                teamLogoView(teamName: fixture.opponentTeamName, size: 14)
                                Text(fixtureOpponentText(fixture))
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        fixtureDifficultyBadge(fixture)
                            .frame(width: difficultyWidth, alignment: .leading)

                        if fixture.isBlank {
                            Text("-")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: xpWidth, alignment: .trailing)
                        } else {
                            Text(
                                expectedPointsForDetailsFixture(
                                    details: details,
                                    fixture: fixture,
                                    fixtureIndex: index
                                )
                                .formatted(.number.precision(.fractionLength(1)))
                            )
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: xpWidth, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var historyHeader: some View {
        HStack(spacing: 8) {
            headerCell("GW", width: 30)
            Text("Opponent")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerCell("Pts", width: 40)
            headerCell("MP", width: 52)
            headerCell("GS", width: 28)
            headerCell("A", width: 28)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func historyRow(_ row: FantasyPlayerDetailsData.HistoryRow) -> some View {
        HStack(spacing: 8) {
            Text("\(row.gameweek)")
                .font(.caption.monospacedDigit())
                .frame(width: 30, alignment: .leading)

            HStack(spacing: 6) {
                teamLogoView(teamName: row.opponentTeamName, size: 16)
                Text("\(row.opponentTeamName) (\(row.wasHome ? "H" : "A"))")
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            pointsHeatmapCell(row.points, width: 40)
            Text(minutesWithStartsText(minutes: row.minutes, starts: row.starts))
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 52, alignment: .trailing)
            valueCell(row.goalsScored, width: 28)
            valueCell(row.assists, width: 28)
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

    private func minutesWithStartsText(minutes: Int, starts: Int) -> String {
        guard starts > 1 else { return "\(minutes)" }
        return "\(minutes) (\(starts))"
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

    @ViewBuilder
    private func teamLogoView(teamName: String, size: CGFloat) -> some View {
        let resolvedTeamName = FantasyTeamShortNameMappingsStore.shared.resolveTeamName(for: teamName)
        Group {
            if let logo = LogoResolver.shared.image(for: resolvedTeamName) ?? LogoResolver.shared.image(for: teamName) {
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
        let text = fixture.difficulty.map(String.init) ?? "-"
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

    private var recommendationPriceColumnWidth: CGFloat { 54 }
    private var recommendationNextDifficultyColumnWidth: CGFloat { 86 }
    private var recommendationChevronColumnWidth: CGFloat { 20 }
    private var recommendationGameweekColumnWidth: CGFloat { 62 }
    private var recommendationTrailingStatColumnWidth: CGFloat { 60 }
    private var recommendationSecondaryTrailingStatColumnWidth: CGFloat { 52 }

    private var transferRecommendationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transfer recommendations")
                .font(.headline)

            if isLoadingTransferRecommendations {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding recommendations...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let transferRecommendationsErrorMessage {
                Text(transferRecommendationsErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let transferRecommendations {
                transferRecommendationGroup(
                    groupID: "similar",
                    title: "Similar value",
                    subtitle: "Top options within a similar budget",
                    items: transferRecommendations.similarValue
                )

                transferRecommendationGroup(
                    groupID: "budget",
                    title: "Budget options",
                    subtitle: "Top lower-cost alternatives",
                    items: transferRecommendations.budget
                )
            } else {
                Text("No transfer recommendations available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func transferRecommendationGroup(
        groupID: String,
        title: String,
        subtitle: String,
        items: [FantasyTransferRecommendation]
    ) -> some View {
        let topItems = Array(items.prefix(10))
        let scoreRange = recommendationScoreRange(topItems)

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if topItems.isEmpty {
                Text("No players found for this filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    transferRecommendationHeaderRow
                        .padding(.bottom, 4)

                    ForEach(Array(topItems.enumerated()), id: \.element.id) { index, recommendation in
                        transferRecommendationRow(
                            recommendation,
                            groupID: groupID,
                            strength: recommendationStrength(
                                recommendation.recommendationScore,
                                in: scoreRange
                            )
                        )
                        if index < topItems.count - 1 {
                            Divider()
                                .overlay(Color.secondary.opacity(0.22))
                                .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
    }

    private var transferRecommendationHeaderRow: some View {
        HStack(spacing: 8) {
            transferRecommendationHeaderCell("Player", alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            transferRecommendationHeaderCell("Price", width: recommendationPriceColumnWidth, alignment: .trailing)
            transferRecommendationHeaderCell(
                "Next game",
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            transferRecommendationHeaderCell(
                "Difficulty",
                width: recommendationNextDifficultyColumnWidth,
                alignment: .leading
            )
            Color.clear
                .frame(width: recommendationChevronColumnWidth, height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func transferRecommendationHeaderCell(
        _ title: String,
        width: CGFloat? = nil,
        alignment: Alignment
    ) -> some View {
        let text = Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        if let width {
            text.frame(width: width, alignment: alignment)
        } else {
            text.frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    private func transferRecommendationRow(
        _ item: FantasyTransferRecommendation,
        groupID: String,
        strength: Double
    ) -> some View {
        let key = recommendationRowKey(groupID: groupID, elementID: item.elementID)
        let isExpanded = expandedRecommendationRows.contains(key)
        let fixtures = normalizedRecommendationUpcomingFixtures(item.upcomingFixtures)
        let nextThreeFixtures = Array(fixtures.prefix(3))
        let nextFixture = fixtures.first
        let rowDetails = recommendationDetailsByElementID[item.elementID]
        let isLoadingRowDetails = loadingRecommendationDetailElementIDs.contains(item.elementID)
        let rowErrorMessage = recommendationDetailErrorsByElementID[item.elementID]

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                let wasExpanded = expandedRecommendationRows.contains(key)
                toggleRecommendationRow(key: key)
                if !wasExpanded {
                    Task {
                        await loadRecommendationDetailsIfNeeded(for: item.elementID)
                    }
                }
            } label: {
                transferRecommendationMainRow(
                    item: item,
                    nextFixture: nextFixture,
                    nextThreeFixtures: nextThreeFixtures,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                recommendationExpandedDetailsSection(
                    item: item,
                    fixtures: fixtures,
                    strength: strength,
                    rowDetails: rowDetails,
                    isLoadingRowDetails: isLoadingRowDetails,
                    rowErrorMessage: rowErrorMessage
                )
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transferRecommendationMainRow(
        item: FantasyTransferRecommendation,
        nextFixture: FantasyTransferRecommendation.Fixture?,
        nextThreeFixtures: [FantasyTransferRecommendation.Fixture],
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                teamLogoView(teamName: item.teamName, size: 16)
                Text(item.webName.isEmpty ? item.playerName : item.webName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: "£%.1f", item.nowCostMillions))
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: recommendationPriceColumnWidth, alignment: .trailing)

            HStack(spacing: 6) {
                if let nextFixture {
                    if nextFixture.isBlank {
                        noGameIcon(size: 14)
                        Text("No game")
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        teamLogoView(teamName: nextFixture.opponentShortName, size: 14)
                        Text(nextFixture.displayLabel)
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                } else {
                    noGameIcon(size: 14)
                    Text("No game")
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            recommendationDifficultyDots(fixtures: nextThreeFixtures)
                .frame(width: recommendationNextDifficultyColumnWidth, alignment: .leading)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: recommendationChevronColumnWidth, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func recommendationDifficultyDots(
        fixtures: [FantasyTransferRecommendation.Fixture]
    ) -> some View {
        let nextThree = Array(fixtures.prefix(3))
        return HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                let fixture = index < nextThree.count ? nextThree[index] : nil
                let color: Color = {
                    guard let fixture else { return Color.secondary.opacity(0.28) }
                    if fixture.isBlank {
                        return Color.secondary.opacity(0.65)
                    }
                    return fixtureDifficultyColor(fixture.difficulty).opacity(0.96)
                }()

                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
            }
        }
        .frame(minHeight: 18, alignment: .center)
    }

    private func normalizedRecommendationUpcomingFixtures(
        _ fixtures: [FantasyTransferRecommendation.Fixture]
    ) -> [FantasyTransferRecommendation.Fixture] {
        guard !fixtures.isEmpty else { return [] }

        var fixturesByGameweek: [Int: FantasyTransferRecommendation.Fixture] = [:]
        for fixture in fixtures.sorted(by: { $0.gameweek < $1.gameweek }) {
            if fixturesByGameweek[fixture.gameweek] == nil {
                fixturesByGameweek[fixture.gameweek] = fixture
            }
        }

        let startGameweek = max(1, selection.gameweekID + 1)

        return (0..<5).map { offset in
            let gameweek = startGameweek + offset
            if let fixture = fixturesByGameweek[gameweek] {
                return fixture
            }
            return FantasyTransferRecommendation.Fixture.blank(gameweek: gameweek)
        }
    }

    private func recommendationExpandedDetailsSection(
        item: FantasyTransferRecommendation,
        fixtures: [FantasyTransferRecommendation.Fixture],
        strength: Double,
        rowDetails: FantasyPlayerDetailsData?,
        isLoadingRowDetails: Bool,
        rowErrorMessage: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoadingRowDetails {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading player details...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let rowDetails {
                recommendationStrengthSection(strength: strength)
                recommendationKeyStatsSection(metrics: rowDetails.metrics)
                recommendationNextFixturesTable(item: item, fixtures: fixtures)
                recommendationPreviousFixturesTable(details: rowDetails)
            } else {
                if let rowErrorMessage {
                    Text(rowErrorMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                recommendationStrengthSection(strength: strength)
                recommendationNextFixturesTable(item: item, fixtures: fixtures)
            }
        }
    }

    private func recommendationStrengthSection(strength: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recommendation strength")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            recommendationStrengthBar(strength)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 10)
        }
    }

    private func recommendationKeyStatsSection(
        metrics: [FantasyPlayerDetailsData.Metric]
    ) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

        return VStack(alignment: .leading, spacing: 6) {
            Text("Key stats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(metrics.prefix(8), id: \.title) { metric in
                    VStack(spacing: 2) {
                        Text(metric.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(metric.value)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
        }
    }

    private func recommendationNextFixturesTable(
        item: FantasyTransferRecommendation,
        fixtures: [FantasyTransferRecommendation.Fixture]
    ) -> some View {
        let gameweekWidth = recommendationGameweekColumnWidth
        let difficultyWidth = recommendationTrailingStatColumnWidth
        let xpWidth = recommendationSecondaryTrailingStatColumnWidth

        return VStack(alignment: .leading, spacing: 6) {
            Text("Next 5 fixtures")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if fixtures.isEmpty {
                Text("No upcoming fixtures")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    transferRecommendationHeaderCell("Gameweek", width: gameweekWidth, alignment: .leading)
                    transferRecommendationHeaderCell("Opponent", alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    transferRecommendationHeaderCell("Difficulty", width: difficultyWidth, alignment: .leading)
                    transferRecommendationHeaderCell("xP", width: xpWidth, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(Array(fixtures.prefix(5).enumerated()), id: \.element.id) { index, fixture in
                    HStack(spacing: 8) {
                        Text("GW\(fixture.gameweek)")
                            .font(.caption.monospacedDigit())
                            .frame(width: gameweekWidth, alignment: .leading)

                        if fixture.isBlank {
                            HStack(spacing: 6) {
                                noGameIcon(size: 14)
                                Text("No game")
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 6) {
                                teamLogoView(teamName: fixture.opponentShortName, size: 14)
                                Text(fixture.displayLabel)
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        recommendationDifficultyPill(fixture.difficulty)
                            .frame(width: difficultyWidth, alignment: .leading)

                        if fixture.isBlank {
                            Text("0.0")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: xpWidth, alignment: .trailing)
                        } else {
                            Text(
                                expectedPointsForFixture(
                                    recommendation: item,
                                    fixture: fixture,
                                    fixtureIndex: index
                                )
                                .formatted(.number.precision(.fractionLength(1)))
                            )
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: xpWidth, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recommendationPreviousFixturesTable(
        details: FantasyPlayerDetailsData
    ) -> some View {
        let rows = recommendationPreviousHistoryRowsWithBlanks(from: details)
        let gameweekWidth = recommendationGameweekColumnWidth
        let pointsWidth = recommendationTrailingStatColumnWidth
        let minutesWidth = recommendationSecondaryTrailingStatColumnWidth
        let pointsRange = recommendationPointsRange(rows)

        return VStack(alignment: .leading, spacing: 6) {
            Text("Previous 5 fixtures")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text("No recent fixtures")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    transferRecommendationHeaderCell("Gameweek", width: gameweekWidth, alignment: .leading)
                    transferRecommendationHeaderCell("Opponent", alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    transferRecommendationHeaderCell("Pts", width: pointsWidth, alignment: .trailing)
                    transferRecommendationHeaderCell("MP", width: minutesWidth, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Text("GW\(row.gameweek)")
                            .font(.caption.monospacedDigit())
                            .frame(width: gameweekWidth, alignment: .leading)

                        if row.opponentTeamID <= 0 {
                            HStack(spacing: 6) {
                                noGameIcon(size: 14)
                                Text("No game")
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 6) {
                                teamLogoView(teamName: row.opponentTeamName, size: 14)
                                Text("\(teamAbbreviation(row.opponentTeamName)) (\(row.wasHome ? "H" : "A"))")
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        recommendationPreviousPointsPill(
                            points: row.points,
                            range: pointsRange
                        )
                            .frame(width: pointsWidth, alignment: .trailing)

                        Text(
                            row.opponentTeamID <= 0
                                ? "-"
                                : minutesWithStartsText(minutes: row.minutes, starts: row.starts)
                        )
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: minutesWidth, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recommendationPreviousHistoryRowsWithBlanks(
        from details: FantasyPlayerDetailsData
    ) -> [FantasyPlayerDetailsData.HistoryRow] {
        var playedRowsByGameweek: [Int: FantasyPlayerDetailsData.HistoryRow] = [:]
        for row in details.historyRows where row.minutes > 0 {
            if playedRowsByGameweek[row.gameweek] == nil {
                playedRowsByGameweek[row.gameweek] = row
            }
        }

        guard let latestPlayedGameweek = playedRowsByGameweek.keys.max() else {
            return []
        }

        let upcomingStartsAtCurrentGameweek = details.upcomingFixtures.first?.gameweek == selection.gameweekID
        let targetStartGameweek = max(
            1,
            upcomingStartsAtCurrentGameweek
                ? (selection.gameweekID - 1)
                : selection.gameweekID
        )
        let effectiveStartGameweek = max(targetStartGameweek, latestPlayedGameweek)
        let floorGameweek = max(1, effectiveStartGameweek - 4)

        return stride(from: effectiveStartGameweek, through: floorGameweek, by: -1)
            .map { gameweek in
                if let row = playedRowsByGameweek[gameweek] {
                    return row
                }
                return FantasyPlayerDetailsData.HistoryRow(
                    gameweek: gameweek,
                    opponentTeamID: -1,
                    opponentTeamName: "No game",
                    wasHome: true,
                    points: 0,
                    starts: 0,
                    minutes: 0,
                    goalsScored: 0,
                    assists: 0,
                    expectedGoals: "0.0"
                )
            }
    }

    private func recommendationPointsRange(
        _ rows: [FantasyPlayerDetailsData.HistoryRow]
    ) -> (min: Int, max: Int) {
        let points = rows.map(\.points)
        guard let minValue = points.min(), let maxValue = points.max() else {
            return (0, 0)
        }
        return (minValue, maxValue)
    }

    private func recommendationPreviousPointsPill(
        points: Int,
        range: (min: Int, max: Int)
    ) -> some View {
        let color = recommendationPreviousPointsColor(points: points, range: range)

        return Text("\(points)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.94))
            )
    }

    private func recommendationPreviousPointsColor(
        points: Int,
        range: (min: Int, max: Int)
    ) -> Color {
        if range.min == range.max {
            return points > 0 ? Color.green : Color.red
        }
        let normalized = Double(points - range.min) / Double(max(1, range.max - range.min))
        let hue = 0.02 + (0.34 * min(max(normalized, 0), 1))
        return Color(hue: hue, saturation: 0.78, brightness: 0.90)
    }

    private func recommendationDifficultyPill(_ difficulty: Int?) -> some View {
        let color = fixtureDifficultyColor(difficulty)
        let text = difficulty.map(String.init) ?? "-"

        return Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(difficulty == nil ? Color.secondary : Color.white)
            .frame(minWidth: 40, alignment: .center)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(difficulty == nil ? 0.20 : 0.92))
            )
    }

    private func teamAbbreviation(_ teamName: String) -> String {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "TBD" }
        let tokens = trimmed
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        if tokens.count >= 2 {
            let first = tokens[0].prefix(1)
            let second = tokens[1].prefix(2)
            let combined = "\(first)\(second)".uppercased()
            if combined.count == 3 { return combined }
        }

        let lettersOnly = trimmed
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        if lettersOnly.count >= 3 {
            return String(lettersOnly.prefix(3))
        }
        return lettersOnly.isEmpty ? "TBD" : lettersOnly
    }

    private func expectedPointsForFixture(
        recommendation: FantasyTransferRecommendation,
        fixture: FantasyTransferRecommendation.Fixture,
        fixtureIndex: Int
    ) -> Double {
        if fixture.isBlank {
            return 0
        }
        // Previous-10 proxy: blend season PPG with recent form, then scale by fixture context.
        let previousTenProxyAverage =
            max(0.0, (recommendation.pointsPerGame * 0.65) + (recommendation.form * 0.35))

        let formVsPPG = recommendation.pointsPerGame > 0
            ? recommendation.form / max(recommendation.pointsPerGame, 0.1)
            : 1.0
        let momentumMultiplier = min(max(formVsPPG, 0.78), 1.25)

        let difficultyMultiplier: Double = {
            switch fixture.difficulty ?? 3 {
            case ...1: return 1.32
            case 2: return 1.16
            case 3: return 1.0
            case 4: return 0.84
            default: return 0.68
            }
        }()

        let availabilityMultiplier: Double = {
            if recommendation.availability == "unavailable" { return 0.35 }
            if recommendation.availability == "doubtful" { return 0.70 }
            return 1.0
        }()

        let homeAwayMultiplier: Double = fixture.isHome ? 1.04 : 0.96
        let horizonDecay = 1.0 - (Double(fixtureIndex) * 0.02)

        let raw = previousTenProxyAverage *
            momentumMultiplier *
            difficultyMultiplier *
            availabilityMultiplier *
            homeAwayMultiplier *
            max(0.85, horizonDecay)

        let bounded = min(max(raw, 0.0), 20.0)
        return (bounded * 10).rounded() / 10
    }

    private func expectedPointsForDetailsFixture(
        details: FantasyPlayerDetailsData,
        fixture: FantasyPlayerDetailsData.UpcomingFixture,
        fixtureIndex: Int
    ) -> Double {
        let pointsPerMatch = metricDouble(details.metrics, title: "Pts / Match") ?? 0
        let form = metricDouble(details.metrics, title: "Form") ?? pointsPerMatch
        let previousTen = details.historyRows.prefix(10).map(\.points)
        let previousTenAverage = previousTen.isEmpty
            ? ((pointsPerMatch * 0.65) + (form * 0.35))
            : Double(previousTen.reduce(0, +)) / Double(previousTen.count)

        let formVsPPG = pointsPerMatch > 0
            ? form / max(pointsPerMatch, 0.1)
            : 1.0
        let momentumMultiplier = min(max(formVsPPG, 0.78), 1.25)

        let difficultyMultiplier: Double = {
            switch fixture.difficulty ?? 3 {
            case ...1: return 1.32
            case 2: return 1.16
            case 3: return 1.0
            case 4: return 0.84
            default: return 0.68
            }
        }()

        let homeAwayMultiplier: Double = fixture.isHome == true ? 1.04 : 0.96
        let horizonDecay = 1.0 - (Double(fixtureIndex) * 0.02)

        let raw = previousTenAverage *
            momentumMultiplier *
            difficultyMultiplier *
            homeAwayMultiplier *
            max(0.85, horizonDecay)

        let bounded = min(max(raw, 0.0), 20.0)
        return (bounded * 10).rounded() / 10
    }

    private func metricDouble(
        _ metrics: [FantasyPlayerDetailsData.Metric],
        title: String
    ) -> Double? {
        guard let value = metrics.first(where: { $0.title == title })?.value else {
            return nil
        }
        let normalized = value
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    private func recommendationStrengthBar(_ strength: Double) -> some View {
        let clamped = min(max(strength, 0), 1)
        let fillRatio = 0.2 + (0.8 * clamped)
        let color = recommendationStrengthColor(clamped)

        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.12))
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: max(4, proxy.size.width * fillRatio))
            }
        }
        .frame(height: 8)
    }

    private func recommendationStrengthColor(_ strength: Double) -> Color {
        let clamped = min(max(strength, 0), 1)
        let hue = 0.02 + (0.34 * clamped) // red -> green
        return Color(hue: hue, saturation: 0.78, brightness: 0.88)
    }

    private func recommendationScoreRange(
        _ items: [FantasyTransferRecommendation]
    ) -> (min: Double, max: Double) {
        let scores = items.map(\.recommendationScore)
        guard let minScore = scores.min(), let maxScore = scores.max() else {
            return (0, 100)
        }
        return (minScore, maxScore)
    }

    private func recommendationStrength(
        _ score: Double,
        in range: (min: Double, max: Double)
    ) -> Double {
        let span = max(0.0001, range.max - range.min)
        return min(max((score - range.min) / span, 0), 1)
    }

    private func recommendationRowKey(groupID: String, elementID: Int) -> String {
        "\(groupID)-\(elementID)"
    }

    private func toggleRecommendationRow(key: String) {
        if expandedRecommendationRows.contains(key) {
            expandedRecommendationRows.remove(key)
        } else {
            expandedRecommendationRows.insert(key)
        }
    }

    private func loadRecommendationDetailsIfNeeded(for elementID: Int) async {
        if recommendationDetailsByElementID[elementID] != nil { return }
        if loadingRecommendationDetailElementIDs.contains(elementID) { return }

        if elementID == selection.player.elementID, let details {
            recommendationDetailsByElementID[elementID] = details
            recommendationDetailErrorsByElementID[elementID] = nil
            return
        }

        loadingRecommendationDetailElementIDs.insert(elementID)
        recommendationDetailErrorsByElementID[elementID] = nil
        defer {
            loadingRecommendationDetailElementIDs.remove(elementID)
        }

        do {
            let loaded = try await fantasyViewModel.loadPlayerDetails(
                elementID: elementID,
                gameweekID: selection.gameweekID,
                apiBaseURL: apiBaseURL
            )
            recommendationDetailsByElementID[elementID] = loaded
        } catch {
            recommendationDetailErrorsByElementID[elementID] = "Could not load expanded details."
        }
    }

    private func userFriendlyTransferRecommendationError(_ error: Error) -> String {
        let message = error.localizedDescription
        let normalized = message
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.contains("game is being updated") || normalized.contains("temporarily unavailable") {
            return "Transfer recommendations are temporarily unavailable while Fantasy Football updates."
        }
        return "Could not load transfer recommendations right now."
    }

    private func loadTransferRecommendations(elementID: Int) async {
        isLoadingTransferRecommendations = true
        transferRecommendationsErrorMessage = nil

        do {
            let recommendations = try await fantasyViewModel.fetchTransferRecommendations(
                elementID: elementID,
                gameweekID: selection.gameweekID,
                apiBaseURL: apiBaseURL
            )
            transferRecommendations = recommendations
        } catch {
            transferRecommendations = nil
            transferRecommendationsErrorMessage = userFriendlyTransferRecommendationError(error)
        }

        isLoadingTransferRecommendations = false
    }

    private func loadDetails() async {
        isLoading = true
        errorMessage = nil
        transferRecommendations = nil
        transferRecommendationsErrorMessage = nil
        isLoadingTransferRecommendations = false
        expandedRecommendationRows = []
        recommendationDetailsByElementID = [:]
        loadingRecommendationDetailElementIDs = []
        recommendationDetailErrorsByElementID = [:]

        do {
            let loaded = try await fantasyViewModel.loadPlayerDetails(
                elementID: selection.player.elementID,
                gameweekID: selection.gameweekID,
                apiBaseURL: apiBaseURL
            )
            details = loaded
            isLoading = false
            await loadTransferRecommendations(elementID: loaded.elementID)
            return
        } catch {
            details = nil
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
