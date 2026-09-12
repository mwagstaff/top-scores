import Foundation
import Security

nonisolated enum PredictionGameAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case missingCredential
    case invalidFixture
    case server(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The game server address is invalid."
        case .invalidResponse: "The game server returned an unreadable response. Please try again."
        case .missingCredential: "Your player session is unavailable. Your saved history has not been removed."
        case .invalidFixture: "Predictions are available for supported matches with an AI score prediction."
        case .server(_, _, let message): message
        }
    }

    var requiresGameCenterRestore: Bool {
        if case .server(409, "existing_game_center_player", _) = self { return true }
        return false
    }

    var requiresVerifiedGameCenter: Bool {
        if case .server(401, "game_center_required", _) = self { return true }
        return false
    }

    var requiresAIReview: Bool {
        if case .server(409, "ai_changed", _) = self { return true }
        return false
    }
}

nonisolated struct PredictionGameAPIClient: Sendable {
    private struct ErrorPayload: Decodable { let error: String; let code: String? }
    private struct SaveRequest: Encodable {
        let homeScore: Int
        let awayScore: Int
        let expectedAIRevision: String?
        let penaltyWinner: String?
    }
    private let baseURL: URL
    private let session: URLSession

    init(apiBaseURL: String, session: URLSession = .shared) throws {
        guard let url = URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw PredictionGameAPIError.invalidURL
        }
        baseURL = url
        self.session = session
    }

    func createPlayer() async throws -> PredictionGamePlayerResponse {
        try await request(path: "players", method: "POST", body: Data("{}".utf8))
    }

    func state(credential: String, competitionId: String? = nil) async throws -> PredictionGameStateResponse {
        try await request(path: "state", credential: credential, query: competitionQuery(competitionId))
    }

    func stats(credential: String, seasonId: String?, competitionId: String? = nil) async throws -> PredictionGameStatsResponse {
        try await request(path: "stats", credential: credential, query: seasonQuery(seasonId) + competitionQuery(competitionId))
    }

    func fixtures(ids: [String], credential: String) async throws -> PredictionGameFixturesResponse {
        try await request(path: "fixtures", credential: credential, query: [
            URLQueryItem(name: "ids", value: ids.joined(separator: ","))
        ])
    }

    func inPlay(credential: String, competitionId: String) async throws -> PredictionGameInPlayResponse {
        try await request(path: "in-play", credential: credential, query: competitionQuery(competitionId))
    }

    func nextPredictions(fixtureID: String? = nil, credential: String, includeLocked: Bool = false, competitionId: String? = nil) async throws -> PredictionGamePredictionSet {
        var query = competitionQuery(competitionId)
        if let fixtureID {
            guard let id = PredictionGameFixtureID.normalized(fixtureID) else {
                throw PredictionGameAPIError.invalidFixture
            }
            query.append(URLQueryItem(name: "fixtureId", value: id))
        }
        if includeLocked { query.append(URLQueryItem(name: "includeLocked", value: "true")) }
        return try await request(path: "next-predictions", credential: credential, query: query)
    }

    func save(fixtureID: String, homeScore: Int, awayScore: Int, expectedAIRevision: String? = nil, credential: String, penaltyWinner: String? = nil) async throws -> PredictionGameSaveResponse {
        guard let normalizedID = PredictionGameFixtureID.normalized(fixtureID) else {
            throw PredictionGameAPIError.invalidFixture
        }
        let body = try JSONEncoder().encode(SaveRequest(homeScore: homeScore, awayScore: awayScore, expectedAIRevision: expectedAIRevision, penaltyWinner: penaltyWinner))
        return try await request(path: "predictions/\(normalizedID)", method: "PUT", credential: credential, body: body)
    }

    func history(credential: String, seasonId: String?, offset: Int, competitionId: String? = nil) async throws -> PredictionGameHistoryResponse {
        try await request(path: "history", credential: credential, query: seasonQuery(seasonId) + competitionQuery(competitionId) + [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: "50")
        ])
    }

    func leaderboard(category: PredictionGameLeaderboardCategory, challengeId: String?, seasonId: String?, credential: String, competitionId: String? = nil) async throws -> PredictionGameLeaderboardResponse {
        var query = seasonQuery(seasonId) + competitionQuery(competitionId) + [URLQueryItem(name: "category", value: category.rawValue)]
        if let challengeId { query.append(URLQueryItem(name: "challengeId", value: challengeId)) }
        return try await request(path: "leaderboards", credential: credential, query: query)
    }

    func linkGameCenter(identity: PredictionGameCenterIdentity, credential: String) async throws -> PredictionGamePlayerResponse {
        try await request(path: "game-center", method: "POST", credential: credential, body: JSONEncoder().encode(identity))
    }

    func gameCenterSubmissions(credential: String) async throws -> PredictionGameCenterSubmissions {
        try await request(path: "game-center/submissions", credential: credential)
    }

    private func competitionQuery(_ competitionId: String?) -> [URLQueryItem] {
        competitionId.map { [URLQueryItem(name: "competitionId", value: $0)] } ?? []
    }

    private func seasonQuery(_ seasonId: String?) -> [URLQueryItem] {
        seasonId.map { [URLQueryItem(name: "seasonId", value: $0)] } ?? []
    }

    func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        credential: String? = nil,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Response {
        try Task.checkCancellation()
        // Preferences already contains /api/v1 (and the production reverse-proxy prefix).
        let url = baseURL.appendingPathComponent("prediction-game").appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PredictionGameAPIError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let requestURL = components.url else { throw PredictionGameAPIError.invalidURL }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let credential { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw PredictionGameAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data)
            let fallback = http.statusCode == 401
                ? "Your player session needs attention. Connect Game Center to recover linked history."
                : "The game is unavailable right now. Please try again."
            throw PredictionGameAPIError.server(status: http.statusCode, code: payload?.code ?? "", message: payload?.error ?? fallback)
        }
        do {
            return try Self.decoder().decode(Response.self, from: data)
        } catch {
            throw PredictionGameAPIError.invalidResponse
        }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid game date")
        }
        return decoder
    }
}

nonisolated struct PredictionGameCenterSubmissions: Decodable, Sendable {
    struct Leaderboard: Decodable, Sendable { let id: String; let score: Int }
    struct Achievement: Decodable, Sendable { let id: String; let percentComplete: Double }
    let leaderboards: [Leaderboard]
    let achievements: [Achievement]
}

nonisolated protocol PredictionGameCredentialStorage: Sendable {
    func load(server: String) throws -> String?
    func save(_ credential: String, server: String) throws
    func preserveGuest(_ credential: String, server: String) throws
}

nonisolated struct PredictionGameCredentialStore: PredictionGameCredentialStorage {
    private static let service = "topscores.dev.skynolimit.prediction-game"

    func load(server: String) throws -> String? {
        var query = keychainQuery(server: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credential = String(data: data, encoding: .utf8), !credential.isEmpty else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return credential
    }

    func save(_ credential: String, server: String) throws {
        let data = Data(credential.utf8)
        let query = keychainQuery(server: server)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(insertStatus)) }
    }

    // Preserve the previous guest credential before switching to an existing linked player.
    func preserveGuest(_ credential: String, server: String) throws {
        let backup = "\(server)#preserved-guest"
        if try load(server: backup) == nil { try save(credential, server: backup) }
    }

    private func keychainQuery(server: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: server]
    }
}
