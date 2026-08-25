import Foundation

nonisolated struct FantasyMatchHistoryRecord: Codable, Hashable, @unchecked Sendable {
    nonisolated static let schemaVersion = 1

    let version: Int
    let managerEntryID: Int
    let seasonKey: String
    let savedAt: Date
    let gameweek: FantasyGameweek
    let picksResponse: FantasyPicksResponse
    let liveResponse: FantasyEventLiveResponse
    let fixtures: [FantasyFixture]
    let bootstrap: FantasyBootstrapLookup

    init(
        managerEntryID: Int,
        gameweek: FantasyGameweek,
        picksResponse: FantasyPicksResponse,
        liveResponse: FantasyEventLiveResponse,
        fixtures: [FantasyFixture],
        bootstrap: FantasyBootstrapLookup,
        savedAt: Date = Date()
    ) {
        let selectedElementIDs = Set(picksResponse.picks.map(\.element))
        self.version = Self.schemaVersion
        self.managerEntryID = managerEntryID
        self.seasonKey = Self.seasonKey(
            gameweek: gameweek,
            events: bootstrap.events,
            fixtures: fixtures
        )
        self.savedAt = savedAt
        self.gameweek = gameweek
        self.picksResponse = picksResponse
        self.liveResponse = FantasyEventLiveResponse(
            elements: liveResponse.elements.filter { selectedElementIDs.contains($0.id) }
        )
        self.fixtures = fixtures
        self.bootstrap = FantasyBootstrapLookup(
            updatedAt: bootstrap.updatedAt,
            totalPlayers: bootstrap.totalPlayers,
            elements: bootstrap.elements.filter { selectedElementIDs.contains($0.id) },
            teams: bootstrap.teams,
            elementTypes: bootstrap.elementTypes,
            events: bootstrap.events
        )
    }

    var storageKey: String {
        "\(managerEntryID)|\(seasonKey)|\(gameweek.id)"
    }

    var isFinal: Bool {
        gameweek.dataChecked == true
    }

    var hasCompleteFinalData: Bool {
        isFinal && !liveResponse.elements.isEmpty
    }

    func replacingLiveResponse(
        _ liveResponse: FantasyEventLiveResponse,
        savedAt: Date
    ) -> FantasyMatchHistoryRecord {
        FantasyMatchHistoryRecord(
            managerEntryID: managerEntryID,
            gameweek: gameweek,
            picksResponse: picksResponse,
            liveResponse: liveResponse,
            fixtures: fixtures,
            bootstrap: bootstrap,
            savedAt: savedAt
        )
    }

    static func seasonKey(
        gameweek: FantasyGameweek,
        events: [FantasyGameweek],
        fixtures: [FantasyFixture]
    ) -> String {
        let firstDeadline = events
            .compactMap { parseDate($0.deadlineTime) }
            .min()
        let gameweekDeadline = parseDate(gameweek.deadlineTime)
        let firstKickoff = fixtures
            .compactMap { parseDate($0.kickoffTime) }
            .min()
        let referenceDate = firstDeadline ?? gameweekDeadline ?? firstKickoff ?? Date()
        return seasonKey(containing: referenceDate)
    }

    static func seasonKey(containing referenceDate: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: referenceDate)
        let month = calendar.component(.month, from: referenceDate)
        let startYear = month >= 7 ? year : year - 1
        return "\(startYear)-\(startYear + 1)"
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

actor FantasyMatchHistoryStore {
    static let shared = FantasyMatchHistoryStore()

    private let fileManager: FileManager
    private let rootDirectory: URL

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let baseDirectory = rootDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Top Scores", isDirectory: true)
            .appendingPathComponent("FantasyHistory", isDirectory: true)
        self.rootDirectory = baseDirectory
            .appendingPathComponent("v\(FantasyMatchHistoryRecord.schemaVersion)", isDirectory: true)
    }

    func loadRecords(managerEntryID: Int) -> [FantasyMatchHistoryRecord] {
        let managerDirectory = rootDirectory
            .appendingPathComponent("manager-\(managerEntryID)", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: managerDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        return enumerator.compactMap { item -> FantasyMatchHistoryRecord? in
            guard let url = item as? URL, url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(FantasyMatchHistoryRecord.self, from: data),
                  record.version == FantasyMatchHistoryRecord.schemaVersion,
                  record.managerEntryID == managerEntryID else {
                return nil
            }
            return record
        }
        .sorted {
            if $0.seasonKey != $1.seasonKey {
                return $0.seasonKey < $1.seasonKey
            }
            return $0.gameweek.id < $1.gameweek.id
        }
    }

    @discardableResult
    func save(_ proposedRecord: FantasyMatchHistoryRecord) -> FantasyMatchHistoryRecord {
        let destination = recordURL(for: proposedRecord)
        let existingRecord = loadRecord(at: destination)
        let record = preferredRecord(existing: existingRecord, proposed: proposedRecord)
        if record == existingRecord {
            return record
        }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: destination, options: [.atomic])
        } catch {
            diagnosticLog("Fantasy history save failed error=%@", error.localizedDescription)
        }

        return record
    }

    private func recordURL(for record: FantasyMatchHistoryRecord) -> URL {
        rootDirectory
            .appendingPathComponent("manager-\(record.managerEntryID)", isDirectory: true)
            .appendingPathComponent(record.seasonKey, isDirectory: true)
            .appendingPathComponent("gw-\(record.gameweek.id).json", isDirectory: false)
    }

    private func loadRecord(at url: URL) -> FantasyMatchHistoryRecord? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(FantasyMatchHistoryRecord.self, from: data),
              record.version == FantasyMatchHistoryRecord.schemaVersion else {
            return nil
        }
        return record
    }

    private func preferredRecord(
        existing: FantasyMatchHistoryRecord?,
        proposed: FantasyMatchHistoryRecord
    ) -> FantasyMatchHistoryRecord {
        guard let existing else { return proposed }

        if existing.isFinal {
            guard proposed.isFinal,
                  proposed.picksResponse.picks == existing.picksResponse.picks,
                  proposed.picksResponse.activeChipCodes == existing.picksResponse.activeChipCodes,
                  !proposed.liveResponse.elements.isEmpty,
                  proposed.liveResponse != existing.liveResponse else {
                return existing
            }
            return existing.replacingLiveResponse(
                proposed.liveResponse,
                savedAt: proposed.savedAt
            )
        }

        if !proposed.isFinal && proposed.savedAt < existing.savedAt {
            return existing
        }
        if !existing.liveResponse.elements.isEmpty && proposed.liveResponse.elements.isEmpty {
            if proposed.isFinal {
                return proposed.replacingLiveResponse(
                    existing.liveResponse,
                    savedAt: proposed.savedAt
                )
            }
            return existing
        }
        return proposed
    }
}
