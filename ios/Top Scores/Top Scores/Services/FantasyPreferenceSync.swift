import Foundation
import Combine
import Security

struct FantasySyncedPreferences: Codable, Equatable {
    struct League: Codable, Equatable { let id: Int; let name: String }
    var manager: Int?
    var rivals: [Int]
    var leagues: [League]
    var leagueOrder: [Int]? = nil

    private enum CodingKeys: String, CodingKey { case manager, rivals, leagues, leagueOrder }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let manager { try values.encode(manager, forKey: .manager) }
        else { try values.encodeNil(forKey: .manager) }
        try values.encode(rivals, forKey: .rivals)
        try values.encode(leagues, forKey: .leagues)
        try values.encodeIfPresent(leagueOrder, forKey: .leagueOrder)
    }

    static func local(defaults: UserDefaults = .standard) -> Self {
        let rivals = (try? JSONDecoder().decode([FantasyRivalManager].self, from: Data((defaults.string(forKey: "fantasy.rivalManagersJSON") ?? "[]").utf8))) ?? []
        let leagues = (try? JSONDecoder().decode([FantasyTrackedLeague].self, from: Data((defaults.string(forKey: "fantasy.trackedLeaguesJSON") ?? "[]").utf8))) ?? []
        let manager = Int(defaults.string(forKey: "fantasy.managerEntryID") ?? "")
        let orders = (try? JSONDecoder().decode([String: [Int]].self, from: Data((defaults.string(forKey: "fantasy.leagueOrderByManagerJSON") ?? "{}").utf8))) ?? [:]
        return Self(manager: Int(defaults.string(forKey: "fantasy.managerEntryID") ?? ""), rivals: rivals.map(\.entryID), leagues: leagues.map { League(id: $0.leagueID, name: "League \($0.leagueID)") }, leagueOrder: manager.flatMap { orders[String($0)] })
    }

    func apply(defaults: UserDefaults = .standard) {
        let old = (try? JSONDecoder().decode([FantasyRivalManager].self, from: Data((defaults.string(forKey: "fantasy.rivalManagersJSON") ?? "[]").utf8))) ?? []
        let managers = rivals.map { id in
            old.first { $0.entryID == id } ?? FantasyRivalManager(entryID: id, teamName: "Team \(id)", managerFirstName: "", managerLastName: "", overallPoints: nil, clubBadgeSrc: nil)
        }
        if let data = try? JSONEncoder().encode(managers) { defaults.set(String(decoding: data, as: UTF8.self), forKey: "fantasy.rivalManagersJSON") }
        if let data = try? JSONEncoder().encode(leagues.map { FantasyTrackedLeague(leagueID: $0.id) }) { defaults.set(String(decoding: data, as: UTF8.self), forKey: "fantasy.trackedLeaguesJSON") }
        if let manager, let leagueOrder {
            var orders = (try? JSONDecoder().decode([String: [Int]].self, from: Data((defaults.string(forKey: "fantasy.leagueOrderByManagerJSON") ?? "{}").utf8))) ?? [:]
            orders[String(manager)] = leagueOrder
            if let data = try? JSONEncoder().encode(orders) { defaults.set(String(decoding: data, as: UTF8.self), forKey: "fantasy.leagueOrderByManagerJSON") }
        }
        let id = manager.map(String.init) ?? ""
        if defaults.string(forKey: "fantasy.managerEntryID") != id { defaults.set(id, forKey: "fantasy.managerEntryID") }
    }

    // Names are display hints; the app resolves authoritative league names itself.
    func hasSameSelection(as other: Self) -> Bool {
        manager == other.manager && rivals == other.rivals && leagues.map(\.id) == other.leagues.map(\.id) && leagueOrder == other.leagueOrder
    }
}

struct FantasySyncSnapshot: Codable {
    var preferences: FantasySyncedPreferences
    let revision: Int
}

struct FantasyBrowserPairing: Decodable {
    let code: String
    let expiresAt: Double
    let mode: String
    let once: Bool
    var expiry: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
}

@MainActor
final class FantasyPairingInbox: ObservableObject {
    static let shared = FantasyPairingInbox()
    @Published var pendingURL: URL?

    func receive(_ url: URL, source: String) {
        let destination = FantasyPairingURL.isPairingDestination(url)
        // Never persist the URL or its pairing secret in diagnostics.
        CrashBreadcrumbs.record("incoming link source=\(source) pairing=\(destination) fragmentLength=\(url.fragment?.count ?? 0) accepted=\(FantasyPairingURL.secret(from: url) != nil)")
        guard destination else { return }
        pendingURL = url
    }
}

enum FantasyPairingURL {
    static func isPairingDestination(_ url: URL) -> Bool {
        let universal = url.scheme == "https" && url.host == "top-scores.skynolimit.dev" && url.path == "/fpl/connect"
        let custom = url.scheme == "topscores" && url.host == "fpl-connect" && url.path.isEmpty
        return universal || custom
    }

    static func secret(from url: URL) -> String? {
        guard url.user == nil, url.password == nil, url.port == nil, url.query == nil else { return nil }
        guard isPairingDestination(url), let fragment = url.fragment,
              fragment.hasPrefix("pair="), fragment.count == 48 else { return nil }
        let value = String(fragment.dropFirst(5))
        guard value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

@MainActor
final class FantasyPreferenceSync: ObservableObject {
    static let shared = FantasyPreferenceSync()
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var conflict: FantasySyncSnapshot?
    @Published private(set) var devices: [Device] = []
    struct Device: Decodable, Identifiable { let id: String; let label: String }
    private struct Session: Decodable { let token: String; let preferences: FantasySyncedPreferences; let revision: Int }
    private struct State: Decodable { let preferences: FantasySyncedPreferences; let revision: Int; let deviceID: String; let devices: [Device] }
    private struct OK: Decodable { let ok: Bool }
    private struct ServerError: Decodable { let error: String; let snapshot: FantasySyncSnapshot? }
    private struct RequestError: LocalizedError {
        let message: String
        let status: Int
        let snapshot: FantasySyncSnapshot?
        var errorDescription: String? { message }
    }
    private let baseKey = "fantasy.preferenceSync.base.v1"
    private let keychainService = "dev.skynolimit.top-scores.fpl-sync"
    private var credential: String?
    private var base: FantasySyncSnapshot?

    private init() {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "device", kSecReturnData as String: true]
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data { credential = String(data: data, encoding: .utf8) }
        if let data = UserDefaults.standard.data(forKey: baseKey) { base = try? JSONDecoder().decode(FantasySyncSnapshot.self, from: data) }
        connected = credential != nil
    }

    private func storeCredential(_ token: String?) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "device"]
        if let token {
            let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if result == errSecItemNotFound { result = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil) }
            guard result == errSecSuccess else { throw RequestError(message: "Unable to save the connection securely. Please try again.", status: 0, snapshot: nil) }
        } else { SecItemDelete(query as CFDictionary) }
        credential = token; connected = token != nil
    }

    private func remember(_ snapshot: FantasySyncSnapshot?) {
        base = snapshot
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: baseKey) }
        else { UserDefaults.standard.removeObject(forKey: baseKey) }
    }

    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }

    private func request<T: Decodable>(_ path: String, body: [String: Any]? = nil, method: String = "POST") async throws -> T {
        var request = URLRequest(url: URL(string: "https://top-scores.skynolimit.dev/api/fpl-sync/\(path)")!)
        request.httpMethod = body == nil ? "GET" : method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios", forHTTPHeaderField: "X-FPL-Client")
        if let credential { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(ServerError.self, from: data)
            throw RequestError(message: error?.error ?? "Sync is temporarily unavailable. Your settings are safe on this device.", status: (response as? HTTPURLResponse)?.statusCode ?? 0, snapshot: error?.snapshot)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func synchronize() async {
        guard connected, !busy, conflict == nil else { return }
        busy = true; defer { busy = false }
        do { try await synchronizeCurrent() }
        catch is CancellationError { }
        catch { handle(error) }
    }

    private func synchronizeCurrent() async throws {
        let captured = FantasySyncedPreferences.local()
        guard let base else {
            let state: State = try await request("state")
            conflict = FantasySyncSnapshot(preferences: state.preferences, revision: state.revision)
            status = "Choose whether to keep this device’s settings or the synced settings."
            return
        }
        // Keep server display names when only the app's local name hints differ.
        var sending = captured
        sending.leagues = captured.leagues.map { league in base.preferences.leagues.first { $0.id == league.id } ?? league }
        let result: FantasySyncSnapshot = try await request("state", body: ["base": try object(base), "preferences": try object(sending)], method: "PUT")
        if FantasySyncedPreferences.local().hasSameSelection(as: captured) {
            if !result.preferences.hasSameSelection(as: captured) { result.preferences.apply() }
            remember(result)
        } else { remember(FantasySyncSnapshot(preferences: sending, revision: result.revision)) }
        status = "Settings synced"
    }

    func inspectBrowser(_ secret: String) async throws -> FantasyBrowserPairing {
        try await request("browser-pair/inspect", body: ["secret": secret])
    }

    func connectBrowser(_ secret: String) async throws {
        guard !busy else { throw RequestError(message: "Please wait for the current sync to finish.", status: 0, snapshot: nil) }
        busy = true; defer { busy = false }
        do {
            guard FantasySyncedPreferences.local().manager != nil else {
                throw RequestError(message: "Set up your FPL team in the app, then scan the website’s QR code again.", status: 400, snapshot: nil)
            }
            if !connected {
                let captured = FantasySyncedPreferences.local()
                let session: Session = try await request("session", body: ["preferences": try object(captured)])
                try storeCredential(session.token)
                remember(FantasySyncSnapshot(preferences: session.preferences, revision: session.revision))
            }
            try await synchronizeCurrent()
            guard conflict == nil else { throw RequestError(message: "Resolve the settings conflict before connecting another device.", status: 409, snapshot: conflict) }
            let _: OK = try await request("browser-pair/approve", body: ["secret": secret])
            status = "Browser approved. Your FPL setup will appear on the website automatically."
        } catch { handle(error); throw error }
    }

    func resolve(useLocal: Bool) async {
        guard let conflict, !busy else { return }
        if !useLocal { conflict.preferences.apply() }
        remember(conflict); self.conflict = nil
        await synchronize()
    }

    func loadDevices() async {
        guard connected else { return }
        do { let state: State = try await request("state"); devices = state.devices.filter { $0.id != state.deviceID } }
        catch { handle(error) }
    }

    func disconnect(deviceID: String? = nil) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let _: OK = try await request("disconnect", body: deviceID.map { ["deviceID": $0] } ?? [:])
            if deviceID == nil { try storeCredential(nil); remember(nil); conflict = nil; devices = []; status = "Disconnected. Your settings remain on this device." }
            else { await loadDevices() }
        } catch { handle(error) }
    }

    private func handle(_ error: Error) {
        if let error = error as? RequestError {
            if error.status == 401 { try? storeCredential(nil); remember(nil); conflict = nil }
            if let snapshot = error.snapshot { conflict = snapshot }
        }
        status = error.localizedDescription
    }
}
