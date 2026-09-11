import SwiftUI

struct PredictionGameWeekView: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: PredictionGameWeekSession
    @State private var selectedDay: Date?
    @State private var saveTask: Task<Void, Never>?
    @State private var showsLeaveConfirmation = false
    private let onPredictionsVisibilityChanged: () -> Void

    init(
        predictionSet: PredictionGamePredictionSet? = nil,
        onPredictionsVisibilityChanged: @escaping () -> Void = {}
    ) {
        _session = StateObject(wrappedValue: PredictionGameWeekSession(predictionSet: predictionSet))
        self.onPredictionsVisibilityChanged = onPredictionsVisibilityChanged
    }

    private var isCurrentPlayer: Bool {
        session.isCurrentPlayer(game: game, apiBaseURL: preferences.apiBaseURL)
    }

    private var days: [Date] {
        Set(session.fixtures.map { Calendar.current.startOfDay(for: $0.kickoffAt) }).sorted()
    }

    private var visibleFixtures: [PredictionGameFixture] {
        session.fixtures.filter { fixture in
            selectedDay.map { Calendar.current.isDate(fixture.kickoffAt, inSameDayAs: $0) } ?? true
        }
    }

    var body: some View {
        ZStack {
            BeatAIBackground()
            if session.isLoading && !isCurrentPlayer {
                ProgressView("Loading your gameweek…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isCurrentPlayer {
                board
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                    Text(session.errorMessage ?? "Your gameweek is not available yet.")
                        .multilineTextAlignment(.center)
                    Button("Try again") { Task { await session.load(game: game, apiBaseURL: preferences.apiBaseURL) } }
                        .buttonStyle(BeatAIPrimaryButtonStyle())
                }
                .padding(24)
            }
        }
        .fontDesign(.rounded)
        .foregroundStyle(.white)
        .tint(BeatAIStyle.blue)
        .navigationTitle("Beat the AI")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if session.changedCount > 0 { showsLeaveConfirmation = true } else { dismiss() }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .frame(minHeight: 44)
                }
                .disabled(session.isSaving)
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text("Beat the AI").font(.headline)
                    if let label = session.predictionSet?.gameweekLabel {
                        Text(label).font(.caption).foregroundStyle(BeatAIStyle.muted)
                    }
                }
            }
        }
        .toolbarBackground(BeatAIStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled(session.isSaving || session.changedCount > 0)
        .confirmationDialog("Save your predictions before leaving?", isPresented: $showsLeaveConfirmation, titleVisibility: .visible) {
            Button("Save and go back") { save(leaveAfterSaving: true) }
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your unsaved picks will be lost if you discard them.")
        }
        .task(id: "\(preferences.apiBaseURL)|\(game.selectedCompetitionID)") {
            saveTask?.cancel()
            session.cancel()
            game.setPredictionEditingActive(true)
            await session.load(game: game, apiBaseURL: preferences.apiBaseURL)
        }
        .onChange(of: game.playerScopeID) { _, _ in
            guard !session.isLoading, !isCurrentPlayer else { return }
            saveTask?.cancel()
            session.cancel()
            Task { await session.load(game: game, apiBaseURL: preferences.apiBaseURL) }
        }
        .onChange(of: days) { _, availableDays in
            if let selectedDay, !availableDays.contains(selectedDay) { self.selectedDay = nil }
        }
        .onDisappear {
            saveTask?.cancel()
            session.cancel()
            game.setPredictionEditingActive(false)
        }
    }

    private var board: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(session.predictionSet?.resolvedCompetitionName ?? game.selectedCompetition.name, systemImage: "soccerball")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(BeatAIStyle.gold)
                    .fixedSize(horizontal: false, vertical: true)
                dateTabs
                BeatAIPanel {
                    Toggle(isOn: Binding(
                        get: { preferences.showPredictedScores },
                        set: {
                            preferences.showPredictedScores = $0
                            onPredictionsVisibilityChanged()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Show AI predictions").font(.subheadline.weight(.semibold))
                            Text("Compare your picks with the AI")
                                .font(.caption).foregroundStyle(BeatAIStyle.muted)
                        }
                    }
                    .accessibilityIdentifier("week-show-ai")
                }
                if let message = session.errorMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.fixtures.isEmpty {
                    BeatAIPanel {
                        Text("There are no matches with AI predictions in an open gameweek for this competition right now.")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Label("Swipe the number dials up or down to make your picks", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                        .foregroundStyle(BeatAIStyle.muted)
                    Text("Trophy-marked matches count toward friends’ leaderboards. All your picks count toward your personal record.")
                        .font(.caption)
                        .foregroundStyle(BeatAIStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LazyVStack(spacing: 14) {
                            ForEach(visibleFixtures) { item in
                                let fixture = game.fixture(for: item.id) ?? item
                                PredictionGameWeekMatchCard(
                                    fixture: fixture,
                                    draft: session.draft(for: fixture.id),
                                    showsAI: preferences.showPredictedScores,
                                    editable: game.canEdit(fixture: fixture, at: context.date) && !session.isSaving && !session.isLoading,
                                    serverDate: game.serverNow(relativeTo: context.date),
                                    error: session.rowErrors[fixture.id],
                                    isSaving: session.savingFixtureID == fixture.id,
                                    setHome: { session.setHomeScore($0, for: fixture.id) },
                                    setAway: { session.setAwayScore($0, for: fixture.id) },
                                    setPenaltyWinner: { session.setPenaltyWinner($0, for: fixture.id) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .refreshable { await session.load(game: game, apiBaseURL: preferences.apiBaseURL) }
        .safeAreaInset(edge: .bottom) {
            if !session.fixtures.isEmpty { saveBar }
        }
    }

    private var dateTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                dateTab("All (\(session.fixtures.count))", day: nil)
                ForEach(days, id: \.self) { day in
                    dateTab(day.formatted(.dateTime.weekday(.abbreviated).day()), day: day)
                }
            }
        }
    }

    private func dateTab(_ title: String, day: Date?) -> some View {
        Button { selectedDay = day } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(selectedDay == day ? BeatAIStyle.blue : .white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedDay == day ? .isSelected : [])
    }

    private var saveBar: some View {
        VStack(spacing: 10) {
            if let message = session.confirmationMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BeatAIStyle.green)
                    .accessibilityIdentifier("week-save-confirmation")
            }
            Button { save() } label: {
                HStack(spacing: 10) {
                    if session.isSaving { ProgressView().tint(.white) }
                    Text(session.isSaving ? "Saving predictions…" : "Save predictions")
                    if session.changedCount > 0, !session.isSaving {
                        Text("\(session.changedCount)")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
            }
            .buttonStyle(BeatAIPrimaryButtonStyle())
            .disabled(session.isSaving || session.isLoading || session.changedCount == 0)
            .accessibilityIdentifier("week-save-predictions")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(BeatAIStyle.background)
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

struct PredictionGameWeekMatchCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var dialHeight = 68
    let fixture: PredictionGameFixture
    let draft: PredictionGameWeekDraft
    let showsAI: Bool
    let editable: Bool
    let serverDate: Date
    let error: String?
    let isSaving: Bool
    let setHome: (Int?) -> Void
    let setAway: (Int?) -> Void
    let setPenaltyWinner: (String?) -> Void
    var leagueName: String? = nil
    var sharedAI: PredictionGameAI? = nil
    private var displayedAI: PredictionGameAI? { leagueName == nil ? fixture.ai : sharedAI }

    var body: some View {
        BeatAIPanel(padding: dynamicTypeSize >= .xxLarge ? 18 : 12) {
            VStack(alignment: .leading, spacing: 12) {
                if dynamicTypeSize >= .xxLarge {
                    Text(fixture.kickoffAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(BeatAIStyle.muted)
                    accessibleTeam(fixture.homeTeam, aiScore: displayedAI?.homeScore, score: draft.homeScore, setScore: setHome)
                    accessibleTeam(fixture.awayTeam, aiScore: displayedAI?.awayScore, score: draft.awayScore, setScore: setAway)
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        HStack(alignment: .center, spacing: 4) {
                            compactTeam(fixture.homeTeam)
                            VStack(spacing: 3) {
                                Text(fixture.kickoffAt.formatted(.dateTime.weekday(.abbreviated).day()))
                                    .foregroundStyle(BeatAIStyle.muted)
                                Text(fixture.kickoffAt.formatted(.dateTime.hour().minute()))
                                    .fontWeight(.semibold)
                            }
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .frame(minWidth: 32)
                            compactTeam(fixture.awayTeam)
                        }
                        .frame(maxWidth: .infinity)
                        if showsAI {
                            VStack(spacing: 4) {
                                Text("AI").font(.caption2.weight(.bold))
                                HStack(spacing: 4) {
                                    aiCell(displayedAI?.homeScore)
                                    aiCell(displayedAI?.awayScore)
                                }
                                .frame(height: min(dialHeight, 102))
                            }
                            .foregroundStyle(BeatAIStyle.muted)
                        }
                        VStack(spacing: 4) {
                            Text("YOU").font(.caption2.weight(.bold)).foregroundStyle(BeatAIStyle.blue)
                            HStack(spacing: 4) {
                                scoreDial(team: fixture.homeTeam, score: draft.homeScore, setScore: setHome)
                                scoreDial(team: fixture.awayTeam, score: draft.awayScore, setScore: setAway)
                            }
                        }
                    }
                }
                Label(
                    leagueName ?? (fixture.challengeId != nil ? "Friends challenge" : "Personal pick"),
                    systemImage: leagueName != nil || fixture.challengeId != nil ? "trophy.fill" : "person.fill"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(leagueName != nil || fixture.challengeId != nil ? BeatAIStyle.gold : BeatAIStyle.muted)
                .accessibilityIdentifier("week-match-scope-\(fixture.id)")
                if fixture.resolvedCompetitionID != "1", draft.isComplete, draft.homeScore == draft.awayScore || fixture.isSecondLeg == true {
                    PredictionGamePenaltyWinnerPicker(
                        homeTeam: fixture.homeTeam, awayTeam: fixture.awayTeam,
                        selection: Binding(get: { draft.penaltyWinner }, set: setPenaltyWinner),
                        aiWinner: displayedAI?.homeScore == displayedAI?.awayScore || fixture.isSecondLeg == true ? displayedAI?.penaltyWinner : nil,
                        showsAI: showsAI
                    )
                    .disabled(!editable)
                }
                HStack(alignment: .top, spacing: 8) {
                    Label(deadlineText, systemImage: fixture.canPredict && serverDate < fixture.kickoffAt ? "clock" : "lock.fill")
                    Spacer(minLength: 4)
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else if draft.isChanged {
                        Text("Unsaved").foregroundStyle(BeatAIStyle.blue)
                    } else if fixture.prediction != nil {
                        Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(BeatAIStyle.green)
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(BeatAIStyle.muted)
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let result = fixture.result {
                    Text("Full-time \(result.displayText)").font(.caption.weight(.semibold))
                    if let winner = result.penaltyWinner {
                        Text("\(winner == "home" ? fixture.homeTeam : fixture.awayTeam) won on penalties")
                            .font(.caption).foregroundStyle(BeatAIStyle.muted)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("week-match-\(fixture.id)")
    }

    private var deadlineText: String {
        if fixture.void { return "Match void" }
        if fixture.settled { return "Full-time" }
        if fixture.locked || serverDate >= fixture.kickoffAt { return "Predictions locked" }
        if fixture.ai == nil { return "AI prediction coming soon" }
        let remaining = max(0, Int(fixture.kickoffAt.timeIntervalSince(serverDate)))
        if remaining >= 86_400 { return "Locks in \(remaining / 86_400)d \((remaining % 86_400) / 3_600)h" }
        if remaining >= 3_600 { return "Locks in \(remaining / 3_600)h \((remaining % 3_600) / 60)m" }
        return "Locks in \(remaining / 60)m \(remaining % 60)s"
    }

    private func compactTeam(_ name: String) -> some View {
        VStack(spacing: 4) {
            crest(name)
            Text(shortName(name))
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)
                .frame(height: 28, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }

    private func shortName(_ name: String) -> String {
        switch name.lowercased() {
        case "manchester united": "Man Utd"
        case "manchester city": "Man City"
        case "nottingham forest": "Forest"
        case "brighton & hove albion", "brighton and hove albion": "Brighton"
        case "wolverhampton wanderers": "Wolves"
        case "tottenham hotspur", "tottenham": "Spurs"
        case "west ham united": "West Ham"
        case "newcastle united": "Newcastle"
        case "leeds united": "Leeds"
        case "crystal palace": "Palace"
        case "aston villa": "Villa"
        default: name
        }
    }

    private func crest(_ name: String) -> some View {
        Group {
            if let image = LogoResolver.shared.image(for: name) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "shield").resizable().scaledToFit()
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }

    private func aiCell(_ score: Int?) -> some View {
        Text(score.map(String.init) ?? "—")
            .font(.system(.title3, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 26, height: 44)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("AI score, \(score.map(String.init) ?? "unavailable")")
    }

    private func scoreDial(team: String, score: Int?, setScore: @escaping (Int?) -> Void) -> some View {
        PredictionScoreDial(score: Binding(get: { score }, set: setScore), team: team)
        .disabled(!editable)
    }

    private func accessibleTeam(_ name: String, aiScore: Int?, score: Int?, setScore: @escaping (Int?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                crest(name)
                Text(name).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if showsAI { Text("AI: \(aiScore.map(String.init) ?? "—")").foregroundStyle(BeatAIStyle.muted) }
                Spacer(minLength: 0)
                Text("You").foregroundStyle(BeatAIStyle.blue)
                scoreDial(team: name, score: score, setScore: setScore)
            }
        }
    }
}

/// Draws and second legs may still have a winner decided by a shoot-out.
struct PredictionGamePenaltyWinnerPicker: View {
    let homeTeam: String
    let awayTeam: String
    @Binding var selection: String?
    let aiWinner: String?
    var showsAI = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If there’s a shoot-out, who wins?")
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                option(homeTeam, value: "home")
                option(awayTeam, value: "away")
            }
            Text("Optional · Only counts if the match goes to penalties.")
                .font(.caption2)
                .foregroundStyle(BeatAIStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            if showsAI, let aiWinner {
                Text("If penalties: AI backs \(aiWinner == "home" ? homeTeam : awayTeam)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(BeatAIStyle.purple)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func option(_ name: String, value: String) -> some View {
        Button { selection = selection == value ? nil : value } label: {
            HStack(spacing: 6) {
                Text(name).fixedSize(horizontal: false, vertical: true)
                if selection == value { Image(systemName: "checkmark.circle.fill").accessibilityHidden(true) }
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 8)
            .foregroundStyle(selection == value ? BeatAIStyle.blue : BeatAIStyle.muted)
            .background(selection == value ? BeatAIStyle.blue.opacity(0.14) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) to win on penalties")
        .accessibilityAddTraits(selection == value ? .isSelected : [])
        .accessibilityHint(selection == value ? "Double tap to clear this choice" : "Only applies if the match is decided by a shoot-out")
    }
}
