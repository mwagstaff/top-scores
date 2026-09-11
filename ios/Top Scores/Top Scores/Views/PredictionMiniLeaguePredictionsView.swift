import SwiftUI

struct PredictionMiniLeaguePredictionsView: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = PredictionMiniLeaguePredictionSession()
    @State private var selectedDay: Date?
    @State private var saveTask: Task<Void, Never>?
    @State private var showsLeaveConfirmation = false
    let leagueID: String
    let leagueName: String
    let round: PredictionMiniLeagueRound
    let showsAI: Bool

    private var days: [Date] { Set(session.fixtures.map { Calendar.current.startOfDay(for: $0.kickoffAt) }).sorted() }
    private var visibleFixtures: [PredictionGameFixture] {
        session.fixtures.filter { fixture in selectedDay.map { Calendar.current.isDate(fixture.kickoffAt, inSameDayAs: $0) } ?? true }
    }
    private var isCurrent: Bool { session.isCurrent(game: game, apiBaseURL: preferences.apiBaseURL) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(leagueName, systemImage: "flag.checkered.2.crossed")
                    .font(.subheadline.weight(.bold)).foregroundStyle(BeatAIStyle.gold)
                Text(round.label).font(.system(.title, design: .rounded, weight: .heavy))
                Text(session.scoringEligible ? "One pick, every league. These scores also count in your personal game and your other eligible leagues." : "Your league scoring starts next full round. These picks count in your personal game and any other leagues where you’re eligible.")
                    .font(.footnote).foregroundStyle(BeatAIStyle.muted)
                if session.isLoading && !isCurrent {
                    MiniLeagueLoading("Laying out your matchday…")
                } else if isCurrent {
                    dateTabs
                    if showsAI {
                        Label("League AI scores were fixed when this round opened.", systemImage: "sparkles")
                            .font(.caption).foregroundStyle(BeatAIStyle.purple)
                    }
                    Label("Turn the number dials to make your picks", systemImage: "arrow.up.arrow.down")
                        .font(.caption).foregroundStyle(BeatAIStyle.muted)
                    if let error = session.errorMessage { MiniLeagueInlineError(message: error) }
                    if session.fixtures.isEmpty {
                        BeatAIPanel { Text("No matches are available for this round yet.").font(.headline) }
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LazyVStack(spacing: 14) {
                            ForEach(visibleFixtures) { item in
                                let fixture = game.fixture(for: item.id) ?? item
                                VStack(alignment: .leading, spacing: 8) {
                                    PredictionGameWeekMatchCard(
                                        fixture: fixture, draft: session.draft(for: item.id).cardDraft,
                                        showsAI: showsAI && preferences.showPredictedScores,
                                        editable: game.canEdit(fixture: fixture, at: context.date) && !session.isSaving && !session.isLoading,
                                        serverDate: game.serverNow(relativeTo: context.date),
                                        error: session.rowErrors[item.id], isSaving: session.savingFixtureID == item.id,
                                        setHome: { session.setHome($0, id: item.id) },
                                        setAway: { session.setAway($0, id: item.id) },
                                        setPenaltyWinner: { session.setPenaltyWinner($0, id: item.id) },
                                        leagueName: leagueName, sharedAI: session.sharedAI[item.id]
                                    )
                                    if let label = personalOpponentLabel(fixture) {
                                        Text(label)
                                            .font(.caption).foregroundStyle(BeatAIStyle.muted).padding(.horizontal, 12)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    MiniLeagueErrorCard(session.errorMessage ?? "This round is unavailable.") { Task { await load() } }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .miniLeagueScreen(title: "Your predictions")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back", systemImage: "chevron.left") {
                    if session.changedCount > 0 { showsLeaveConfirmation = true } else { dismiss() }
                }
                .disabled(session.isSaving)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isCurrent, !session.fixtures.isEmpty { saveBar }
        }
        .interactiveDismissDisabled(session.isSaving || session.changedCount > 0)
        .confirmationDialog("Save your predictions before leaving?", isPresented: $showsLeaveConfirmation, titleVisibility: .visible) {
            Button("Save and go back") { save(leaveAfterSaving: true) }
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: { Text("Your unsaved picks will be lost if you discard them.") }
        .task(id: "\(preferences.apiBaseURL)|\(game.privateLeagueScopeID)") {
            saveTask?.cancel()
            session.cancel()
            await load()
            if !Task.isCancelled { game.setPredictionEditingActive(true) }
        }
        .onDisappear {
            saveTask?.cancel()
            session.cancel()
            game.setPredictionEditingActive(false)
        }
        .accessibilityIdentifier("mini-league-predictions")
    }

    private var dateTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                dateTab("All (\(session.fixtures.count))", day: nil)
                ForEach(days, id: \.self) { day in dateTab(day.formatted(.dateTime.weekday(.abbreviated).day()), day: day) }
            }
        }
    }
    private func dateTab(_ title: String, day: Date?) -> some View {
        Button { selectedDay = day } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).frame(minHeight: 44)
                .background(selectedDay == day ? BeatAIStyle.blue : .white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedDay == day ? .isSelected : [])
    }
    private var saveBar: some View {
        VStack(spacing: 10) {
            if let message = session.confirmationMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(BeatAIStyle.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { save() } label: {
                HStack(spacing: 10) {
                    if session.isSaving { ProgressView().tint(.white) }
                    Text(session.isSaving ? "Saving your picks…" : "Save predictions")
                    if session.changedCount > 0 && !session.isSaving { Text("\(session.changedCount)").monospacedDigit() }
                }
            }
            .buttonStyle(BeatAIPrimaryButtonStyle())
            .disabled(session.isLoading || session.isSaving || session.changedCount == 0)
            .accessibilityIdentifier("mini-league-save-predictions")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(BeatAIStyle.background)
    }
    private func personalOpponentLabel(_ fixture: PredictionGameFixture) -> String? {
        guard showsAI, preferences.showPredictedScores, let personalAI = fixture.ai else { return nil }
        let benchmark = session.sharedAI[fixture.id]
        guard personalAI.homeScore != benchmark?.homeScore || personalAI.awayScore != benchmark?.awayScore || personalAI.penaltyWinner != benchmark?.penaltyWinner else { return nil }
        var label = "Your personal AI opponent: \(personalAI.displayText)"
        if let winner = personalAI.penaltyWinner, personalAI.homeScore == personalAI.awayScore || fixture.isSecondLeg == true {
            label += " · If penalties, \(winner == "home" ? fixture.homeTeam : fixture.awayTeam)"
        }
        return label
    }
    private func load() async {
        await session.load(leagueID: leagueID, roundID: round.id, game: game, apiBaseURL: preferences.apiBaseURL)
    }
    private func save(leaveAfterSaving: Bool = false) {
        guard saveTask == nil else { return }
        saveTask = Task {
            await session.save(game: game, apiBaseURL: preferences.apiBaseURL)
            guard !Task.isCancelled else { return }
            saveTask = nil
            if leaveAfterSaving, session.changedCount == 0 { dismiss() }
        }
    }
}
