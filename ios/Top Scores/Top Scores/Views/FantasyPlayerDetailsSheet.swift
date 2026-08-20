import SwiftUI
import UIKit

struct FantasyPlayerDetailsSheet: View {
    private enum DetailsTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case history = "History"
        case stats = "Stats"
        case comparison = "Comparison"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: return "chart.bar.xaxis"
            case .history: return "clock.arrow.circlepath"
            case .stats: return "chart.bar.doc.horizontal"
            case .comparison: return "rectangle.split.3x1"
            }
        }
    }

    private enum RecommendationRoute: String, Identifiable {
        case browse
        case comparison

        var id: String { rawValue }
    }

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
    @State private var selectedTab: DetailsTab = .overview
    @State private var recommendationRoute: RecommendationRoute?
    @State private var comparisonElementIDs: [Int] = []
    @State private var recommendationNavigationStartedAt: Date?

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
                        VStack(alignment: .leading, spacing: 16) {
                            premiumPlayerHeader(details)
                            if !details.statusUpdates.isEmpty {
                                availabilitySection(details)
                            }
                            expectedPointsSummary(details)
                            fixturesSection(details)
                            detailsTabBar
                            selectedTabContent(details)
                            transferRecommendationsButton
                            ictIndexFootnote
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .refreshable {
                        await loadDetails()
                    }
                } else {
                    unavailableState
                }
            }
            .background(Color(red: 0.025, green: 0.035, blue: 0.031).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $recommendationRoute) { route in
                transferRecommendationsScreen(selectionMode: route == .comparison)
            }
        }
        .task(id: selection.id) {
            selectedTab = .overview
            await loadDetails()
        }
    }

    private func premiumPlayerHeader(_ details: FantasyPlayerDetailsData) -> some View {
        let firstFixture = details.upcomingFixtures.first(where: { !$0.isBlank })

        return ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.17, blue: 0.10),
                    Color(red: 0.015, green: 0.07, blue: 0.05),
                    Color.black.opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(alignment: .bottom, spacing: 8) {
                playerPortrait(url: details.profileImageURL)
                    .frame(width: 140, height: 210, alignment: .bottom)

                VStack(alignment: .leading, spacing: 10) {
                    Text(details.position)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.green)

                    Text(details.playerName)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    HStack(spacing: 8) {
                        teamLogoView(teamName: details.teamName, size: 22)
                        Text(details.teamName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.86))
                    }

                    HStack(spacing: 0) {
                        headerMetric(metricValue(details, title: "Price"), label: "Price")
                        headerMetric(
                            details.ownershipPercent.formatted(.number.precision(.fractionLength(1))) + "%",
                            label: "Ownership"
                        )
                        headerMetric(metricValue(details, title: "ICT Index"), label: "ICT Index")
                    }
                    .padding(.top, 8)
                }
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let difficulty = firstFixture?.difficulty {
                VStack(spacing: 4) {
                    Text("\(difficulty)")
                        .font(.title3.monospacedDigit().weight(.heavy))
                        .foregroundStyle(difficulty <= 2 ? Color.black.opacity(0.82) : Color.white)
                        .frame(width: 44, height: 44)
                        .background(fixtureDifficultyColor(difficulty), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    Text("Difficulty")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                .padding(12)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.36), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            }
            .accessibilityLabel("Close")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(12)
        }
        .frame(height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.green.opacity(0.16), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func playerPortrait(url: URL?) -> some View {
        FantasyPlayerProfileImage(url: url, size: 140, height: 210)
    }

    private func headerMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func expectedPointsSummary(_ details: FantasyPlayerDetailsData) -> some View {
        let firstFixture = details.upcomingFixtures.first(where: { !$0.isBlank })
        let fixtureIndex = firstFixture.flatMap { details.upcomingFixtures.firstIndex(of: $0) } ?? 0
        let expectedPoints = firstFixture.map {
            FantasyExpectedPointsEstimator.estimate(details: details, fixture: $0, fixtureIndex: fixtureIndex)
        }

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Expected points")
                        .font(.subheadline.weight(.semibold))
                    if let gameweek = firstFixture?.gameweek {
                        Text("GW \(gameweek)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(expectedPoints.map { fantasyExpectedPointsText($0) + " xP" } ?? "—")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.78, green: 0.38, blue: 1.0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                LinearGradient(
                    colors: [Color.purple.opacity(0.16), Color(.secondarySystemGroupedBackground)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.purple.opacity(0.62), lineWidth: 1)
            )

            compactMetric(title: "Form", value: metricValue(details, title: "Form"), accent: .green)
            compactMetric(title: "Pts / match", value: metricValue(details, title: "Pts / Match"), accent: .white)
        }
    }

    private func compactMetric(title: String, value: String, accent: Color) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(accent)
        }
        .frame(width: 86, height: 80)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var detailsTabBar: some View {
        HStack(spacing: 0) {
            ForEach(DetailsTab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.caption.weight(.semibold))
                        Text(tab.rawValue)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedTab == tab ? Color.green : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        selectedTab == tab ? Color.white.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    @ViewBuilder
    private func selectedTabContent(_ details: FantasyPlayerDetailsData) -> some View {
        switch selectedTab {
        case .overview:
            overviewTab(details)
        case .history:
            historyTab(details)
        case .stats:
            statsTab(details)
        case .comparison:
            comparisonTab(details)
        }
    }

    private var transferRecommendationsButton: some View {
        Button {
            recommendationNavigationStartedAt = Date()
            recommendationRoute = .browse
            loadTransferRecommendationsIfNeeded()
        } label: {
            Label("View transfer recommendations", systemImage: "arrow.left.arrow.right")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.35, green: 0.03, blue: 0.48), Color(red: 0.55, green: 0.06, blue: 0.62)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private var ictIndexFootnote: some View {
        Text("ICT Index combines a player's influence, creativity and threat, as calculated by FPL.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func overviewTab(_ details: FantasyPlayerDetailsData) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                sectionContainer(title: "This season") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 14) {
                        overviewMetric("Total points", metricValue(details, title: "Total Pts"))
                        overviewMetric("Clean sheets", "\(details.seasonTotals.cleanSheets)")
                        overviewMetric("Saves", "\(details.seasonTotals.saves)")
                        overviewMetric("Goals", "\(details.seasonTotals.goals)")
                        overviewMetric("Assists", "\(details.seasonTotals.assists)")
                        overviewMetric("Bonus", "\(details.seasonTotals.bonus)")
                    }
                }

                ownershipPanel(details)
                    .frame(width: 132)
            }

            recentMatchesSection(details)
        }
    }

    private func sectionContainer<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
    }

    private func overviewMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }

    private func ownershipPanel(_ details: FantasyPlayerDetailsData) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Ownership")
                .font(.headline)
            Text(details.ownershipPercent.formatted(.number.precision(.fractionLength(1))) + "%")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.11))
                    Capsule()
                        .fill(Color.purple)
                        .frame(width: proxy.size.width * min(max(details.ownershipPercent / 100, 0), 1))
                }
            }
            .frame(height: 8)
            if let managerCount = ownedManagerCount(details) {
                Text("\(compactNumber(managerCount)) managers")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(ownershipDescription(details.ownershipPercent))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.purple.opacity(0.95))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.purple.opacity(0.13), in: Capsule())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
    }

    private func recentMatchesSection(_ details: FantasyPlayerDetailsData) -> some View {
        sectionContainer(title: "Recent matches") {
            if hasPlayedMatches(details) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(details.historyRows.prefix(5)) { row in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text("GW \(row.gameweek)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(row.points) pts")
                                        .font(.caption2.monospacedDigit().weight(.bold))
                                        .foregroundStyle(pointsHeatmapColor(row.points))
                                }
                                Text("\(teamAbbreviation(row.opponentTeamName)) (\(row.wasHome ? "H" : "A"))")
                                    .font(.subheadline.weight(.semibold))
                                HStack(spacing: 14) {
                                    matchMetric("Min", "\(row.minutes)")
                                    matchMetric("G", "\(row.goalsScored)")
                                    matchMetric("A", "\(row.assists)")
                                }
                            }
                            .padding(12)
                            .frame(width: 154, alignment: .leading)
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(pointsHeatmapColor(row.points).opacity(0.28), lineWidth: 1)
                            )
                        }
                    }
                }
            } else {
                matchHistoryEmptyState
            }
        }
    }

    private func matchMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func hasPlayedMatches(_ details: FantasyPlayerDetailsData) -> Bool {
        details.historyRows.contains { $0.minutes > 0 }
    }

    private var matchHistoryEmptyState: some View {
        Label("Match data will appear once the season starts and this player takes part.", systemImage: "clock")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func historyTab(_ details: FantasyPlayerDetailsData) -> some View {
        VStack(spacing: 14) {
            historySection(details)
            pointsTimeline(details)
        }
    }

    private func pointsTimeline(_ details: FantasyPlayerDetailsData) -> some View {
        let rows = Array(details.historyRows.reversed())
        let maximum = max(rows.map(\.points).max() ?? 1, 1)

        return sectionContainer(title: "Points timeline") {
            if hasPlayedMatches(details) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(rows) { row in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.purple)
                                .frame(height: max(5, 88 * CGFloat(row.points) / CGFloat(maximum)))
                            Text("\(row.gameweek)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 116, alignment: .bottom)
            } else {
                matchHistoryEmptyState
            }
        }
    }

    private func statsTab(_ details: FantasyPlayerDetailsData) -> some View {
        let minutes = max(details.seasonTotals.minutes, 1)

        return VStack(spacing: 14) {
            sectionContainer(title: "Key stats") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    premiumStat("Points / match", metricValue(details, title: "Pts / Match"), rank: nil)
                    premiumStat("Form", metricValue(details, title: "Form"), rank: nil)
                    premiumStat("ICT index", metricValue(details, title: "ICT Index"), rank: nil)
                    premiumStat("Goals / 90", per90(details.seasonTotals.goals, minutes: minutes), rank: nil)
                    premiumStat("Assists / 90", per90(details.seasonTotals.assists, minutes: minutes), rank: nil)
                    premiumStat("Saves / 90", per90(details.seasonTotals.saves, minutes: minutes), rank: nil)
                }
            }

            sectionContainer(title: "Season breakdown") {
                VStack(spacing: 12) {
                    statBreakdownRow("Minutes", value: details.seasonTotals.minutes, maximum: max(details.seasonTotals.minutes, 1))
                    statBreakdownRow("Clean sheets", value: details.seasonTotals.cleanSheets, maximum: max(10, details.seasonTotals.cleanSheets))
                    statBreakdownRow("Goals conceded", value: details.seasonTotals.goalsConceded, maximum: max(30, details.seasonTotals.goalsConceded))
                    statBreakdownRow("Bonus points", value: details.seasonTotals.bonus, maximum: max(20, details.seasonTotals.bonus))
                    statBreakdownRow("Penalties saved", value: details.seasonTotals.penaltiesSaved, maximum: max(3, details.seasonTotals.penaltiesSaved))
                    statBreakdownRow("Yellow cards", value: details.seasonTotals.yellowCards, maximum: max(8, details.seasonTotals.yellowCards))
                }
            }

            if !details.latestPointsBreakdown.isEmpty {
                latestPointsBreakdownSection(details)
            }
        }
    }

    private func premiumStat(_ title: String, _ value: String, rank: String?) -> some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(value)
                .font(.title3.monospacedDigit().weight(.bold))
            if let rank {
                Text(rank)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 82)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func statBreakdownRow(_ title: String, value: Int, maximum: Int) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .frame(width: 112, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule()
                        .fill(Color.purple.opacity(0.86))
                        .frame(width: proxy.size.width * CGFloat(value) / CGFloat(max(maximum, 1)))
                }
            }
            .frame(height: 7)
            Text("\(value)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func comparisonTab(_ details: FantasyPlayerDetailsData) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionContainer(title: "Compare players") {
                Text("Select up to three recommended replacements.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        comparisonPlayerCard(
                            name: details.playerName,
                            team: details.teamName,
                            imageURL: details.profileImageURL,
                            removable: false,
                            elementID: details.elementID
                        )

                        ForEach(comparisonRecommendations) { item in
                            comparisonPlayerCard(
                                name: item.webName.isEmpty ? item.playerName : item.webName,
                                team: item.teamShortName ?? item.teamName,
                                imageURL: recommendationDetailsByElementID[item.elementID]?.profileImageURL ?? item.profileImageURL,
                                removable: true,
                                elementID: item.elementID
                            )
                        }
                    }
                }

                Button {
                    recommendationRoute = .comparison
                    loadTransferRecommendationsIfNeeded()
                } label: {
                    Label("Choose comparison players", systemImage: "person.2.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
            }

            comparisonMetrics(details)
        }
    }

    private var comparisonRecommendations: [FantasyTransferRecommendation] {
        allTransferRecommendations.filter { comparisonElementIDs.contains($0.elementID) }
    }

    private func comparisonPlayerCard(
        name: String,
        team: String,
        imageURL: URL?,
        removable: Bool,
        elementID: Int
    ) -> some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                FantasyPlayerProfileImage(url: imageURL, size: 68)
                if removable {
                    Button {
                        comparisonElementIDs.removeAll { $0 == elementID }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .frame(width: 20, height: 20)
                            .background(Color.black.opacity(0.72), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(team)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 106)
        .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.green.opacity(0.30), lineWidth: 1)
        )
    }

    private func comparisonMetrics(_ details: FantasyPlayerDetailsData) -> some View {
        let selectedDetails = comparisonRecommendations.compactMap { recommendationDetailsByElementID[$0.elementID] }
        let columns = [details] + selectedDetails

        return sectionContainer(title: "Key stats") {
            if columns.count == 1 && !comparisonElementIDs.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading comparison data…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    comparisonMetricRow("Player", details: columns) { $0.playerName.components(separatedBy: " ").last ?? $0.playerName }
                    comparisonMetricRow("Price", details: columns) { metricValue($0, title: "Price") }
                    comparisonMetricRow("Form", details: columns) { metricValue($0, title: "Form") }
                    comparisonMetricRow("Points / match", details: columns) { metricValue($0, title: "Pts / Match") }
                    comparisonMetricRow("Ownership", details: columns) {
                        $0.ownershipPercent.formatted(.number.precision(.fractionLength(1))) + "%"
                    }
                    comparisonMetricRow("ICT index", details: columns) { metricValue($0, title: "ICT Index") }
                    comparisonMetricRow("Expected", details: columns) { comparisonExpectedPoints($0) }
                }
            }
        }
    }

    private func comparisonMetricRow(
        _ label: String,
        details: [FantasyPlayerDetailsData],
        value: @escaping (FantasyPlayerDetailsData) -> String
    ) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            ForEach(details, id: \.elementID) { item in
                Text(value(item))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 92, alignment: .center)
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider().opacity(0.25) }
    }

    private func comparisonExpectedPoints(_ details: FantasyPlayerDetailsData) -> String {
        guard let fixture = details.upcomingFixtures.first(where: { !$0.isBlank }) else { return "—" }
        let index = details.upcomingFixtures.firstIndex(of: fixture) ?? 0
        let value = FantasyExpectedPointsEstimator.estimate(details: details, fixture: fixture, fixtureIndex: index)
        return fantasyExpectedPointsText(value) + " xP"
    }

    private func fantasyExpectedPointsText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func transferRecommendationsScreen(selectionMode: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectionMode ? "Choose comparison players" : "Transfer recommendations")
                        .font(.title2.weight(.bold))
                    Text(selectionMode ? "Select up to three players" : "Recommended replacements for \(selection.player.displayName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isLoadingTransferRecommendations {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Finding the strongest alternatives…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if let transferRecommendationsErrorMessage {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(transferRecommendationsErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("Try again") {
                            loadTransferRecommendationsIfNeeded()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if let transferRecommendations {
                    premiumRecommendationGroup(
                        title: "Similar value",
                        subtitle: "Closest upgrades within the same price range",
                        items: Array(transferRecommendations.similarValue.prefix(10)),
                        selectionMode: selectionMode
                    )

                    premiumRecommendationGroup(
                        title: "Budget options",
                        subtitle: "Lower-cost alternatives that release funds",
                        items: Array(transferRecommendations.budget.prefix(10)),
                        selectionMode: selectionMode
                    )
                } else {
                    Text("No transfer recommendations available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if selectionMode {
                    Button {
                        recommendationRoute = nil
                    } label: {
                        Text("Done · \(comparisonElementIDs.count) selected")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
            }
            .padding(16)
        }
        .background(Color(red: 0.025, green: 0.035, blue: 0.031).ignoresSafeArea())
        .onAppear {
            guard let recommendationNavigationStartedAt else { return }
            let durationMs = Int(Date().timeIntervalSince(recommendationNavigationStartedAt) * 1000)
            diagnosticPrint("[FantasyPerf] transfer_recommendations_screen_appeared duration_ms=\(durationMs)")
            self.recommendationNavigationStartedAt = nil
        }
    }

    private func premiumRecommendationGroup(
        title: String,
        subtitle: String,
        items: [FantasyTransferRecommendation],
        selectionMode: Bool
    ) -> some View {
        sectionContainer(title: title) {
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if items.isEmpty {
                Text("No players found for this category.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        premiumRecommendationRow(item, selectionMode: selectionMode)
                        if index < items.count - 1 {
                            Divider().opacity(0.22)
                        }
                    }
                }
            }
        }
    }

    private func premiumRecommendationRow(
        _ item: FantasyTransferRecommendation,
        selectionMode: Bool
    ) -> some View {
        let fixtures = Array(normalizedRecommendationUpcomingFixtures(item.upcomingFixtures).prefix(3))
        let isSelected = comparisonElementIDs.contains(item.elementID)

        return HStack(spacing: 12) {
            FantasyPlayerProfileImage(
                url: recommendationDetailsByElementID[item.elementID]?.profileImageURL ?? item.profileImageURL,
                size: 48
            )
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.webName.isEmpty ? item.playerName : item.webName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(item.teamName) · £\(item.nowCostMillions.formatted(.number.precision(.fractionLength(1))))m")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(item.epNext.formatted(.number.precision(.fractionLength(1)))) xP")
                        .foregroundStyle(Color.purple)
                    Text("Form \(item.form.formatted(.number.precision(.fractionLength(1))))")
                    if let ownership = item.selectedByPercent {
                        Text("\(ownership.formatted(.number.precision(.fractionLength(1))))%")
                    }
                }
                .font(.caption2.monospacedDigit().weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            recommendationDifficultyDots(fixtures: fixtures)
                .frame(width: 52)

            if selectionMode {
                Button {
                    toggleComparisonPlayer(item)
                } label: {
                    Image(systemName: isSelected ? "checkmark" : "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isSelected ? Color.white : Color.purple)
                        .frame(width: 30, height: 30)
                        .background(isSelected ? Color.purple : Color.purple.opacity(0.12), in: Circle())
                        .overlay(Circle().stroke(Color.purple.opacity(0.72), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!isSelected && comparisonElementIDs.count >= 3)
                .opacity(!isSelected && comparisonElementIDs.count >= 3 ? 0.35 : 1)
                .accessibilityLabel(isSelected ? "Remove from comparison" : "Add to comparison")
            }
        }
        .padding(.vertical, 11)
    }

    private var allTransferRecommendations: [FantasyTransferRecommendation] {
        guard let transferRecommendations else { return [] }
        var seen = Set<Int>()
        return (transferRecommendations.similarValue + transferRecommendations.budget).filter {
            seen.insert($0.elementID).inserted
        }
    }

    private func toggleComparisonPlayer(_ item: FantasyTransferRecommendation) {
        if comparisonElementIDs.contains(item.elementID) {
            comparisonElementIDs.removeAll { $0 == item.elementID }
            return
        }
        guard comparisonElementIDs.count < 3 else { return }
        comparisonElementIDs.append(item.elementID)
        Task {
            await loadRecommendationDetailsIfNeeded(for: item.elementID)
        }
    }

    private func metricValue(_ details: FantasyPlayerDetailsData, title: String) -> String {
        details.metrics.first(where: { $0.title == title })?.value ?? "—"
    }

    private func per90(_ value: Int, minutes: Int) -> String {
        guard minutes > 0 else { return "0.0" }
        return (Double(value) * 90 / Double(minutes)).formatted(.number.precision(.fractionLength(1)))
    }

    private func ownedManagerCount(_ details: FantasyPlayerDetailsData) -> Int? {
        guard let totalManagers = details.totalManagers else { return nil }
        return Int((Double(totalManagers) * details.ownershipPercent / 100).rounded())
    }

    private func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 {
            return (Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(2))) + "M"
        }
        if value >= 1_000 {
            return (Double(value) / 1_000).formatted(.number.precision(.fractionLength(1))) + "K"
        }
        return "\(value)"
    }

    private func ownershipDescription(_ ownership: Double) -> String {
        switch ownership {
        case 25...: return "Highly owned"
        case 10..<25: return "Popular pick"
        case 3..<10: return "Differential"
        default: return "Rare pick"
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
            FantasyPlayerProfileImage(url: details.profileImageURL, size: 62)

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
                    let expectedPoints = fixture.isBlank
                        ? nil
                        : FantasyExpectedPointsEstimator.estimate(
                            details: details,
                            fixture: fixture,
                            fixtureIndex: index
                        )

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

                        expectedPointsPill(
                            expectedPoints?.formatted(.number.precision(.fractionLength(1))) ?? "-",
                            value: expectedPoints
                        )
                        .frame(width: xpWidth, alignment: .trailing)
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

            if hasPlayedMatches(details) {
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
            } else {
                matchHistoryEmptyState
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
            .font(.caption2.monospacedDigit().weight(.semibold))
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
                    let expectedPoints = fixture.isBlank
                        ? nil
                        : expectedPointsForFixture(
                            recommendation: item,
                            fixture: fixture,
                            fixtureIndex: index
                        )

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

                        expectedPointsPill(
                            expectedPoints?.formatted(.number.precision(.fractionLength(1))) ?? "0.0",
                            value: expectedPoints
                        )
                        .frame(width: xpWidth, alignment: .trailing)
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
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 40, alignment: .center)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
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

    private func expectedPointsPill(_ text: String, value: Double?) -> some View {
        let color = expectedPointsPillColor(value)

        return Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(value == nil ? Color.secondary : expectedPointsPillForegroundColor(value))
            .frame(minWidth: 40, alignment: .center)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(value == nil ? 0.20 : 0.92))
            )
    }

    private func expectedPointsPillColor(_ value: Double?) -> Color {
        guard let value else { return Color.gray }
        switch value {
        case ..<2.0:
            return Color.red
        case ..<4.0:
            return Color.orange
        case ..<6.0:
            return Color.yellow
        default:
            return Color.green
        }
    }

    private func expectedPointsPillForegroundColor(_ value: Double?) -> Color {
        guard let value else { return Color.secondary }
        return value >= 4.0 ? Color.black.opacity(0.82) : Color.white
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
            return "Transfer recommendations are temporarily unavailable while Fantasy Premier League updates."
        }
        return "Could not load transfer recommendations right now."
    }

    private var userSquadElementIDs: Set<Int> {
        Set(fantasyViewModel.data?.allPlayers.map(\.elementID) ?? [])
    }

    private func filteredTransferRecommendations(
        _ response: FantasyTransferRecommendationsResponse
    ) -> FantasyTransferRecommendationsResponse {
        let excludedElementIDs = userSquadElementIDs
        guard !excludedElementIDs.isEmpty else { return response }

        return FantasyTransferRecommendationsResponse(
            source: response.source,
            updatedAt: response.updatedAt,
            ageSeconds: response.ageSeconds,
            stale: response.stale,
            criteria: response.criteria,
            similarValue: response.similarValue.filter { !excludedElementIDs.contains($0.elementID) },
            budget: response.budget.filter { !excludedElementIDs.contains($0.elementID) }
        )
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
            let filtered = filteredTransferRecommendations(recommendations)
            transferRecommendations = filtered
            if comparisonElementIDs.isEmpty {
                comparisonElementIDs = Array(filtered.similarValue.prefix(3).map(\.elementID))
            }
            let comparisonIDs = comparisonElementIDs
            isLoadingTransferRecommendations = false
            Task {
                for elementID in comparisonIDs {
                    await loadRecommendationDetailsIfNeeded(for: elementID)
                }
            }
            return
        } catch {
            transferRecommendations = nil
            transferRecommendationsErrorMessage = userFriendlyTransferRecommendationError(error)
        }

        isLoadingTransferRecommendations = false
    }

    private func loadTransferRecommendationsIfNeeded() {
        guard transferRecommendations == nil, !isLoadingTransferRecommendations else { return }

        Task {
            await loadTransferRecommendations(elementID: selection.player.elementID)
        }
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
        comparisonElementIDs = []
        recommendationRoute = nil

        do {
            let loaded = try await fantasyViewModel.loadPlayerDetails(
                elementID: selection.player.elementID,
                gameweekID: selection.gameweekID,
                apiBaseURL: apiBaseURL
            )
            details = loaded
            isLoading = false
            return
        } catch {
            details = nil
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
