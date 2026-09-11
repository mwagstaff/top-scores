import SwiftUI

struct PredictionGameView: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedSeasonID = ""
    @State private var selectedFixture: PredictionGameEditorTarget?
    @State private var showsRules = false

    var body: some View {
        FootballNavigationScreen(title: "Beat the AI", subtitle: game.selectedCompetition.name) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if game.enabled {
                        dashboard
                    } else {
                        PredictionGameWelcome {
                            await game.activate(apiBaseURL: preferences.apiBaseURL)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .refreshable {
                guard game.enabled else { return }
                await reload()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Scoring rules", systemImage: "info.circle") {
                    showsRules = true
                }
            }
        }
        .sheet(item: $selectedFixture) { target in
            PredictionGameEditor(fixtureID: target.id)
        }
        .sheet(isPresented: $showsRules) {
            PredictionGameRulesView()
        }
        .task {
            if game.enabled { await reload() }
        }
        .onChange(of: selectedSeasonID) { _, _ in
            Task { await reload() }
        }
        .onDisappear { game.gameScreenDidDisappear() }
    }

    @ViewBuilder
    private var dashboard: some View {
        if let message = game.errorMessage {
            PredictionGameErrorNotice(message: message) {
                Task { await reload() }
            }
        }

        if game.isLoading && game.challenge == nil && game.history.isEmpty {
            ProgressView("Loading your game…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }

        performanceSection
        challengeSection
        competitionSection
        historySection
        achievementsSection
        DisclosureGroup("Game settings") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hide your game picks from Scores. Your saved predictions and history are kept for when you return.")
                    .font(.footnote)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                Button("Hide game features") { game.deactivate() }
                    .frame(minHeight: 44)
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your record")
                    .font(.title3.weight(.bold))
                Spacer(minLength: 8)
                Picker("Season", selection: $selectedSeasonID) {
                    Text("All seasons").tag("")
                    ForEach(game.seasons) { season in
                        Text(season.label).tag(season.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.accentColor)
                .accessibilityHint("Filters your personal performance and prediction history")
            }

            VStack(spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    pointsColumn(title: "You", points: game.summary.youPoints, accent: Color.accentColor)
                    Text("vs")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FootballVisualStyle.mutedText)
                        .accessibilityHidden(true)
                    pointsColumn(title: "AI", points: game.summary.aiPoints, accent: FootballVisualStyle.predictionAccent)
                }
                .accessibilityElement(children: .combine)

                Text(performanceMessage)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(FootballVisualStyle.divider)

                HStack(alignment: .top, spacing: 8) {
                    recordColumn(title: "Wins", value: game.summary.wins)
                    recordColumn(title: "Draws", value: game.summary.draws)
                    recordColumn(title: "Losses", value: game.summary.losses)
                }

                if game.summary.played > 0 {
                    Text("\(game.summary.winPercentage, specifier: "%.0f")% win rate across \(game.summary.played) matches")
                        .font(.footnote)
                        .foregroundStyle(FootballVisualStyle.mutedText)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
            .footballTintedSurface(accentColor: Color.accentColor, cornerRadius: 24, showsPitchMarkings: true)

            VStack(spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    HStack {
                        Text("On the same matches")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("You").frame(width: 52, alignment: .trailing)
                        Text("AI").frame(width: 52, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FootballVisualStyle.mutedText)
                }

                comparisonRow("Perfect predictions", you: "\(game.summary.exactScores)", ai: "\(game.summary.aiExactScores)")
                comparisonRow("Correct results", you: "\(game.summary.correctResults)", ai: "\(game.summary.aiCorrectResults)")
                comparisonRow(
                    "Result accuracy",
                    you: game.summary.resultAccuracy.formatted(.number.precision(.fractionLength(0))) + "%",
                    ai: game.summary.aiResultAccuracy.formatted(.number.precision(.fractionLength(0))) + "%"
                )
                comparisonRow(
                    "Points per match",
                    you: game.summary.averagePoints.formatted(.number.precision(.fractionLength(2))),
                    ai: game.summary.aiAveragePoints.formatted(.number.precision(.fractionLength(2)))
                )
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var challengeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Weekly challenge")
                .font(.title3.weight(.bold))

            if let challenge = game.challenge {
                VStack(alignment: .leading, spacing: 8) {
                    Text(challenge.title)
                        .font(.headline)
                    Text("The same \(challenge.fixtureIds.count) matches for everyone. Each pick locks at kick-off.")
                        .font(.subheadline)
                        .foregroundStyle(FootballVisualStyle.mutedText)
                    HStack {
                        Label(challenge.completed ? "Challenge complete" : "This week", systemImage: challenge.completed ? "checkmark.circle" : "calendar")
                        Spacer(minLength: 8)
                        Text("You \(challenge.youPoints) · AI \(challenge.aiPoints)")
                            .monospacedDigit()
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 0) {
                    ForEach(Array(challenge.fixtureIds.enumerated()), id: \.element) { index, fixtureID in
                        if let fixture = game.fixture(for: fixtureID) {
                            fixtureButton(fixture)
                            if index < challenge.fixtureIds.count - 1 {
                                Divider().overlay(FootballVisualStyle.divider).padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .footballTintedSurface(accentColor: Color.accentColor, cornerRadius: 20, accentOpacity: 0.08)

                Text("Missed picks score 0 in the challenge. Predict other matches in this competition from Scores for your personal record.")
                    .font(.footnote)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                PredictionGameEmptyState(
                    title: "Next challenge coming soon",
                    message: "When the next challenge for this competition is published, its fixtures will appear here. You can still make picks from Scores.",
                    systemImage: "calendar"
                )
            }
        }
    }

    private var competitionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Take on your friends")
                .font(.title3.weight(.bold))

            NavigationLink {
                PredictionGameLeaderboardView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trophy.fill")
                        .foregroundStyle(FootballSectionAccent.venue)
                        .font(.title3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Leaderboards").font(.headline)
                        Text("Weekly points, season points and perfect picks")
                            .font(.footnote)
                            .foregroundStyle(FootballVisualStyle.mutedText)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FootballVisualStyle.mutedText)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .padding(18)
                .footballTintedSurface(accentColor: FootballSectionAccent.venue, cornerRadius: 20)
            }
            .buttonStyle(.plain)

            PredictionGameCenterPanel()
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your predictions")
                .font(.title3.weight(.bold))

            if game.history.isEmpty {
                PredictionGameEmptyState(
                    title: "Your first pick starts the story",
                    message: "Choose a weekly challenge fixture or tap any AI prediction in Scores. Saved picks and results will appear here.",
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(game.history.enumerated()), id: \.element.id) { index, fixture in
                        fixtureButton(game.fixture(for: fixture.id) ?? fixture)
                        if index < game.history.count - 1 {
                            Divider().overlay(FootballVisualStyle.divider).padding(.horizontal, 16)
                        }
                    }
                }
                .footballTintedSurface(accentColor: Color.accentColor, cornerRadius: 20, accentOpacity: 0.06)
            }

            if game.hasMoreHistory {
                Button {
                    Task {
                        await game.loadMoreHistory(apiBaseURL: preferences.apiBaseURL)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if game.isLoadingHistory { ProgressView() }
                        Text("Show earlier predictions")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(game.isLoadingHistory)
            }
        }
    }

    private var achievementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Achievements")
                .font(.title3.weight(.bold))
            Text("Little victories. Lasting bragging rights.")
                .font(.subheadline)
                .foregroundStyle(FootballVisualStyle.mutedText)

            ForEach(game.achievements) { achievement in
                PredictionGameAchievementRow(achievement: achievement)
            }

            if game.player?.gameCenterLinked == true {
                Button("View Game Center achievements", systemImage: "rosette") {
                    Task { await game.openGameCenterAchievements(apiBaseURL: preferences.apiBaseURL) }
                }
                .frame(minHeight: 44)
                .disabled(game.isConnectingGameCenter)
            }
        }
    }

    private func fixtureButton(_ fixture: PredictionGameFixture) -> some View {
        Button {
            selectedFixture = PredictionGameEditorTarget(id: fixture.id)
        } label: {
            PredictionGameFixtureRow(fixture: fixture)
        }
        .buttonStyle(.plain)
        .accessibilityHint(fixture.locked ? "Shows your prediction and match result" : "Opens your score prediction")
    }

    private func pointsColumn(title: String, points: Int, accent: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(accent)
            Text(points.formatted())
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text("points")
                .font(.caption)
                .foregroundStyle(FootballVisualStyle.mutedText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(points) points")
    }

    private func recordColumn(title: String, value: Int) -> some View {
        VStack(spacing: 4) {
            Text(value.formatted())
                .font(.title3.weight(.bold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(FootballVisualStyle.mutedText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(title.lowercased())")
    }

    private func comparisonRow(_ title: String, you: String, ai: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).fontWeight(.semibold)
                    Text("You: \(you) · AI: \(ai)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(you).frame(width: 52, alignment: .trailing)
                    Text(ai).frame(width: 52, alignment: .trailing)
                }
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). You, \(you). AI, \(ai).")
    }

    private var performanceMessage: String {
        guard game.summary.played > 0 else {
            return "Football instincts or artificial intelligence? Make your first pick."
        }
        let difference = game.summary.youPoints - game.summary.aiPoints
        if difference > 0 { return "You’re \(difference) \(difference == 1 ? "point" : "points") ahead. Advantage, human." }
        if difference < 0 { return "AI leads by \(-difference). Your next pick could turn it around." }
        return "Level on points. The next match could make the difference."
    }

    private func reload() async {
        await game.loadDashboard(
            apiBaseURL: preferences.apiBaseURL,
            seasonId: selectedSeasonID.isEmpty ? nil : selectedSeasonID
        )
    }
}

private struct PredictionGameEditorTarget: Identifiable {
    let id: String
}

struct PredictionGameEditor: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.returnFromPredictionGameToFixtures) private var returnToFixtures
    @StateObject private var session: PredictionGameEditorSession
    @State private var saveTask: Task<Void, Never>?
    @State private var isAdvancing = false

    init(fixtureID: String, predictionSet: PredictionGamePredictionSet? = nil) {
        _session = StateObject(wrappedValue: PredictionGameEditorSession(fixtureID: fixtureID, predictionSet: predictionSet))
    }

    private var fixture: PredictionGameFixture? { game.fixture(for: session.fixtureID) }
    private var isBusy: Bool { session.isWorking || game.isSaving }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !game.enabled {
                            PredictionGameWelcome {
                                await game.activate(apiBaseURL: preferences.apiBaseURL, loadDashboard: false)
                                if game.enabled { await session.load(game: game, apiBaseURL: preferences.apiBaseURL) }
                            }
                        } else if session.isLoading {
                            ProgressView("Loading match prediction…")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else if let fixture, session.isPrepared {
                            editorContent(fixture, at: context.date)
                        } else {
                            PredictionGameErrorNotice(
                                message: session.saveError ?? game.errorMessage ?? "This match does not have an AI prediction available yet."
                            ) {
                                Task { await session.load(game: game, apiBaseURL: preferences.apiBaseURL) }
                            }
                        }
                    }
                    .padding(20)
                }
                .id(session.fixtureID)
                .safeAreaInset(edge: .bottom) {
                    if game.enabled, let fixture, session.isPrepared, !session.isLoading,
                       !fixture.locked && !fixture.settled && !fixture.void && fixture.ai != nil {
                        saveButtons(fixture, at: context.date)
                    }
                }
            }
            .background(FootballVisualStyle.pageBackground.ignoresSafeArea())
            .navigationTitle("Your prediction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(game.isSaving)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled(game.isSaving)
        .task(id: preferences.apiBaseURL) {
            saveTask?.cancel()
            session.cancel()
            game.setPredictionEditingActive(true)
            await game.gameScreenDidAppear(apiBaseURL: preferences.apiBaseURL)
            if game.enabled { await session.load(game: game, apiBaseURL: preferences.apiBaseURL) }
        }
        .onDisappear {
            saveTask?.cancel()
            session.cancel()
            game.setPredictionEditingActive(false)
            game.gameScreenDidDisappear()
        }
    }

    private func editorContent(_ fixture: PredictionGameFixture, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.predictionSet?.gameweekLabel.map { "PREMIER LEAGUE · \($0.uppercased())" } ?? "PREMIER LEAGUE")
                    .font(.caption.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(Color.accentColor)
                Text(fixture.resolvedCompetitionName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FootballVisualStyle.predictionAccent)
                Text(fixture.homeTeam + " v " + fixture.awayTeam)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Label(fixture.kickoffAt.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let ai = fixture.ai {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("AI prediction", systemImage: "sparkles")
                            .font(.headline)
                        Spacer(minLength: 12)
                        Text(ai.displayText)
                            .font(.system(.title, design: .rounded, weight: .heavy))
                            .monospacedDigit()
                    }
                    .foregroundStyle(FootballVisualStyle.predictionAccent)
                    if fixture.resolvedCompetitionID != "1", ai.homeScore == ai.awayScore || fixture.isSecondLeg == true, let winner = ai.penaltyWinner {
                        Text("If penalties: AI backs \(winner == "home" ? fixture.homeTeam : fixture.awayTeam)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(FootballVisualStyle.predictionAccent)
                    }
                    Text(fixture.prediction == nil
                        ? "The AI’s prediction is fixed when you first save. You can edit your pick until kick-off."
                        : "Your AI opponent is fixed. Changing your pick will keep this same AI prediction.")
                        .font(.footnote)
                        .foregroundStyle(FootballVisualStyle.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .footballTintedSurface(accentColor: FootballVisualStyle.predictionAccent, cornerRadius: 20)
                .accessibilityElement(children: .combine)
            }

            if game.canEdit(fixture: fixture, at: date) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your call")
                        .font(.title3.weight(.bold))
                    scoreControl(team: fixture.homeTeam, score: $session.homeScore)
                    scoreControl(team: fixture.awayTeam, score: $session.awayScore)
                    if fixture.resolvedCompetitionID != "1", session.homeScore == session.awayScore || fixture.isSecondLeg == true {
                        PredictionGamePenaltyWinnerPicker(
                            homeTeam: fixture.homeTeam, awayTeam: fixture.awayTeam,
                            selection: $session.penaltyWinner, aiWinner: nil, showsAI: false
                        )
                    }
                    Label("Editable until kick-off", systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(FootballVisualStyle.mutedText)
                }
                .disabled(isBusy)
            } else {
                lockedComparison(fixture, at: date)
            }

            if let saveError = session.saveError {
                PredictionGameErrorNotice(message: saveError) {
                    Task { await session.load(game: game, apiBaseURL: preferences.apiBaseURL, preserveDraft: true) }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("3 for exact · 1 for result · 0 otherwise")
                    .font(.footnote.weight(.semibold))
                Text("Predict the score after extra time, if played, excluding penalty goals. If a shoot-out decides the match, 3 points needs both the exact score and the right winner; the right winner alone earns 1.")
                    .font(.footnote)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if fixture.challengeId != nil {
                Label("This pick also counts in the weekly challenge.", systemImage: "trophy")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scoreControl(team: String, score: Binding<Int>) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(team)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Roll up or down to choose")
                    .font(.caption)
                    .foregroundStyle(FootballVisualStyle.mutedText)
            }
            Spacer(minLength: 0)
            PredictionScoreDial(
                score: Binding(get: { score.wrappedValue }, set: { if let value = $0 { score.wrappedValue = value } }),
                team: team,
                allowsEmpty: false,
                large: true
            )
        }
        .padding(18)
        .footballTintedSurface(accentColor: Color.accentColor, cornerRadius: 20, accentOpacity: 0.10)
    }

    private func lockedComparison(_ fixture: PredictionGameFixture, at date: Date) -> some View {
        let availability = fixture.predictionAvailability(at: game.serverNow(relativeTo: date))
        return VStack(alignment: .leading, spacing: 12) {
            Label(
                availability == .void ? "Match void" : availability == .awaitingAI ? "AI prediction coming soon" : "Predictions locked",
                systemImage: availability == .void ? "minus.circle" : availability == .awaitingAI ? "clock" : "lock.fill"
            )
                .font(.headline)

            if let entry = fixture.prediction {
                LabeledContent("Your prediction", value: entry.displayText)
                    .foregroundStyle(Color.accentColor)
                if let winner = entry.penaltyWinner {
                    LabeledContent("Your shoot-out winner", value: winner == "home" ? fixture.homeTeam : fixture.awayTeam)
                }
                if let result = fixture.result {
                    LabeledContent("Full-time score", value: result.displayText)
                    if let winner = result.penaltyWinner {
                        LabeledContent("Won on penalties", value: winner == "home" ? fixture.homeTeam : fixture.awayTeam)
                    }
                }
                if let you = entry.youPoints, let ai = entry.aiPoints {
                    Divider()
                    Text(you > ai ? "Advantage, human. You win this one." : you < ai ? "This one goes to the AI." : "All square. You and the AI draw.")
                        .font(.subheadline.weight(.semibold))
                    LabeledContent("Points", value: "You \(you) · AI \(ai)")
                } else {
                    Text(fixture.void ? "This match does not count toward your record or the challenge." : "Your pick is saved. Points will appear when the final result is confirmed.")
                        .font(.subheadline)
                        .foregroundStyle(FootballVisualStyle.mutedText)
                }
            } else {
                Text(availability == .void
                    ? "This match does not count toward the challenge."
                    : availability == .awaitingAI
                        ? "The AI’s prediction is not available for this match yet. Try again later."
                        : "This match has already kicked off, so predictions are closed. You can still make your picks for upcoming matches.")
                    .font(.subheadline)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .monospacedDigit()
        .padding(18)
        .footballTintedSurface(accentColor: Color.accentColor, cornerRadius: 20, accentOpacity: 0.08)
    }

    private func saveButtons(_ fixture: PredictionGameFixture, at date: Date) -> some View {
        let next = session.nextFixture(game: game, at: date)
        return VStack(spacing: 10) {
            if next != nil {
                saveActionButton("Save and next match", advance: true)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Saves this prediction, then opens the next eligible match in this gameweek")
                saveActionButton("Save and return to Fixtures", advance: false)
                    .buttonStyle(.bordered)
            } else {
                saveActionButton("Save and return to Fixtures", advance: false)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Your pick counts once the save is confirmed.")
                .font(.caption)
                .foregroundStyle(FootballVisualStyle.mutedText)
        }
        .disabled(isBusy || !game.canEdit(fixture: fixture, at: date))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(FootballVisualStyle.pageBackground)
    }

    private func saveActionButton(_ title: String, advance: Bool) -> some View {
        Button {
            guard !isBusy else { return }
            isAdvancing = advance
            saveTask = Task {
                let shouldReturn = await session.save(game: game, apiBaseURL: preferences.apiBaseURL, advance: advance)
                guard !Task.isCancelled, shouldReturn else { return }
                dismiss()
                returnToFixtures()
            }
        } label: {
            HStack(spacing: 8) {
                if isBusy && isAdvancing == advance { ProgressView() }
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityIdentifier(advance ? "prediction-save-next" : "prediction-save-return")
    }
}

private struct PredictionGameFixtureRow: View {
    let fixture: PredictionGameFixture

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(fixture.homeTeam + " v " + fixture.awayTeam)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let result = fixture.result {
                        Text(result.displayText)
                            .font(.headline)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel("Final score, \(result.homeScore) to \(result.awayScore)")
                    }
                }

                Text(fixture.kickoffAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(FootballVisualStyle.mutedText)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { predictions }
                    VStack(alignment: .leading, spacing: 4) { predictions }
                }
                .font(.footnote.weight(.semibold))
                .monospacedDigit()

                if let entry = fixture.prediction, let you = entry.youPoints, let ai = entry.aiPoints {
                    Label(
                        "\(you > ai ? "You win" : you < ai ? "AI wins" : "Draw") · You \(you) pts · AI \(ai) pts",
                        systemImage: you > ai ? "checkmark.circle.fill" : "equal.circle"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(you > ai ? Color.accentColor : FootballVisualStyle.mutedText)
                } else if fixture.void {
                    Label("Void · doesn’t count", systemImage: "minus.circle")
                        .font(.caption)
                        .foregroundStyle(FootballVisualStyle.mutedText)
                } else if fixture.locked {
                    Label(fixture.prediction == nil ? "Locked · no prediction" : "Locked · awaiting result", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(FootballVisualStyle.mutedText)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FootballVisualStyle.mutedText)
                .padding(.top, 4)
                .accessibilityHidden(true)
        }
        .padding(16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var predictions: some View {
        Text(fixture.ai.map { "AI: \($0.displayText)" } ?? "AI prediction unavailable")
            .foregroundStyle(FootballVisualStyle.predictionAccent)
        if let entry = fixture.prediction {
            Text("You: \(entry.displayText)")
                .foregroundStyle(Color.accentColor)
        } else if !fixture.locked && !fixture.void {
            Text("Make your prediction")
                .foregroundStyle(Color.accentColor)
        }
    }
}

struct PredictionGameAchievementRow: View {
    let achievement: PredictionGameAchievement

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: achievement.unlocked ? "rosette" : "circle.dotted")
                .font(.title2)
                .foregroundStyle(achievement.unlocked ? FootballSectionAccent.venue : FootballVisualStyle.mutedText)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(achievement.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if achievement.unlocked {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                Text(achievement.description)
                    .font(.footnote)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                if !achievement.unlocked {
                    ProgressView(value: min(max(achievement.progress, 0), 100), total: 100)
                        .tint(Color.accentColor)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(achievement.title). \(achievement.description)")
        .accessibilityValue(achievement.unlocked ? "Unlocked" : "\(Int(achievement.progress)) percent complete")
    }
}

struct PredictionGameCenterPanel: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if game.player?.gameCenterLinked == true {
                Label("History linked to Game Center", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Your history is linked for recovery on another device.")
                    .font(.footnote)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                Button("Compete with friends", systemImage: "person.2.fill") {
                    Task { await game.openGameCenterLeaderboards(apiBaseURL: preferences.apiBaseURL) }
                }
                .buttonStyle(.bordered)
                .disabled(game.isConnectingGameCenter)
                Button {
                    Task { await game.connectGameCenter(apiBaseURL: preferences.apiBaseURL) }
                } label: {
                    HStack(spacing: 8) {
                        if game.isConnectingGameCenter { ProgressView() }
                        Text(game.isConnectingGameCenter ? "Connecting…" : "Refresh Game Center connection")
                    }
                    .font(.footnote)
                    .frame(minHeight: 44)
                }
                .disabled(game.isConnectingGameCenter)
            } else {
                Label("Playing as a guest", systemImage: "person.crop.circle")
                    .font(.subheadline.weight(.semibold))
                Text("Connect Game Center to compete with friends and recover your history on another device. Your Game Center nickname will appear in rankings.")
                    .font(.footnote)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await game.connectGameCenter(apiBaseURL: preferences.apiBaseURL) }
                } label: {
                    HStack(spacing: 8) {
                        if game.isConnectingGameCenter { ProgressView() }
                        Text(game.isConnectingGameCenter ? "Connecting…" : "Connect Game Center")
                    }
                    .frame(minHeight: 32)
                }
                .buttonStyle(.bordered)
                .disabled(game.isConnectingGameCenter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .alert("Restore your Game Center history?", isPresented: $game.requiresGameCenterRestore) {
            Button("Keep playing as guest", role: .cancel) {}
            Button("Restore history") {
                Task { await game.restoreGameCenter(apiBaseURL: preferences.apiBaseURL) }
            }
        } message: {
            Text("This Game Center account already has a Top Scores record. Restore it to switch to that record. Predictions from this guest account are not merged.")
        }
    }
}

private struct PredictionGameLeaderboardView: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @State private var category: PredictionGameLeaderboardCategory = .weekly

    var body: some View {
        FootballNavigationScreen(title: "Leaderboards", subtitle: "\(game.selectedCompetition.name) challenges") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Picker("Leaderboard", selection: $category) {
                        ForEach(PredictionGameLeaderboardCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.accentColor)

                    Text(category == .perfect ? "Perfect scores on shared challenge matches this season." : category == .weekly ? "Points on this week’s shared fixtures. Equal scores share a rank." : "Challenge points across this competition’s season. Equal scores share a rank.")
                        .font(.subheadline)
                        .foregroundStyle(FootballVisualStyle.mutedText)

                    if game.isLoadingLeaderboard {
                        ProgressView("Loading rankings…")
                            .frame(maxWidth: .infinity)
                    } else if let message = game.errorMessage {
                        PredictionGameErrorNotice(message: message) { Task { await load() } }
                    } else if game.leaderboards.isEmpty {
                        PredictionGameEmptyState(
                            title: "The table is waiting",
                            message: "Rankings appear as challenge matches are scored. Make your picks to get involved.",
                            systemImage: "trophy"
                        )
                    } else {
                        rankings
                    }

                    PredictionGameCenterPanel()
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
        .task(id: category) { await load() }
        .onDisappear { game.gameScreenDidDisappear() }
    }

    private var rankings: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Global ranking")
                Spacer()
                Text(category == .perfect ? "Perfect" : "Points")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(FootballVisualStyle.mutedText)
            .padding(16)

            ForEach(game.leaderboards) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.rank.formatted())
                        .font(.subheadline.weight(.bold))
                        .frame(minWidth: 28, alignment: .leading)
                    Text(row.isYou ? "\(row.displayName) (You)" : row.displayName)
                        .font(.subheadline.weight(row.isYou ? .bold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(row.points.formatted())
                        .font(.headline)
                }
                .monospacedDigit()
                .foregroundStyle(row.isYou ? Color.accentColor : .primary)
                .padding(16)
                .background(row.isYou ? Color.accentColor.opacity(0.10) : Color.clear)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rank \(row.rank). \(row.isYou ? "You" : row.displayName). \(row.points) \(category == .perfect ? "perfect predictions" : "points").")
            }
        }
        .footballTintedSurface(accentColor: FootballSectionAccent.venue, cornerRadius: 20, accentOpacity: 0.08)
    }

    private func load() async {
        await game.loadLeaderboard(category: category, apiBaseURL: preferences.apiBaseURL)
    }
}

private struct PredictionGameWelcome: View {
    @EnvironmentObject private var game: PredictionGameStore
    let activate: () async -> Void
    @State private var isActivating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Label("YOU VS AI", systemImage: "sportscourt.fill")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.accentColor)
                Text("Are you smarter\nthan AI?")
                    .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Back your football instincts. Predict football scores and take on Top Scores’ AI, one match at a time.")
                    .font(.body)
                    .foregroundStyle(FootballVisualStyle.mutedText)
            }

            VStack(alignment: .leading, spacing: 18) {
                welcomeRule("Make your call", detail: "Tap a predicted score and enter your own. Edit until kick-off.", symbol: "pencil")
                welcomeRule("Beat the prediction", detail: "3 points for an exact score, 1 for the correct result. The AI plays by the same rules.", symbol: "target")
                welcomeRule("Build your record", detail: "Track every season and take on the same weekly challenge as your friends.", symbol: "chart.xyaxis.line")
            }
            .padding(20)
            .footballTintedSurface(accentColor: Color.accentColor, cornerRadius: 24)

            VStack(spacing: 12) {
                Button {
                    isActivating = true
                    Task {
                        await activate()
                        isActivating = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isActivating { ProgressView().tint(.white) }
                        Text(isActivating ? "Starting your game…" : "Let’s play")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isActivating)

                Text("Start as a guest. Connect Game Center inside the game for friends and to recover your history on another device.")
                    .font(.footnote)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let message = game.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func welcomeRule(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PredictionGameErrorNotice: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn’t update the game", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.footnote)
                .foregroundStyle(FootballVisualStyle.mutedText)
            Button("Try again", action: retry)
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .footballTintedSurface(accentColor: .orange, cornerRadius: 18)
        .accessibilityElement(children: .contain)
    }
}

private struct PredictionGameEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(FootballVisualStyle.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .footballTintedSurface(accentColor: Color.accentColor, cornerRadius: 20, accentOpacity: 0.07)
    }
}

private struct PredictionGameRulesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Same rules. Two opponents.") {
                    LabeledContent("Exact score", value: "3 points")
                    LabeledContent("Correct win, draw or loss", value: "1 point")
                    LabeledContent("Incorrect result", value: "0 points")
                }
                Section {
                    Text("The AI’s score is fixed when your first prediction is saved. Editing your pick keeps that same AI opponent.")
                    Text("You can change your prediction until kick-off. Only picks accepted before the deadline count.")
                    Text("Earn more points than the AI to win a match. Equal points count as a draw in your head-to-head record.")
                }
                Section("Match rules") {
                    Text("Predict the final score including extra time, but excluding goals from a penalty shoot-out. If the match is decided on penalties, the winning team counts as the result. An exact score needs the correct shoot-out winner too.")
                }
                Section("The weekly challenge") {
                    Text("Everyone gets the same fixtures. Missed picks earn 0 challenge points. Other picks in this competition count toward your personal record, so you and the AI are always compared on the same matches.")
                    Text("Win percentage includes all scored head-to-head matches, including draws. Cancelled or void matches do not count. Results and points may be corrected when official scores change.")
                }
                Section("Your history") {
                    Text("Your personal record stays across seasons. Connect Game Center within the game to recover it on another device. Keep this device’s guest account until you connect.")
                }
            }
            .navigationTitle("How to play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

#if DEBUG
private struct PredictionGameFixturesPreview: View {
    private let futureMatch = PredictionGameFixture(
        id: "1001", homeTeam: "Manchester United", awayTeam: "Brighton & Hove Albion",
        seasonId: "2026-2027", seasonLabel: "2026/27", kickoffAt: .now.addingTimeInterval(86_400),
        status: "notstarted", locked: false, settled: false, void: false, challengeId: "preview-week",
        ai: PredictionGameAI(homeScore: 0, awayScore: 2, modelVersion: "preview", sourceRevision: "preview-1", frozenAt: .now),
        prediction: PredictionGameEntry(homeScore: 1, awayScore: 3, savedAt: .now, youPoints: nil, aiPoints: nil, outcome: nil),
        result: nil
    )
    private let completedMatch = PredictionGameFixture(
        id: "1002", homeTeam: "Nottingham Forest", awayTeam: "Wolverhampton Wanderers",
        seasonId: "2026-2027", seasonLabel: "2026/27", kickoffAt: .now.addingTimeInterval(-86_400),
        status: "finished", locked: true, settled: true, void: false, challengeId: "preview-week",
        ai: PredictionGameAI(homeScore: 0, awayScore: 2, modelVersion: "preview", sourceRevision: "preview-1", frozenAt: .now),
        prediction: PredictionGameEntry(homeScore: 1, awayScore: 3, savedAt: .now, youPoints: 3, aiPoints: 1, outcome: "win"),
        result: PredictionGameScore(homeScore: 1, awayScore: 3)
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your predictions")
                    .font(.title2.weight(.bold))
                VStack(spacing: 0) {
                    PredictionGameFixtureRow(fixture: futureMatch)
                    Divider()
                    PredictionGameFixtureRow(fixture: completedMatch)
                }
                .footballTintedSurface(accentColor: Color.accentColor, cornerRadius: 20)

                PredictionGameAchievementRow(achievement: PredictionGameAchievement(
                    id: "preview-perfect", title: "Sharp Shooter", description: "Make 10 perfect predictions.",
                    progress: 60, target: 10, unlocked: false
                ))
                PredictionGameAchievementRow(achievement: PredictionGameAchievement(
                    id: "preview-first", title: "Human 1, AI 0", description: "Beat the AI on one match.",
                    progress: 100, target: 1, unlocked: true
                ))
            }
            .padding(20)
        }
        .background(FootballVisualStyle.pageBackground)
        .environment(\.colorScheme, .dark)
    }
}

#Preview("Beat the AI · Guest introduction") {
    ScrollView {
        PredictionGameWelcome {}
            .padding(20)
    }
    .environmentObject(PredictionGameStore(userDefaults: UserDefaults(suiteName: "predictionGame.preview") ?? .standard))
    .background(FootballVisualStyle.pageBackground)
    .environment(\.colorScheme, .dark)
}

#Preview("Beat the AI · Predictions and achievements") {
    PredictionGameFixturesPreview()
}

#Preview("Beat the AI · Accessibility text") {
    PredictionGameFixturesPreview()
        .dynamicTypeSize(.accessibility3)
}
#endif
