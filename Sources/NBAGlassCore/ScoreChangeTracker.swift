import Foundation

/// A team's score went up between two consecutive live fetches.
public struct ScoringEvent: Equatable, Sendable {
    public let gameID: String
    public let teamID: String
    public let points: Int
    public init(gameID: String, teamID: String, points: Int) {
        self.gameID = gameID; self.teamID = teamID; self.points = points
    }
}

/// Detects real score increases by comparing each fresh network result with the previous one
/// for the same day. Only fed with successful network fetches — never cached data — and the
/// first result for a day (or after a long gap) only establishes a baseline, so launching,
/// switching dates or waking from sleep never produces celebrations.
public struct ScoreChangeTracker: Sendable {
    private var scores: [String: Int] = [:]   // "gameID|teamID" → last seen score
    private var dayKey: String?
    private var updatedAt: Date?
    /// A baseline older than this is considered stale (e.g. polling was paused) and replaced silently.
    public var maxBaselineAge: TimeInterval

    public init(maxBaselineAge: TimeInterval = 600) { self.maxBaselineAge = maxBaselineAge }

    public static func key(gameID: String, teamID: String) -> String { "\(gameID)|\(teamID)" }

    public mutating func reset() { scores = [:]; dayKey = nil; updatedAt = nil }

    public mutating func ingest(_ games: [Game], dayKey: String, at now: Date = Date()) -> [ScoringEvent] {
        let comparable = self.dayKey == dayKey && updatedAt.map { now.timeIntervalSince($0) <= maxBaselineAge } == true
        if !comparable { scores = [:] }
        var events: [ScoringEvent] = []
        var next: [String: Int] = [:]
        for game in games {
            for side in [game.away, game.home] {
                let key = Self.key(gameID: game.id, teamID: side.team.id)
                // A missing score drops the baseline, so its reappearance is not an "increase".
                guard let score = side.score else { continue }
                if comparable, let previous = scores[key], score > previous {
                    events.append(ScoringEvent(gameID: game.id, teamID: side.team.id, points: score - previous))
                }
                next[key] = score
            }
        }
        scores = next; self.dayKey = dayKey; updatedAt = now
        return events
    }
}
