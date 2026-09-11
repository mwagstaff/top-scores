import Combine
import Foundation

nonisolated struct PredictionMiniLeagueDraft: Equatable {
    var home: Int?
    var away: Int?
    var penaltyWinner: String?
    var savedScore: PredictionGameScore?
    var reviewedAIRevision: String?
    var changed: Bool { home != savedScore?.homeScore || away != savedScore?.awayScore || penaltyWinner != savedScore?.penaltyWinner }
    var cardDraft: PredictionGameWeekDraft {
        PredictionGameWeekDraft(home: home, away: away, penaltyWinner: penaltyWinner, savedScore: savedScore)
    }
}

/// Uses canonical match saves, so the same pick applies to every league in which it is eligible.
@MainActor
final class PredictionMiniLeaguePredictionSession: ObservableObject {
    @Published private(set) var fixtures: [PredictionGameFixture] = []
    @Published private(set) var scoringEligible = true
    @Published private(set) var sharedAI: [String: PredictionGameAI] = [:]
    @Published private(set) var drafts: [String: PredictionMiniLeagueDraft] = [:]
    @Published private(set) var rowErrors: [String: String] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var savingFixtureID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var confirmationMessage: String?
    private let leagues = PredictionMiniLeagueStore()
    private weak var boundGame: PredictionGameStore?
    private var scopeSubscription: AnyCancellable?
    private var loadedScope: UUID?
    private var loadedServer: String?
    private var requestID = UUID()

    var changedCount: Int { fixtures.filter { drafts[$0.id]?.changed == true }.count }
    func isCurrent(game: PredictionGameStore, apiBaseURL: String) -> Bool {
        loadedScope == game.privateLeagueScopeID && loadedServer == apiBaseURL
    }
    func draft(for id: String) -> PredictionMiniLeagueDraft { drafts[id] ?? PredictionMiniLeagueDraft() }

    func setHome(_ value: Int?, id: String) {
        edit(id) { $0.home = value }
    }
    func setAway(_ value: Int?, id: String) {
        edit(id) { $0.away = value }
    }
    func setPenaltyWinner(_ value: String?, id: String) {
        edit(id) { $0.penaltyWinner = value }
    }
    private func edit(_ id: String, change: (inout PredictionMiniLeagueDraft) -> Void) {
        guard !isLoading, !isSaving, var draft = drafts[id] else { return }
        change(&draft)
        if draft.home != draft.away && fixtures.first(where: { $0.id == id })?.isSecondLeg != true { draft.penaltyWinner = nil }
        drafts[id] = draft
        rowErrors[id] = nil
        confirmationMessage = nil
    }

    func load(leagueID: String, roundID: String, game: PredictionGameStore, apiBaseURL: String) async {
        guard !isSaving else { return }
        bind(game)
        let id = UUID()
        requestID = id
        let samePlayer = isCurrent(game: game, apiBaseURL: apiBaseURL)
        if !samePlayer { clear() }
        isLoading = true
        errorMessage = nil
        defer { if requestID == id { isLoading = false } }
        await leagues.loadFixtures(leagueID: leagueID, roundID: roundID, game: game, apiBaseURL: apiBaseURL)
        guard !Task.isCancelled, requestID == id else { return }
        guard leagues.errorMessage == nil else {
            errorMessage = leagues.errorMessage
            // A failed membership check must not leave private fixtures or drafts visible.
            if leagues.fixtures.isEmpty { clear() }
            return
        }
        fixtures = leagues.fixtures.sorted { $0.kickoffAt == $1.kickoffAt ? $0.id < $1.id : $0.kickoffAt < $1.kickoffAt }
        sharedAI = leagues.sharedAI
        scoringEligible = leagues.scoringEligible
        for fixture in fixtures {
            let saved = fixture.prediction.map { PredictionGameScore(penaltyWinner: $0.penaltyWinner, homeScore: $0.homeScore, awayScore: $0.awayScore) }
            if samePlayer, var existing = drafts[fixture.id], existing.changed {
                existing.savedScore = saved
                drafts[fixture.id] = existing
            } else {
                drafts[fixture.id] = PredictionMiniLeagueDraft(home: saved?.homeScore, away: saved?.awayScore, penaltyWinner: saved?.penaltyWinner, savedScore: saved, reviewedAIRevision: fixture.ai?.sourceRevision)
            }
        }
        loadedScope = game.privateLeagueScopeID
        loadedServer = apiBaseURL
    }

    func save(game: PredictionGameStore, apiBaseURL: String) async {
        guard !isLoading, !isSaving, isCurrent(game: game, apiBaseURL: apiBaseURL) else { return }
        let id = UUID()
        requestID = id
        let changed = fixtures.filter { drafts[$0.id]?.changed == true }
        isSaving = true
        errorMessage = nil
        confirmationMessage = nil
        var savedCount = 0
        defer { if requestID == id { isSaving = false; savingFixtureID = nil } }
        for item in changed {
            guard !Task.isCancelled, requestID == id, isCurrent(game: game, apiBaseURL: apiBaseURL) else { return }
            guard var draft = drafts[item.id] else { continue }
            guard let home = draft.home, let away = draft.away else {
                rowErrors[item.id] = "Enter both scores to save your pick."
                continue
            }
            guard (0...20).contains(home), (0...20).contains(away) else {
                rowErrors[item.id] = "Choose a score from 0 to 20 for each team."
                continue
            }
            let fixture = game.fixture(for: item.id) ?? item
            guard game.canEdit(fixture: fixture) else {
                rowErrors[item.id] = "This match is locked. Your draft was not saved."
                continue
            }
            if fixture.prediction == nil, draft.reviewedAIRevision != fixture.ai?.sourceRevision {
                draft.reviewedAIRevision = fixture.ai?.sourceRevision
                drafts[item.id] = draft
                rowErrors[item.id] = "Your personal AI opponent now predicts \(fixture.ai?.displayText ?? "a different score"). Review it and save again. The league benchmark stays fixed."
                continue
            }
            savingFixtureID = item.id
            let winner = home == away || fixture.isSecondLeg == true ? draft.penaltyWinner : nil
            let saved = await game.save(fixtureID: item.id, homeScore: home, awayScore: away, expectedAIRevision: draft.reviewedAIRevision, apiBaseURL: apiBaseURL, penaltyWinner: winner)
            guard !Task.isCancelled, requestID == id, isCurrent(game: game, apiBaseURL: apiBaseURL) else { return }
            if saved {
                draft.savedScore = PredictionGameScore(penaltyWinner: winner, homeScore: home, awayScore: away)
                draft.penaltyWinner = winner
                drafts[item.id] = draft
                rowErrors[item.id] = nil
                savedCount += 1
            } else {
                let current = game.fixture(for: item.id) ?? fixture
                if current.prediction == nil, draft.reviewedAIRevision != current.ai?.sourceRevision {
                    draft.reviewedAIRevision = current.ai?.sourceRevision
                    drafts[item.id] = draft
                }
                rowErrors[item.id] = game.errorMessage ?? "Your pick wasn’t saved. Please try again."
            }
        }
        if savedCount > 0 { confirmationMessage = "\(savedCount) \(savedCount == 1 ? "pick" : "picks") saved across your eligible leagues." }
        if changed.contains(where: { rowErrors[$0.id] != nil }) { errorMessage = "Some picks need attention. Your unsaved changes are still here." }
    }

    func cancel() {
        requestID = UUID()
        isLoading = false
        isSaving = false
        savingFixtureID = nil
    }
    private func bind(_ game: PredictionGameStore) {
        guard boundGame !== game else { return }
        boundGame = game
        scopeSubscription = game.$privateLeagueScopeID.dropFirst().sink { [weak self] _ in
            guard let self, self.loadedScope != nil else { return }
            self.cancel()
            self.clear()
        }
    }
    private func clear() {
        fixtures = []; sharedAI = [:]; drafts = [:]; rowErrors = [:]
        loadedScope = nil; loadedServer = nil; confirmationMessage = nil; scoringEligible = true
    }
}
