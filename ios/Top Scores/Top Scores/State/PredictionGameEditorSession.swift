import Combine
import Foundation

@MainActor
final class PredictionGameEditorSession: ObservableObject {
    @Published private(set) var fixtureID: String
    @Published var homeScore = 0 {
        didSet { if homeScore != awayScore, !isSecondLeg { penaltyWinner = nil } }
    }
    @Published var awayScore = 0 {
        didSet { if homeScore != awayScore, !isSecondLeg { penaltyWinner = nil } }
    }
    @Published var penaltyWinner: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isPrepared = false
    @Published private(set) var isWorking = false
    @Published private(set) var saveError: String?
    @Published private(set) var predictionSet: PredictionGamePredictionSet?

    private var requestGeneration = UUID()
    private var visitedFixtureIDs: Set<String> = []
    private var originalGameweekID: String?
    private var originalCompetitionID: String?
    private var isSecondLeg = false
    private var loadedServer: String?
    private var mayReuseSuppliedSet: Bool

    init(fixtureID: String, predictionSet: PredictionGamePredictionSet? = nil) {
        self.fixtureID = PredictionGameFixtureID.normalized(fixtureID) ?? fixtureID
        self.predictionSet = predictionSet
        originalGameweekID = predictionSet?.gameweekId
        originalCompetitionID = predictionSet?.resolvedCompetitionID
        mayReuseSuppliedSet = predictionSet != nil
    }

    func load(game: PredictionGameStore, apiBaseURL: String, preserveDraft: Bool = false) async {
        guard !isWorking || isLoading else { return }
        let generation = UUID()
        requestGeneration = generation
        let targetID = fixtureID
        let server = normalizedServer(apiBaseURL)
        let changedServer = loadedServer.map { $0 != server } == true
        if changedServer {
            visitedFixtureIDs = []
            originalGameweekID = nil
            originalCompetitionID = nil
            predictionSet = nil
            isPrepared = false
        }
        let suppliedFixture: PredictionGameFixture?
        if mayReuseSuppliedSet, let predictionSet,
           let cached = game.freshCachedFixture(fixtureID: targetID, apiBaseURL: apiBaseURL),
           predictionSet.fixtures.first(where: { $0.id == targetID }) == cached,
           (0.0..<30.0).contains(game.serverNow().timeIntervalSince(predictionSet.serverTime)) {
            suppliedFixture = cached
        } else {
            suppliedFixture = nil
        }
        if mayReuseSuppliedSet, suppliedFixture == nil {
            predictionSet = nil
            originalGameweekID = nil
            originalCompetitionID = nil
        }
        mayReuseSuppliedSet = false
        isLoading = true
        isWorking = true
        saveError = nil
        defer {
            if requestGeneration == generation {
                isLoading = false
                isWorking = false
            }
        }

        let loaded: PredictionGameFixture?
        if let suppliedFixture {
            loaded = suppliedFixture
        } else {
            loaded = await game.loadFixture(fixtureID: targetID, apiBaseURL: apiBaseURL)
        }
        guard isCurrent(generation, game: game), targetID == fixtureID else { return }
        guard let loaded else {
            isPrepared = false
            saveError = game.errorMessage ?? "This match could not be loaded. Please try again."
            return
        }
        isSecondLeg = loaded.isSecondLeg == true
        if !preserveDraft || !isPrepared || changedServer {
            homeScore = loaded.prediction?.homeScore ?? 0
            awayScore = loaded.prediction?.awayScore ?? 0
            penaltyWinner = loaded.prediction?.penaltyWinner
        }
        originalCompetitionID = loaded.resolvedCompetitionID
        loadedServer = server
        isPrepared = true
        isLoading = false
        isWorking = false
        // A next-set launch already supplied this freshly hydrated match and context.
        guard suppliedFixture == nil else { return }

        // The current match is ready. This optional request must not delay editing or saving.
        // A save replaces the generation so this response cannot reset its draft or error.
        let refreshedSet = await game.loadPredictionSet(
            fixtureID: targetID, apiBaseURL: apiBaseURL, reportErrors: false
        )
        guard isCurrent(generation, game: game), targetID == fixtureID else { return }
        if let refreshedSet {
            if originalGameweekID == nil { originalGameweekID = refreshedSet.gameweekId }
            predictionSet = refreshedSet.gameweekId == originalGameweekID &&
                refreshedSet.resolvedCompetitionID == originalCompetitionID ? refreshedSet : nil
        } else {
            // The current fixture can still be saved when only the next-match request fails.
            predictionSet = nil
            saveError = "This match is ready to predict, but the other matches could not be loaded. You can still save this pick, or retry to load the rest."
        }
    }

    func nextFixture(game: PredictionGameStore, at date: Date) -> PredictionGameFixture? {
        guard game.enabled, let predictionSet, let originalGameweekID,
              predictionSet.gameweekId == originalGameweekID,
              predictionSet.resolvedCompetitionID == originalCompetitionID else { return nil }
        let excluded = visitedFixtureIDs.union([fixtureID])
        return predictionSet.orderedEditableFixtures(at: game.serverNow(relativeTo: date), excluding: excluded)
            .lazy
            .map { game.fixture(for: $0.id) ?? $0 }
            .first { $0.resolvedCompetitionID == originalCompetitionID && game.canEdit(fixture: $0, at: date) }
    }

    /// Returns true only when the sheet should close. Advancing keeps the same sheet open.
    func save(game: PredictionGameStore, apiBaseURL: String, advance: Bool) async -> Bool {
        guard !isWorking, game.enabled, isPrepared else { return false }
        guard loadedServer == normalizedServer(apiBaseURL) else {
            saveError = "The game server changed. Reload this match before saving."
            return false
        }
        guard let current = game.fixture(for: fixtureID), game.canEdit(fixture: current, at: Date()) else {
            saveError = "This match is now locked. Predictions can only be saved before kick-off."
            return false
        }

        let generation = UUID()
        requestGeneration = generation
        let savedFixtureID = fixtureID
        let savedHomeScore = homeScore
        let savedAwayScore = awayScore
        let gameweekID = originalGameweekID
        let competitionID = originalCompetitionID
        isWorking = true
        saveError = nil
        defer {
            if requestGeneration == generation { isWorking = false }
        }
        let saved = await game.save(
            fixtureID: savedFixtureID,
            homeScore: savedHomeScore,
            awayScore: savedAwayScore,
            expectedAIRevision: current.ai?.sourceRevision,
            apiBaseURL: apiBaseURL,
            penaltyWinner: savedHomeScore == savedAwayScore || current.isSecondLeg == true ? penaltyWinner : nil
        )
        guard isCurrent(generation, game: game), fixtureID == savedFixtureID else { return false }
        guard saved else {
            saveError = game.errorMessage ?? "Your prediction was not saved. Please try again before kick-off."
            return false
        }
        visitedFixtureIDs.insert(savedFixtureID)
        guard advance else { return true }

        guard let refreshedSet = await game.loadPredictionSet(fixtureID: savedFixtureID, apiBaseURL: apiBaseURL) else {
            guard isCurrent(generation, game: game) else { return false }
            saveError = "Your prediction was saved, but the next matches could not be loaded. Try again, or return to Fixtures."
            return false
        }
        guard isCurrent(generation, game: game), fixtureID == savedFixtureID else { return false }
        guard let gameweekID, refreshedSet.gameweekId == gameweekID,
              refreshedSet.resolvedCompetitionID == competitionID else {
            predictionSet = nil
            saveError = "Your prediction was saved. This match’s gameweek changed, so choose another match from Fixtures."
            return false
        }
        predictionSet = refreshedSet
        let candidates = refreshedSet.orderedEditableFixtures(
            at: game.serverNow(), excluding: visitedFixtureIDs
        )
        var attempted = visitedFixtureIDs
        for candidate in candidates {
            guard candidate.resolvedCompetitionID == competitionID, attempted.insert(candidate.id).inserted else { continue }
            let loaded = await game.loadFixture(fixtureID: candidate.id, apiBaseURL: apiBaseURL)
            guard isCurrent(generation, game: game), fixtureID == savedFixtureID else { return false }
            guard let loaded else {
                saveError = "Your prediction was saved, but the next match could not be loaded. Try again, or return to Fixtures."
                return false
            }
            // A fixture can reach kick-off while the context or fixture request is in flight.
            guard loaded.resolvedCompetitionID == competitionID, game.canEdit(fixture: loaded, at: Date()) else { continue }
            isSecondLeg = loaded.isSecondLeg == true
            homeScore = loaded.prediction?.homeScore ?? 0
            awayScore = loaded.prediction?.awayScore ?? 0
            penaltyWinner = loaded.prediction?.penaltyWinner
            isPrepared = true
            fixtureID = loaded.id
            return false
        }
        return true
    }

    func cancel() {
        requestGeneration = UUID()
        isLoading = false
        isWorking = false
    }

    private func isCurrent(_ generation: UUID, game: PredictionGameStore) -> Bool {
        requestGeneration == generation && !Task.isCancelled && game.enabled
    }

    private func normalizedServer(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
