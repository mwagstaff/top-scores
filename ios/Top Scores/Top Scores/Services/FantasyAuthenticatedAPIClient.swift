import Foundation
import Security
import WebKit

@MainActor
struct FantasyAuthenticatedAPIClient {
    struct CurrentTeamResult {
        let entryID: Int
        let team: FantasyCurrentTeamResponse
    }

    typealias CookieProvider = () async -> [HTTPCookie]
    typealias AccessTokenProvider = () async throws -> String?

    private struct AuthenticationContext {
        let cookies: [HTTPCookie]
        let accessToken: String?
    }

    private let session: URLSession
    private let cookieProvider: CookieProvider
    private let accessTokenProvider: AccessTokenProvider

    init(
        session: URLSession? = nil,
        cookieProvider: CookieProvider? = nil,
        accessTokenProvider: AccessTokenProvider? = nil
    ) {
        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 15
            resolvedSession = URLSession(configuration: configuration)
        }
        self.session = resolvedSession
        self.cookieProvider = cookieProvider ?? Self.fplCookies
        self.accessTokenProvider = accessTokenProvider ?? {
            try await FantasyAuthSessionStore.validAccessToken(using: resolvedSession)
        }
    }

    func fetchCurrentTeam(entryID: Int) async throws -> CurrentTeamResult {
        let authentication = try await authenticationContext()

        let resolvedEntryID = try await authenticatedEntryID(
            requestedEntryID: entryID,
            authentication: authentication
        )
        let data = try await fetch(
            path: "/api/my-team/\(resolvedEntryID)/",
            operation: "fpl_current_team",
            authentication: authentication
        )

        do {
            let team = try JSONDecoder().decode(FantasyCurrentTeamResponse.self, from: data)
            return CurrentTeamResult(entryID: resolvedEntryID, team: team)
        } catch {
            throw FantasyPublicAPIError.decodeFailed(
                operation: "fpl_current_team",
                underlying: error
            )
        }
    }

    func detectSignedInEntryID() async throws -> Int {
        let authentication = try await authenticationContext()
        let data = try await fetch(
            path: "/api/me/",
            operation: "fpl_account",
            authentication: authentication
        )
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entryID = Self.entryID(from: payload) else {
            throw FantasyPublicAPIError.invalidHTTPResponse
        }
        return entryID
    }

    private func authenticatedEntryID(
        requestedEntryID: Int,
        authentication: AuthenticationContext
    ) async throws -> Int {
        let data: Data
        do {
            data = try await fetch(
                path: "/api/me/",
                operation: "fpl_account",
                authentication: authentication
            )
        } catch let error as FantasyPublicAPIError {
            if case .authenticationRequired = error {
                throw error
            }
            return requestedEntryID
        } catch {
            return requestedEntryID
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return requestedEntryID
        }
        return Self.entryID(from: payload) ?? requestedEntryID
    }

    private func fetch(
        path: String,
        operation: String,
        authentication: AuthenticationContext
    ) async throws -> Data {
        guard let url = URL(string: "https://fantasy.premierleague.com\(path)") else {
            throw FantasyPublicAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let compatibleCookies = authentication.cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return url.host?.hasSuffix(domain) == true && path.hasPrefix(cookie.path)
        }
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: compatibleCookies)
        for (field, value) in cookieHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let token = authentication.accessToken {
            let authorization = token.lowercased().hasPrefix("bearer ")
                ? token
                : "Bearer \(token)"
            request.setValue(authorization, forHTTPHeaderField: "X-API-Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FantasyPublicAPIError.invalidHTTPResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            if authentication.accessToken != nil {
                FantasyAuthSessionStore.clear()
            }
            throw FantasyPublicAPIError.authenticationRequired
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.lowercased().contains("the game is being updated") {
                throw FantasyPublicAPIError.gameUpdating(operation: operation, message: body)
            }
            throw FantasyPublicAPIError.badStatus(
                http.statusCode,
                operation: operation,
                snippet: String(body.prefix(240))
            )
        }
        return data
    }

    private func authenticationContext() async throws -> AuthenticationContext {
        let cookies = await cookieProvider()
        let cookieToken = cookies.first(where: {
            $0.name.caseInsensitiveCompare("ACCESS_TOKEN") == .orderedSame
        })?.value
        let accessToken = if let cookieToken, !cookieToken.isEmpty {
            cookieToken
        } else {
            try await accessTokenProvider()
        }
        let hasLegacySession = cookies.contains {
            $0.name.caseInsensitiveCompare("sessionid") == .orderedSame
        }
        guard accessToken?.isEmpty == false || hasLegacySession else {
            throw FantasyPublicAPIError.authenticationRequired
        }
        return AuthenticationContext(cookies: cookies, accessToken: accessToken)
    }

    private static func fplCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func entryID(from payload: [String: Any]) -> Int? {
        let player = payload["player"] as? [String: Any]
        let candidate = player?["entry"]
            ?? player?["entry_id"]
            ?? payload["entry"]
            ?? payload["entry_id"]
        if let number = candidate as? NSNumber, number.intValue > 0 {
            return number.intValue
        }
        if let string = candidate as? String, let value = Int(string), value > 0 {
            return value
        }
        return nil
    }
}

enum FantasyAuthSessionStore {
    private static let service = "dev.skynolimit.topscores.fpl-auth"
    private static let account = "oidc-session"
    private static let clientID = "bfcbaf69-aade-4c1b-8f00-c1cb8a193030"

    private struct OIDCSession: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
        }
    }

    private struct TokenRefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    static func saveOIDCSessionJSON(_ json: String) throws {
        guard let data = json.data(using: .utf8) else {
            throw FantasyPublicAPIError.invalidHTTPResponse
        }
        let session = try JSONDecoder().decode(OIDCSession.self, from: data)
        guard !session.accessToken.isEmpty else {
            throw FantasyPublicAPIError.authenticationRequired
        }
        try save(session)
    }

    static func validAccessToken(using urlSession: URLSession) async throws -> String? {
        guard let session = load() else { return nil }
        if session.expiresAt.map({ $0 > Date().timeIntervalSince1970 + 60 }) != false {
            return session.accessToken
        }
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            clear()
            return nil
        }

        guard let url = URL(string: "https://account.premierleague.com/as/token") else {
            throw FantasyPublicAPIError.invalidURL
        }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FantasyPublicAPIError.invalidHTTPResponse
        }
        if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
            clear()
            return nil
        }
        guard (200...299).contains(http.statusCode) else {
            throw FantasyPublicAPIError.badStatus(
                http.statusCode,
                operation: "fpl_token_refresh",
                snippet: String((String(data: data, encoding: .utf8) ?? "").prefix(240))
            )
        }
        do {
            let refreshed = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
            let updated = OIDCSession(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken ?? refreshToken,
                expiresAt: Date().timeIntervalSince1970 + refreshed.expiresIn
            )
            try save(updated)
            return updated.accessToken
        } catch let error as FantasyPublicAPIError {
            throw error
        } catch {
            throw FantasyPublicAPIError.decodeFailed(
                operation: "fpl_token_refresh",
                underlying: error
            )
        }
    }

    static func clear() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }

    private static func load() -> OIDCSession? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(OIDCSession.self, from: data)
    }

    private static func save(_ session: OIDCSession) throws {
        let data = try JSONEncoder().encode(session)
        let query = keychainQuery()
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
