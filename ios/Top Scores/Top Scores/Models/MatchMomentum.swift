import Foundation

nonisolated struct MatchMomentum: Codable, Hashable, Sendable {
    struct Point: Codable, Hashable, Sendable {
        let minute: Double
        let value: Double
    }
    struct Segment: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let side: String
        let points: [Point]
    }
    struct Annotation: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let minute: Double
        let time: String
        let side: String
        let kind: String
        let label: String

        var symbol: String {
            switch kind {
            case "goal": "⚽"
            case "red_card": "▮"
            case "penalty_missed": "P×"
            default: "⚽×"
            }
        }
    }
    struct Tick: Codable, Hashable, Sendable {
        let minute: Double
        let label: String
    }
    struct Marker: Identifiable {
        let annotation: Annotation
        let x: Double
        let lane: Int
        var id: String { annotation.id }
    }

    let status: String
    let segments: [Segment]
    let annotations: [Annotation]
    let endMinute: Double
    let scale: Double
    let ticks: [Tick]
    let updatedAt: String?
    let refreshAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case status, segments, annotations, scale, ticks
        case endMinute = "end_minute"
        case updatedAt = "updated_at"
        case refreshAfterSeconds = "refresh_after_seconds"
    }

    var isRenderable: Bool {
        status == "available" && endMinute.isFinite && endMinute > 0 && endMinute <= 150 &&
        scale.isFinite && scale > 0 && !segments.isEmpty &&
        segments.allSatisfy { segment in
            ["home", "away"].contains(segment.side) && segment.points.count >= 2 &&
            segment.points.allSatisfy { $0.minute.isFinite && $0.minute >= 0 && $0.minute <= endMinute && $0.value.isFinite }
        } && annotations.allSatisfy { $0.minute.isFinite && $0.minute >= 0 && $0.minute <= endMinute } &&
        ticks.allSatisfy { $0.minute.isFinite && $0.minute >= 0 && $0.minute <= endMinute }
    }

    func markers(side: String, width: Double) -> [Marker] {
        guard endMinute > 0 else { return [] }
        var lastPositions: [Double] = []
        return annotations.filter { $0.side == side }.sorted { $0.minute < $1.minute }.map { annotation in
            let x = min(width, annotation.minute / endMinute * width)
            let lane = lastPositions.firstIndex { x - $0 >= 44 } ?? lastPositions.count
            if lane == lastPositions.count { lastPositions.append(x) } else { lastPositions[lane] = x }
            return Marker(annotation: annotation, x: x, lane: lane)
        }
    }
}
