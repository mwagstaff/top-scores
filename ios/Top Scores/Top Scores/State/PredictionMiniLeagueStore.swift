import Combine
import Foundation

/// All private data lives in memory and is cleared when its verified Game Center scope changes.
@MainActor
final class PredictionMiniLeagueStore: ObservableObject {
    @Published private(set) var leagues: [PredictionMiniLeague] = []
    @Published private(set) var detail: PredictionMiniLeagueDetailResponse?
    @Published private(set) var standings: [PredictionMiniLeagueStanding] = []
    @Published private(set) var fixtures: [PredictionGameFixture] = []
    @Published private(set) var sharedAI: [String: PredictionGameAI] = [:]
    @Published private(set) var round: PredictionMiniLeagueRound?
    @Published private(set) var scoringEligible = true
    @Published private(set) var invitationPreview: PredictionMiniLeagueInvitationPreview?
    @Published private(set) var invitation: PredictionMiniLeagueInvitation?
    @Published private(set) var invitations: [PredictionMiniLeagueInvitationRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var isLoadingFixtures = false
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private weak var boundGame: PredictionGameStore?
    private var scopeSubscription: AnyCancellable?
    private var listRequestID = UUID()
    private var detailRequestID = UUID()
    private var fixtureRequestID = UUID()
    private var invitationLeagueID: String?
    private var fixtureContext: String?

    func load(game: PredictionGameStore, apiBaseURL: String) async {
        bind(game)
        let requestID = UUID()
        listRequestID = requestID
        isLoading = true
        errorMessage = nil
        defer { if listRequestID == requestID { isLoading = false } }
        do {
            let response: PredictionMiniLeagueListResponse = try await request("my-leagues", game: game, apiBaseURL: apiBaseURL)
            guard requestID == listRequestID else { return }
            leagues = response.leagues
        } catch {
            if requestID == listRequestID {
                if isAccessDenied(error) { clearPrivateData() }
                report(error)
            }
        }
    }

    func loadDetail(leagueID: String, scope: PredictionMiniLeagueScope = .round,
                    roundID: String? = nil, seasonID: String? = nil,
                    game: PredictionGameStore, apiBaseURL: String) async {
        bind(game)
        let requestID = UUID()
        detailRequestID = requestID
        if detail?.league.id != leagueID { detail = nil }
        standings = []
        isLoadingDetail = true
        errorMessage = nil
        defer { if detailRequestID == requestID { isLoadingDetail = false } }
        do {
            let path = try leaguePath(leagueID)
            let response: PredictionMiniLeagueDetailResponse = try await request(path, game: game, apiBaseURL: apiBaseURL)
            guard detailRequestID == requestID else { return }
            detail = response
            var query = [URLQueryItem(name: "scope", value: scope.rawValue)]
            if let roundID { query.append(URLQueryItem(name: "roundId", value: roundID)) }
            if let seasonID { query.append(URLQueryItem(name: "seasonId", value: seasonID)) }
            let table: PredictionMiniLeagueStandingsResponse = try await request(path + "/standings", query: query, game: game, apiBaseURL: apiBaseURL)
            guard detailRequestID == requestID else { return }
            standings = table.rows
            upsert(response.league)
        } catch {
            if detailRequestID == requestID {
                if isAccessDenied(error) {
                    detail = nil; standings = []; fixtures = []; sharedAI = [:]
                    leagues.removeAll { $0.id == leagueID }
                    if invitationLeagueID == leagueID { invitation = nil; invitations = []; invitationLeagueID = nil }
                }
                report(error)
            }
        }
    }

    func loadFixtures(leagueID: String, roundID: String? = nil, game: PredictionGameStore, apiBaseURL: String) async {
        bind(game)
        let requestID = UUID()
        fixtureRequestID = requestID
        let context = leagueID + "|" + (roundID ?? "current")
        if fixtureContext != context { fixtures = []; sharedAI = [:]; round = nil; scoringEligible = true }
        fixtureContext = context
        isLoadingFixtures = true
        errorMessage = nil
        defer { if fixtureRequestID == requestID { isLoadingFixtures = false } }
        do {
            let query = roundID.map { [URLQueryItem(name: "roundId", value: $0)] } ?? []
            let response: PredictionMiniLeagueFixtureResponse = try await request(try leaguePath(leagueID) + "/fixtures", query: query, game: game, apiBaseURL: apiBaseURL)
            guard fixtureRequestID == requestID else { return }
            fixtures = response.fixtures
            sharedAI = Dictionary(response.sharedAI.map { ($0.fixtureId, $0.ai) }, uniquingKeysWith: { first, _ in first })
            round = response.round
            scoringEligible = response.scoringEligible ?? true
            game.acceptMiniLeagueFixtures(response)
        } catch {
            if fixtureRequestID == requestID {
                if isAccessDenied(error) { fixtures = []; sharedAI = [:]; round = nil }
                report(error)
            }
        }
    }

    func create(name: String, competitionID: String, showAI: Bool = true,
                game: PredictionGameStore, apiBaseURL: String) async -> PredictionMiniLeague? {
        await leagueMutation(path: "mini-leagues", method: "POST",
            body: ["name": name, "competitionId": competitionID, "showAI": showAI], game: game, apiBaseURL: apiBaseURL)
    }

    func updateLeague(leagueID: String, name: String? = nil, showAI: Bool? = nil,
                      game: PredictionGameStore, apiBaseURL: String) async -> PredictionMiniLeague? {
        do {
            var body: [String: Any] = [:]
            if let name { body["name"] = name }
            if let showAI { body["showAI"] = showAI }
            return await leagueMutation(path: try leaguePath(leagueID), method: "PATCH", body: body, game: game, apiBaseURL: apiBaseURL)
        } catch { report(error); return nil }
    }

    func preview(code: String, game: PredictionGameStore, apiBaseURL: String) async -> Bool {
        bind(game)
        guard !isWorking else { return false }
        isWorking = true; errorMessage = nil; invitationPreview = nil
        defer { isWorking = false }
        do {
            let response: PredictionMiniLeagueInvitationPreviewResponse = try await request("mini-league-invitations/preview", method: "POST",
                body: ["code": code], game: game, apiBaseURL: apiBaseURL)
            invitationPreview = response.invitation
            return true
        } catch { report(error); return false }
    }

    func join(code: String, game: PredictionGameStore, apiBaseURL: String) async -> PredictionMiniLeague? {
        await leagueMutation(path: "mini-league-invitations/redeem", method: "POST", body: ["code": code], game: game, apiBaseURL: apiBaseURL)
    }

    func clearInvitationPreview() { invitationPreview = nil }

    func createInvitation(leagueID: String, game: PredictionGameStore, apiBaseURL: String) async -> PredictionMiniLeagueInvitation? {
        bind(game)
        guard !isWorking else { return nil }
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            let response: PredictionMiniLeagueInvitationResponse = try await request(try leaguePath(leagueID) + "/invitations", method: "POST", body: [:], game: game, apiBaseURL: apiBaseURL)
            invitationLeagueID = leagueID
            invitation = response.invitation
            await loadInvitations(leagueID: leagueID, game: game, apiBaseURL: apiBaseURL)
            return response.invitation
        } catch { report(error); return nil }
    }

    func loadInvitations(leagueID: String, game: PredictionGameStore, apiBaseURL: String) async {
        bind(game)
        if invitationLeagueID != leagueID { invitation = nil; invitations = [] }
        invitationLeagueID = leagueID
        do {
            let response: PredictionMiniLeagueInvitationsResponse = try await request(try leaguePath(leagueID) + "/invitations", game: game, apiBaseURL: apiBaseURL)
            guard invitationLeagueID == leagueID else { return }
            invitations = response.invitations
        } catch { if isAccessDenied(error) { invitations = []; invitation = nil }; report(error) }
    }

    func revokeInvitation(leagueID: String, invitationID: String, game: PredictionGameStore, apiBaseURL: String) async -> Bool {
        do {
            let result = await action(path: try leaguePath(leagueID) + "/invitations/" + identifier(invitationID), method: "DELETE", game: game, apiBaseURL: apiBaseURL)
            if result {
                if invitation?.id == invitationID { invitation = nil }
                await loadInvitations(leagueID: leagueID, game: game, apiBaseURL: apiBaseURL)
            }
            return result
        } catch { report(error); return false }
    }

    func removeMember(leagueID: String, memberID: String, game: PredictionGameStore, apiBaseURL: String) async -> Bool {
        await memberAction(leagueID: leagueID, memberID: memberID, suffix: "", method: "DELETE", game: game, apiBaseURL: apiBaseURL)
    }
    func reinstateMember(leagueID: String, memberID: String, game: PredictionGameStore, apiBaseURL: String) async -> Bool {
        await memberAction(leagueID: leagueID, memberID: memberID, suffix: "/reinstate", method: "POST", game: game, apiBaseURL: apiBaseURL)
    }
    func transferOwnership(leagueID: String, memberID: String, game: PredictionGameStore, apiBaseURL: String) async -> Bool {
        do { return await action(path: try leaguePath(leagueID) + "/transfer", body: ["memberId": memberID], game: game, apiBaseURL: apiBaseURL) }
        catch { report(error); return false }
    }
    func closeLeague(leagueID: String, game: PredictionGameStore, apiBaseURL: String) async -> Bool {
        do { return await action(path: try leaguePath(leagueID) + "/close", game: game, apiBaseURL: apiBaseURL) }
        catch { report(error); return false }
    }
    func leaveLeague(leagueID: String, game: PredictionGameStore, apiBaseURL: String) async -> Bool {
        do {
            let result = await action(path: try leaguePath(leagueID) + "/membership", method: "DELETE", game: game, apiBaseURL: apiBaseURL)
            if result { leagues.removeAll { $0.id == leagueID }; detail = nil; standings = []; fixtures = []; sharedAI = [:]; invitations = []; invitation = nil }
            return result
        } catch { report(error); return false }
    }

    private func memberAction(leagueID: String, memberID: String, suffix: String, method: String,
                              game: PredictionGameStore, apiBaseURL: String) async -> Bool {
        do { return await action(path: try leaguePath(leagueID) + "/members/" + identifier(memberID) + suffix, method: method, game: game, apiBaseURL: apiBaseURL) }
        catch { report(error); return false }
    }
    private func action(path: String, method: String = "POST", body: [String: Any] = [:],
                        game: PredictionGameStore, apiBaseURL: String) async -> Bool {
        bind(game)
        guard !isWorking else { return false }
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            let response: PredictionMiniLeagueActionResponse = try await request(path, method: method, body: body, game: game, apiBaseURL: apiBaseURL)
            return response.ok
        } catch { report(error); return false }
    }
    private func leagueMutation(path: String, method: String, body: [String: Any],
                                game: PredictionGameStore, apiBaseURL: String) async -> PredictionMiniLeague? {
        bind(game)
        guard !isWorking else { return nil }
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            let response: PredictionMiniLeagueResponse = try await request(path, method: method, body: body, game: game, apiBaseURL: apiBaseURL)
            upsert(response.league)
            return response.league
        } catch { report(error); return nil }
    }
    private func request<Response: Decodable & Sendable>(
        _ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil,
        game: PredictionGameStore, apiBaseURL: String
    ) async throws -> Response {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await game.withMiniLeagueClient(apiBaseURL: apiBaseURL) { client, credential in
            try await client.request(path: path, method: method, credential: credential, query: query, body: data)
        }
    }
    private func bind(_ game: PredictionGameStore) {
        guard boundGame !== game else { return }
        clearPrivateData()
        boundGame = game
        scopeSubscription = game.$privateLeagueScopeID.dropFirst().sink { [weak self] _ in
            self?.clearPrivateData()
        }
    }
    private func clearPrivateData() {
        leagues = []; detail = nil; standings = []; fixtures = []; sharedAI = [:]; round = nil; scoringEligible = true; fixtureContext = nil
        invitationPreview = nil; invitation = nil; invitations = []; invitationLeagueID = nil; errorMessage = nil
    }
    private func upsert(_ league: PredictionMiniLeague) {
        if let index = leagues.firstIndex(where: { $0.id == league.id }) { leagues[index] = league }
        else { leagues.insert(league, at: 0) }
    }
    private func leaguePath(_ id: String) throws -> String { "mini-leagues/" + (try identifier(id)) }
    private func identifier(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 128, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
            throw PredictionMiniLeagueError.invalidIdentifier
        }
        return id
    }
    private func isAccessDenied(_ error: Error) -> Bool {
        if case PredictionGameAPIError.server(let status, _, _) = error { return [401, 403, 404].contains(status) }
        return error is PredictionMiniLeagueError
    }
    private func report(_ error: Error) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        errorMessage = error.localizedDescription
    }
}
