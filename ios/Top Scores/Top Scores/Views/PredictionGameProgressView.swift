import SwiftUI

struct PredictionGameProgressView: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize = 48
    @State private var tab: ProgressTab = .record
    @State private var selectedSeasonID = ""
    @State private var loadedSeasonID: String?
    @State private var category: PredictionGameLeaderboardCategory = .weekly
    @State private var leaderboardSeasonID = ""
    @State private var recordError: String?
    @State private var leaderboardError: String?

    private enum ProgressTab: String, CaseIterable, Identifiable {
        case record = "Record", achievements = "Achievements", leaderboards = "Leaderboards"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PredictionGameCompetitionPicker {
                    selectedSeasonID = ""
                    leaderboardSeasonID = ""
                    loadedSeasonID = nil
                    recordError = nil
                    leaderboardError = nil
                }
                tabPicker
                switch tab {
                case .record: record
                case .achievements: achievements
                case .leaderboards: leaderboards
                }
                BeatAIGameCenterStatus()
            }
            .padding(20)
            .frame(maxWidth: 660)
            .frame(maxWidth: .infinity)
        }
        .background { BeatAIBackground() }
        .environment(\.colorScheme, .dark)
        .navigationTitle("Beat the AI")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if tab == .leaderboards { await refreshLeaderboard() }
            else { await refreshRecord() }
        }
        .task(id: "\(game.selectedCompetitionID)|\(selectedSeasonID)|\(game.playerScopeID)") { await refreshRecord() }
        .task(id: "\(game.selectedCompetitionID)|\(tab.rawValue)|\(category.rawValue)|\(leaderboardSeasonID)") {
            if tab == .leaderboards { await refreshLeaderboard() }
        }
        .accessibilityIdentifier("prediction-game-progress-screen")
    }

    @ViewBuilder
    private var tabPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("Progress section", selection: $tab) {
                ForEach(ProgressTab.allCases) {
                    Text($0.rawValue).tag($0)
                        .accessibilityIdentifier("beat-ai-tab-\($0.rawValue.lowercased())")
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            Picker("Progress section", selection: $tab) {
                ForEach(ProgressTab.allCases) {
                    Text($0.rawValue).tag($0)
                        .accessibilityIdentifier("beat-ai-tab-\($0.rawValue.lowercased())")
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var record: some View {
        HStack {
            Text("You vs AI").font(.title3.weight(.bold))
            Spacer(minLength: 8)
            Picker("Record season", selection: $selectedSeasonID) {
                Text("All time").tag("")
                ForEach(game.seasons) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.menu)
            .tint(BeatAIStyle.gold)
        }
        if game.isLoading || (game.enabled && loadedSeasonID != selectedSeasonID && recordError == nil) {
            loading("Updating your record…")
        } else if let recordError {
            errorCard(recordError) { Task { await refreshRecord() } }
        } else {
            scoreCard
            summaryStats
            recentForm
            achievementOverview
            matchHistory
        }
    }

    private var scoreCard: some View {
        VStack(spacing: 12) {
                Text(recordScope.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(BeatAIStyle.muted)
                HStack(alignment: .center, spacing: 12) {
                    opponent("YOU", points: game.summary.youPoints, color: BeatAIStyle.blue)
                    Text("VS")
                        .font(.caption.weight(.black))
                        .foregroundStyle(BeatAIStyle.muted)
                        .padding(10)
                        .background(.white.opacity(0.05), in: Circle())
                        .accessibilityHidden(true)
                    opponent("AI", points: game.summary.aiPoints, color: BeatAIStyle.purple)
                }
                Text(recordHeadline)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(game.summary.played > 0 && game.summary.youPoints > game.summary.aiPoints ? BeatAIStyle.gold : .white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(game.summary.played > 0
                    ? "W \(game.summary.wins) · D \(game.summary.draws) · L \(game.summary.losses)   \(game.summary.winPercentage.formatted(.number.precision(.fractionLength(0))))% win rate"
                    : "Your record starts when your first match finishes.")
                    .font(.caption)
                    .foregroundStyle(BeatAIStyle.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(game.summary.played > 0
                        ? "\(game.summary.wins) wins, \(game.summary.draws) draws, \(game.summary.losses) losses. \(game.summary.winPercentage.formatted(.number.precision(.fractionLength(0)))) percent win rate."
                        : "Your record starts when your first match finishes.")
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { geometry in
                Image("BeatAIHero")
                    .resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay(BeatAIStyle.background.opacity(0.83))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).strokeBorder(BeatAIStyle.gold.opacity(0.26), lineWidth: 1)
        }
    }

    private func opponent(_ name: String, points: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(name).font(.caption.weight(.bold)).foregroundStyle(color)
            Text(points.formatted())
                .font(.system(size: scoreSize, weight: .black, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(points) points")
    }

    private var summaryStats: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: dynamicTypeSize.isAccessibilitySize ? 1 : 3), spacing: 10) {
            metric("Exact scores", value: game.summary.exactScores.formatted(), comparison: "AI: \(game.summary.aiExactScores)", color: BeatAIStyle.gold)
            metric("Correct results", value: game.summary.correctResults.formatted(), comparison: game.summary.played == 0 ? "No scored matches" : "\(game.summary.resultAccuracy.formatted(.number.precision(.fractionLength(0))))% accuracy", color: BeatAIStyle.green)
            metric("Scored matches", value: game.summary.played.formatted(), comparison: "You vs AI", color: BeatAIStyle.blue)
        }
    }

    private func metric(_ title: String, value: String, comparison: String, color: Color) -> some View {
        BeatAIPanel(accent: color, padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(value).font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
                Text(title).font(.caption2.weight(.bold))
                Text(comparison).font(.caption2).foregroundStyle(BeatAIStyle.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var recentForm: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Recent form").font(.headline)
                    Spacer(minLength: 8)
                    Text("Gameweeks").font(.caption).foregroundStyle(BeatAIStyle.muted)
                }
                if recentWeeks.isEmpty {
                    Text("Your recent gameweeks will appear here once you make your picks.")
                        .font(.subheadline)
                        .foregroundStyle(BeatAIStyle.muted)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 2 : 5), spacing: 10) {
                        ForEach(recentWeeks) { week in
                            let outcome = weekOutcome(week)
                            VStack(spacing: 6) {
                                Text(week.label.replacingOccurrences(of: "Gameweek ", with: "GW "))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(BeatAIStyle.muted)
                                Text(outcome.letter)
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(outcome.color)
                                    .frame(minWidth: 36, minHeight: 36)
                                    .background(outcome.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                                Text("\(week.youPoints)–\(week.aiPoints)")
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                            }
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(week.label). \(outcome.label). You \(week.youPoints) points, AI \(week.aiPoints) points.")
                        }
                    }
                    Text("Oldest to newest · You–AI points · – means in progress")
                        .font(.caption2)
                        .foregroundStyle(BeatAIStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
        }
    }

    private var achievementOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Achievements").font(.title3.weight(.bold))
                Spacer(minLength: 8)
                Button("View all") { tab = .achievements }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            if game.achievements.isEmpty {
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? metricColumns : Array(repeating: GridItem(.flexible(), alignment: .top), count: 4), spacing: 16) {
                    ForEach(Array(BeatAIAchievementDefinition.catalog.prefix(4))) { definition in
                        Button { tab = .achievements } label: {
                            VStack(spacing: 8) {
                                Image(systemName: achievementSymbol(definition.id))
                                    .font(.title3)
                                    .foregroundStyle(BeatAIStyle.muted)
                                    .frame(width: 44, height: 44)
                                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityHidden(true)
                                Text(definition.title)
                                    .font(.caption2.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(definition.title). Progress unavailable.")
                    }
                }
            } else {
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? metricColumns : Array(repeating: GridItem(.flexible(), alignment: .top), count: 4), spacing: 16) {
                    ForEach(Array(game.achievements.prefix(4))) { achievement in
                        Button { tab = .achievements } label: {
                            VStack(spacing: 8) {
                                achievementBadge(achievement, size: 44)
                                Text(achievement.title)
                                    .font(.caption2.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(achievement.title), \(achievement.unlocked ? "unlocked" : "\(Int(achievement.progress)) percent complete")")
                    }
                }
            }
        }
    }

    private var achievements: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your trophy cabinet")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text(game.achievements.isEmpty ? "Milestones for your football instincts." : "\(game.achievements.filter(\.unlocked).count) of \(game.achievements.count) unlocked · All time")
                .font(.subheadline)
                .foregroundStyle(BeatAIStyle.muted)
            if game.achievements.isEmpty {
                if game.isLoading { ProgressView("Updating achievement progress…").font(.caption) }
                Text("Progress is unavailable until your record loads.")
                    .font(.caption)
                    .foregroundStyle(BeatAIStyle.muted)
                achievementCatalog
                if !game.isLoading { emptyAchievements }
            } else {
                LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 14) {
                    ForEach(game.achievements) { achievement in
                        BeatAIPanel(accent: achievement.unlocked ? BeatAIStyle.gold : BeatAIStyle.blue) {
                            VStack(alignment: .leading, spacing: 12) {
                                achievementBadge(achievement, size: 48)
                                Text(achievement.title).font(.headline)
                                Text(achievement.description)
                                    .font(.caption)
                                    .foregroundStyle(BeatAIStyle.muted)
                                ProgressView(value: min(max(achievement.progress, 0), 100), total: 100)
                                    .tint(achievement.unlocked ? BeatAIStyle.gold : BeatAIStyle.blue)
                                Text(achievement.unlocked ? "Unlocked" : "\(Int(achievement.progress))% complete")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(achievement.unlocked ? BeatAIStyle.gold : BeatAIStyle.muted)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(achievement.title). \(achievement.description)")
                        .accessibilityValue(achievement.unlocked ? "Unlocked" : "\(Int(achievement.progress)) percent complete")
                    }
                }
            }
            Button("Achievements in Game Center", systemImage: "rosette") {
                Task { await game.openGameCenterAchievements(apiBaseURL: preferences.apiBaseURL) }
            }
            .frame(minHeight: 44)
            .disabled(game.isConnectingGameCenter || !game.enabled)
        }
    }

    private var emptyAchievements: some View {
        BeatAIPanel(accent: BeatAIStyle.gold) {
            VStack(alignment: .leading, spacing: 10) {
                Label("The cabinet is waiting", systemImage: "trophy")
                    .font(.headline)
                    .foregroundStyle(BeatAIStyle.gold)
                Text("Your achievement progress appears when your game record loads. Every perfect pick and victory over the AI brings you closer.")
                    .font(.subheadline)
                    .foregroundStyle(BeatAIStyle.muted)
                if game.enabled {
                    Button("Update progress") { Task { await refreshRecord() } }
                        .frame(minHeight: 44)
                        .disabled(game.isLoading)
                }
            }
        }
    }

    private var achievementCatalog: some View {
        LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 14) {
            ForEach(BeatAIAchievementDefinition.catalog) { definition in
                BeatAIPanel(accent: BeatAIStyle.gold) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: achievementSymbol(definition.id))
                            .font(.title2)
                            .foregroundStyle(BeatAIStyle.muted)
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityHidden(true)
                        Text(definition.title).font(.headline)
                        Text(definition.description).font(.caption).foregroundStyle(BeatAIStyle.muted)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue("Progress unavailable")
            }
        }
    }

    private func achievementBadge(_ achievement: PredictionGameAchievement, size: CGFloat) -> some View {
        Image(systemName: achievementSymbol(achievement.id))
            .font(.system(size: size * 0.44, weight: .bold))
            .foregroundStyle(achievement.unlocked ? BeatAIStyle.gold : BeatAIStyle.muted)
            .frame(width: size, height: size)
            .background(achievement.unlocked ? BeatAIStyle.gold.opacity(0.14) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay(alignment: .bottomTrailing) {
                if achievement.unlocked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(BeatAIStyle.green)
                        .background(BeatAIStyle.background, in: Circle())
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var leaderboards: some View {
        BeatAIPanel {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Leaderboard category", selection: $category) {
                    ForEach(PredictionGameLeaderboardCategory.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(BeatAIStyle.gold)
                if category != .weekly {
                    Picker("Leaderboard season", selection: $leaderboardSeasonID) {
                        Text("Current season").tag("")
                        ForEach(game.seasons) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                }
                Text(category == .weekly
                    ? "The trophy-marked challenge matches in \(game.selectedCompetition.name) are the same for everyone. Equal points share a rank."
                    : category == .perfect
                        ? "Exact scores on shared challenge matches in this season."
                        : "Your points across shared challenges in this season.")
                    .font(.caption)
                    .foregroundStyle(BeatAIStyle.muted)
                Text("Picks in other competitions never change this table.")
                    .font(.caption)
                    .foregroundStyle(BeatAIStyle.muted)
            }
        }
        if game.isLoadingLeaderboard {
            loading("Loading the table…")
        } else if let leaderboardError {
            errorCard(leaderboardError) { Task { await refreshLeaderboard() } }
        } else if game.leaderboards.isEmpty {
            BeatAIPanel(accent: BeatAIStyle.gold) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("The table is waiting", systemImage: "trophy.fill")
                        .font(.headline).foregroundStyle(BeatAIStyle.gold)
                    Text("Rankings appear as challenge matches are scored. Make your picks and give the table something to talk about.")
                        .font(.subheadline).foregroundStyle(BeatAIStyle.muted)
                }
            }
        } else {
            BeatAIPanel(accent: BeatAIStyle.gold) {
                VStack(spacing: 16) {
                    HStack {
                        Text("GLOBAL RANKING")
                        Spacer()
                        Text(category == .perfect ? "EXACT" : "POINTS")
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(BeatAIStyle.muted)
                    ForEach(game.leaderboards) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.rank.formatted())
                                .font(.headline)
                                .frame(minWidth: 24, alignment: .leading)
                                .foregroundStyle(row.rank <= 3 ? BeatAIStyle.gold : BeatAIStyle.muted)
                            Text(row.isYou ? "\(row.displayName) (You)" : row.displayName)
                                .font(.subheadline.weight(row.isYou ? .bold : .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(row.points.formatted()).font(.headline)
                        }
                        .foregroundStyle(row.isYou ? BeatAIStyle.blue : .white)
                        .monospacedDigit()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Rank \(row.rank). \(row.isYou ? "You" : row.displayName). \(row.points) \(category == .perfect ? "exact scores" : "points").")
                    }
                }
            }
        }
        Button("Friends in Game Center", systemImage: "person.2.fill") {
            Task { await game.openGameCenterLeaderboards(apiBaseURL: preferences.apiBaseURL, category: category,
                                                                      seasonId: leaderboardSeasonID.isEmpty ? nil : leaderboardSeasonID) }
        }
        .buttonStyle(BeatAIPrimaryButtonStyle())
        .disabled(game.isConnectingGameCenter || !game.enabled)
    }

    @ViewBuilder
    private var matchHistory: some View {
        if !game.history.isEmpty {
            DisclosureGroup("Prediction history") {
                VStack(spacing: 16) {
                    ForEach(game.history) { fixture in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(fixture.homeTeam) v \(fixture.awayTeam)").font(.subheadline.weight(.bold))
                            Text(fixture.kickoffAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(BeatAIStyle.muted)
                            if let prediction = fixture.prediction {
                                Text("You: \(prediction.displayText) · AI: \(fixture.ai?.displayText ?? "—")")
                                    .font(.caption.weight(.semibold)).monospacedDigit()
                                if let winner = prediction.penaltyWinner {
                                    Text("Your shoot-out winner: \(winner == "home" ? fixture.homeTeam : fixture.awayTeam)")
                                        .font(.caption).foregroundStyle(BeatAIStyle.muted)
                                }
                                if let winner = fixture.ai?.penaltyWinner {
                                    Text("AI shoot-out winner: \(winner == "home" ? fixture.homeTeam : fixture.awayTeam)")
                                        .font(.caption).foregroundStyle(BeatAIStyle.purple)
                                }
                            }
                            if let result = fixture.result {
                                Text("Full time: \(result.displayText)").font(.caption).foregroundStyle(BeatAIStyle.muted)
                                if let winner = result.penaltyWinner {
                                    Text("\(winner == "home" ? fixture.homeTeam : fixture.awayTeam) won on penalties")
                                        .font(.caption).foregroundStyle(BeatAIStyle.muted)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                    if game.hasMoreHistory {
                        Button {
                            Task { await game.loadMoreHistory(apiBaseURL: preferences.apiBaseURL) }
                        } label: {
                            HStack {
                                if game.isLoadingHistory { ProgressView() }
                                Text("Earlier predictions")
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(game.isLoadingHistory)
                    }
                }
                .padding(.top, 16)
            }
            .font(.headline)
        }
    }

    private func loading(_ message: String) -> some View {
        ProgressView(message)
            .font(.subheadline)
            .frame(maxWidth: .infinity, minHeight: 100)
    }

    private func errorCard(_ message: String, retry: @escaping () -> Void) -> some View {
        BeatAIPanel(accent: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Couldn’t update your progress", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message).font(.subheadline).foregroundStyle(BeatAIStyle.muted)
                Button("Try again", action: retry).frame(minHeight: 44)
            }
        }
    }

    private var metricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    private var recordScope: String {
        selectedSeasonID.isEmpty ? "All time" : game.seasons.first(where: { $0.id == selectedSeasonID })?.label ?? "Selected season"
    }

    private var recordHeadline: String {
        guard game.summary.played > 0 else { return "Who’ll take the first point?" }
        if game.summary.youPoints > game.summary.aiPoints { return "You are currently smarter than AI" }
        if game.summary.youPoints < game.summary.aiPoints { return "AI is currently smarter than you" }
        return "You and AI are currently level"
    }

    private var recentWeeks: [PredictionGameRecentGameweek] {
        Array(game.recentGameweeks.sorted { $0.startsAt > $1.startsAt }.prefix(5).reversed())
    }

    private func weekOutcome(_ week: PredictionGameRecentGameweek) -> (letter: String, label: String, color: Color) {
        guard week.completed else { return ("–", "In progress", BeatAIStyle.muted) }
        let you = week.youPoints
        let ai = week.aiPoints
        if you > ai { return ("W", "You win", BeatAIStyle.green) }
        if you < ai { return ("L", "AI wins", BeatAIStyle.purple) }
        return ("D", "Draw", BeatAIStyle.gold)
    }

    private func achievementSymbol(_ id: String) -> String {
        switch id {
        case "firstWhistle": "flag.checkered"
        case "bullseye": "target"
        case "sharpShooter": "scope"
        case "readingTheGame": "book.fill"
        case "humanOneAiZero": "person.fill.checkmark"
        case "tenStepsAhead": "bolt.fill"
        case "cleanSweep": "sparkles"
        case "seasonedPro": "crown.fill"
        default: "trophy.fill"
        }
    }

    private func refreshRecord() async {
        guard game.enabled else { return }
        let season = selectedSeasonID
        let competitionID = game.selectedCompetitionID
        recordError = nil
        await game.loadDashboard(apiBaseURL: preferences.apiBaseURL, seasonId: season.isEmpty ? nil : season)
        guard !Task.isCancelled, season == selectedSeasonID, competitionID == game.selectedCompetitionID else { return }
        recordError = game.errorMessage
        if recordError == nil { loadedSeasonID = season }
    }

    private func refreshLeaderboard() async {
        guard game.enabled else { return }
        leaderboardError = nil
        let competitionID = game.selectedCompetitionID
        let requestedCategory = category
        let requestedSeason = leaderboardSeasonID
        await game.loadLeaderboard(category: category, apiBaseURL: preferences.apiBaseURL,
                                   seasonId: leaderboardSeasonID.isEmpty ? nil : leaderboardSeasonID)
        guard !Task.isCancelled, competitionID == game.selectedCompetitionID,
              category == requestedCategory, leaderboardSeasonID == requestedSeason else { return }
        leaderboardError = game.errorMessage
    }
}

private struct BeatAIAchievementDefinition: Identifiable {
    let id: String
    let title: String
    let description: String

    static let catalog: [Self] = [
        .init(id: "firstWhistle", title: "First Whistle", description: "Complete your first scored prediction."),
        .init(id: "bullseye", title: "Bullseye", description: "Make your first perfect prediction."),
        .init(id: "sharpShooter", title: "Sharp Shooter", description: "Make 10 perfect predictions."),
        .init(id: "readingTheGame", title: "Reading the Game", description: "Predict 25 results correctly."),
        .init(id: "humanOneAiZero", title: "Human 1, AI 0", description: "Beat the AI on one match."),
        .init(id: "tenStepsAhead", title: "Ten Steps Ahead", description: "Build a 10-point advantage over the AI."),
        .init(id: "cleanSweep", title: "Clean Sweep", description: "Predict every result in a completed weekly challenge."),
        .init(id: "seasonedPro", title: "Seasoned Pro", description: "Complete challenge predictions in two seasons.")
    ]
}
