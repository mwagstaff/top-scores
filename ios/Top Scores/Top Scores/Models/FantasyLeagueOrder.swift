import Foundation
import SwiftUI

struct FantasyLeagueOrder {
    private var orders: [String: [Int]]

    init(json: String) {
        orders = (try? JSONDecoder().decode([String: [Int]].self, from: Data(json.utf8))) ?? [:]
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(orders) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func orderedIDs(_ availableIDs: [Int], managerID: Int) -> [Int] {
        let available = Set(availableIDs)
        var seen = Set<Int>()
        return ((orders[String(managerID)] ?? []) + availableIDs).filter {
            available.contains($0) && seen.insert($0).inserted
        }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int, availableIDs: [Int], managerID: Int) {
        var ids = orderedIDs(availableIDs, managerID: managerID)
        guard managerID > 0, destination >= 0, destination <= ids.count,
              source.allSatisfy({ ids.indices.contains($0) }) else { return }
        ids.move(fromOffsets: source, toOffset: destination)
        orders[String(managerID)] = ids
    }

    mutating func move(_ leagueID: Int, to targetID: Int, availableIDs: [Int], managerID: Int) -> Bool {
        var ids = orderedIDs(availableIDs, managerID: managerID)
        guard managerID > 0,
              let source = ids.firstIndex(of: leagueID),
              let destination = ids.firstIndex(of: targetID),
              source != destination else { return false }
        ids.remove(at: source)
        ids.insert(leagueID, at: destination)
        orders[String(managerID)] = ids
        return true
    }
}
