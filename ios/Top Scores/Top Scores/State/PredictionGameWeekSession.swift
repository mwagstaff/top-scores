import Combine
import Foundation

nonisolated struct PredictionGameWeekDraft: Equatable {
    var homeScore: Int?
    var awayScore: Int?
    var penaltyWinner: String?
    fileprivate var baseline: PredictionGameScore?
    fileprivate var reviewedAIRevision: String?

    var isChanged: Bool {
        homeScore != baseline?.homeScore || awayScore != baseline?.awayScore ||
            penaltyWinner != baseline?.penaltyWinner
    }
    var isComplete: Bool { homeScore != nil && awayScore != nil }
}

extension PredictionGameWeekDraft {
    /// A shared presentation model for canonical predictions entered from a private league.
    nonisolated init(home: Int?, away: Int?, penaltyWinner: String?, savedScore: PredictionGameScore?) {
        self.init(homeScore: home, awayScore: away, penaltyWinner: penaltyWinner, baseline: savedScore, reviewedAIRevision: nil)
    }
}

@MainActor
final class PredictionGameWeekSession: ObservableObject {
    @Published private(set) var predictionSet: PredictionGamePredictionSet?
    @Published private(set) var drafts: [String: PredictionGameWeekDraft] = [:]
    @Published private(set) var rowErrors: [String: String] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var savingFixtureID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var confirmationMessage: String?

    private struct DraftScope: Hashable {
        let server: String
        let player: UUID
        let competitionID: String
    }
    private var draftStash: [DraftScope: [String: PredictionGameWeekDraft]] = [:]
    private var loadedScope: DraftScope?
    private var loadedGeneration: UUID?
    private var requestGeneration = UUID()
    private var canReuseSuppliedSet: Bool

    init(predictionSet: PredictionGamePredictionSet? = nil) {
        self.predictionSet = predictionSet
        canReuseSuppliedSet = predictionSet != nil
    }

    var fixtures: [PredictionGameFixture] {
        var seen = Set<String>()
        return (predictionSet?.fixtures ?? []).filter { seen.insert($0.id).inserted }.sorted {
            $0.kickoffAt == $1.kickoffAt ? $0.id < $1.id : $0.kickoffAt < $1.kickoffAt
        }
    }

    var changedCount: Int {
        fixtures.filter { drafts[$0.id]?.isChanged == true }.count
    }

    func draft(for fixtureID: String) -> PredictionGameWeekDraft {
        drafts[fixtureID] ?? PredictionGameWeekDraft()
    }

    func setHomeScore(_ score: Int?, for fixtureID: String) {
        guard !isSaving, !isLoading, var draft = drafts[fixtureID] else { return }
        draft.homeScore = score
        if draft.homeScore != draft.awayScore, fixtures.first(where: { $0.id == fixtureID })?.isSecondLeg != true {
            draft.penaltyWinner = nil
        }
        drafts[fixtureID] = draft
        rowErrors[fixtureID] = nil
        confirmationMessage = nil
    }

    func setAwayScore(_ score: Int?, for fixtureID: String) {
        guard !isSaving, !isLoading, var draft = drafts[fixtureID] else { return }
        draft.awayScore = score
        if draft.homeScore != draft.awayScore, fixtures.first(where: { $0.id == fixtureID })?.isSecondLeg != true {
            draft.penaltyWinner = nil
        }
        drafts[fixtureID] = draft
        rowErrors[fixtureID] = nil
        confirmationMessage = nil
    }

    func setPenaltyWinner(_ winner: String?, for fixtureID: String) {
        guard !isSaving, !isLoading, var draft = drafts[fixtureID],
              draft.isComplete,
              draft.homeScore == draft.awayScore || fixtures.first(where: { $0.id == fixtureID })?.isSecondLeg == true else { return }
        draft.penaltyWinner = winner
        drafts[fixtureID] = draft
        rowErrors[fixtureID] = nil
        confirmationMessage = nil
    }

    func isCurrentPlayer(game: PredictionGameStore, apiBaseURL: String) -> Bool {
        game.enabled && loadedGeneration == game.playerScopeID &&
            loadedScope == DraftScope(server: normalizedServer(apiBaseURL), player: game.playerDraftScopeID, competitionID: game.selectedCompetitionID)
    }

    func load(game: PredictionGameStore, apiBaseURL: String) async {
        guard !isSaving else { return }
        stashDrafts()
        let samePlayer = isCurrentPlayer(game: game, apiBaseURL: apiBaseURL)
        let anchorID = samePlayer ? fixtures.first?.id : nil
        let hadDifferentPlayer = loadedScope != nil && !samePlayer
        let generation = UUID()
        let competitionID = game.selectedCompetitionID
        requestGeneration = generation
        isLoading = true
        errorMessage = nil
        confirmationMessage = nil
        if hadDifferentPlayer {
            predictionSet = nil
            drafts = [:]
            rowErrors = [:]
            loadedScope = nil
            loadedGeneration = nil
        }
        defer { if requestGeneration == generation { isLoading = false } }

        let response: PredictionGamePredictionSet?
        if canReuseSuppliedSet, let supplied = predictionSet, !supplied.fixtures.isEmpty,
           supplied.resolvedCompetitionID == competitionID,
           (0.0..<30.0).contains(game.serverNow().timeIntervalSince(supplied.serverTime)),
           supplied.fixtures.allSatisfy({
               game.freshCachedFixture(fixtureID: $0.id, apiBaseURL: apiBaseURL) == $0
           }) {
            response = supplied
        } else {
            response = await game.loadPredictionSet(
                fixtureID: anchorID, apiBaseURL: apiBaseURL, includeLocked: true
            )
        }
        canReuseSuppliedSet = false
        guard requestGeneration == generation, !Task.isCancelled, game.enabled,
              competitionID == game.selectedCompetitionID else { return }
        guard let response else {
            errorMessage = game.errorMessage ?? "Your gameweek could not be loaded. Please try again."
            return
        }

        guard response.resolvedCompetitionID == competitionID,
              response.fixtures.allSatisfy({ $0.resolvedCompetitionID == competitionID }) else {
            errorMessage = "This gameweek belongs to a different competition. Please reload your selected competition."
            return
        }
        let scope = DraftScope(server: normalizedServer(apiBaseURL), player: game.playerDraftScopeID, competitionID: game.selectedCompetitionID)
        var restored = loadedScope == scope ? drafts : draftStash[scope] ?? [:]
        for item in response.fixtures {
            let fixture = game.fixture(for: item.id) ?? item
            let baseline = fixture.prediction.map { PredictionGameScore(penaltyWinner: $0.penaltyWinner, homeScore: $0.homeScore, awayScore: $0.awayScore) }
            if var existing = restored[fixture.id], existing.isChanged {
                existing.baseline = baseline
                restored[fixture.id] = existing
            } else {
                restored[fixture.id] = PredictionGameWeekDraft(
                    homeScore: baseline?.homeScore, awayScore: baseline?.awayScore,
                    penaltyWinner: baseline?.penaltyWinner, baseline: baseline, reviewedAIRevision: fixture.ai?.sourceRevision
                )
            }
        }
        drafts = restored
        predictionSet = response
        loadedScope = scope
        loadedGeneration = game.playerScopeID
        if hadDifferentPlayer {
            confirmationMessage = "Game selection changed. Drafts are kept separately for each player and competition."
        }
        stashDrafts()
    }

    func save(game: PredictionGameStore, apiBaseURL: String) async {
        guard !isSaving, !isLoading else { return }
        guard isCurrentPlayer(game: game, apiBaseURL: apiBaseURL) else {
            stashDrafts()
            errorMessage = "Your player or competition session changed. Reload the gameweek before saving. Your earlier drafts are kept separately."
            return
        }
        let changed = fixtures.filter { drafts[$0.id]?.isChanged == true }
        guard !changed.isEmpty else {
            confirmationMessage = "Your predictions are up to date."
            return
        }
        let generation = UUID()
        requestGeneration = generation
        isSaving = true
        errorMessage = nil
        confirmationMessage = nil
        var savedCount = 0
        defer {
            if requestGeneration == generation {
                isSaving = false
                savingFixtureID = nil
                stashDrafts()
            }
        }

        for item in changed {
            guard isCurrent(generation, game: game, apiBaseURL: apiBaseURL) else { return }
            guard var draft = drafts[item.id] else { continue }
            rowErrors[item.id] = nil
            guard let home = draft.homeScore, let away = draft.awayScore else {
                rowErrors[item.id] = "Enter both scores to save this prediction."
                continue
            }
            guard (0...20).contains(home), (0...20).contains(away) else {
                rowErrors[item.id] = "Choose a score from 0 to 20 for each team."
                continue
            }
            let fixture = game.fixture(for: item.id) ?? item
            guard game.canEdit(fixture: fixture, at: Date()) else {
                rowErrors[item.id] = fixture.void ? "This match is void. Your draft was not saved."
                    : fixture.ai == nil ? "An AI prediction is not available for this match yet."
                    : "Kick-off has passed. Your draft was not saved."
                continue
            }
            if fixture.prediction == nil, draft.reviewedAIRevision != fixture.ai?.sourceRevision {
                draft.reviewedAIRevision = fixture.ai?.sourceRevision
                drafts[item.id] = draft
                rowErrors[item.id] = aiReviewMessage(fixture)
                continue
            }
            savingFixtureID = item.id
            let penaltyWinner = home == away || fixture.isSecondLeg == true ? draft.penaltyWinner : nil
            let saved = await game.save(
                fixtureID: item.id, homeScore: home, awayScore: away,
                expectedAIRevision: draft.reviewedAIRevision, apiBaseURL: apiBaseURL,
                penaltyWinner: penaltyWinner
            )
            guard isCurrent(generation, game: game, apiBaseURL: apiBaseURL) else { return }
            let refreshed = game.fixture(for: item.id) ?? fixture
            if saved {
                draft.penaltyWinner = penaltyWinner
                draft.baseline = PredictionGameScore(penaltyWinner: penaltyWinner, homeScore: home, awayScore: away)
                draft.reviewedAIRevision = refreshed.ai?.sourceRevision
                drafts[item.id] = draft
                rowErrors[item.id] = nil
                savedCount += 1
            } else {
                if refreshed.prediction == nil, draft.reviewedAIRevision != refreshed.ai?.sourceRevision {
                    draft.reviewedAIRevision = refreshed.ai?.sourceRevision
                    drafts[item.id] = draft
                    rowErrors[item.id] = aiReviewMessage(refreshed)
                } else {
                    rowErrors[item.id] = game.errorMessage ?? "This prediction was not saved. Please try again."
                }
            }
        }
        let failedCount = changed.filter { rowErrors[$0.id] != nil }.count
        if savedCount > 0 {
            confirmationMessage = "Saved \(savedCount) \(savedCount == 1 ? "prediction" : "predictions")."
        }
        if failedCount > 0 {
            errorMessage = "\(failedCount) \(failedCount == 1 ? "prediction needs" : "predictions need") attention. Your drafts are still here."
        }
    }

    func cancel() {
        stashDrafts()
        requestGeneration = UUID()
        isLoading = false
        isSaving = false
        savingFixtureID = nil
    }

    private func isCurrent(_ generation: UUID, game: PredictionGameStore, apiBaseURL: String) -> Bool {
        guard requestGeneration == generation, !Task.isCancelled else { return false }
        guard isCurrentPlayer(game: game, apiBaseURL: apiBaseURL) else {
            stashDrafts()
            errorMessage = "Your player or competition session changed. Reload the gameweek before saving any more predictions."
            return false
        }
        return true
    }

    private func stashDrafts() {
        if let loadedScope { draftStash[loadedScope] = drafts }
    }

    private func aiReviewMessage(_ fixture: PredictionGameFixture) -> String {
        "The AI now predicts \(fixture.ai?.displayText ?? "a different score"). Review its updated score, then save again. Your draft is unchanged."
    }

    private func normalizedServer(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
