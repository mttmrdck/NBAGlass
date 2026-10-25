import Foundation

public enum GameStatus: String, Codable, Sendable {
    case scheduled, live, final, postponed, cancelled, unknown
}

public struct Team: Codable, Hashable, Sendable {
    public var id: String
    public var abbreviation: String
    public var displayName: String
    public var shortName: String
    /// Provider-supplied primary colour, hex without `#`.
    public var colorHex: String?
    /// Provider-supplied secondary colour, hex without `#`.
    public var alternateColorHex: String?
    public var record: String?

    public init(id: String, abbreviation: String, displayName: String, shortName: String,
                colorHex: String? = nil, alternateColorHex: String? = nil, record: String? = nil) {
        self.id = id; self.abbreviation = abbreviation; self.displayName = displayName
        self.shortName = shortName; self.colorHex = colorHex; self.alternateColorHex = alternateColorHex
        self.record = record
    }
}

public struct GameSide: Codable, Hashable, Sendable {
    public var team: Team
    public var score: Int?
    /// Points per period (regulation quarters followed by overtimes), as reported.
    public var periodScores: [Int]

    public init(team: Team, score: Int? = nil, periodScores: [Int] = []) {
        self.team = team; self.score = score; self.periodScores = periodScores
    }
}

public struct Game: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var startDate: Date
    public var status: GameStatus
    /// Provider's human-readable status (e.g. "Halftime", "Final/OT").
    public var statusDetail: String
    public var period: Int?
    public var clock: String?
    public var away: GameSide
    public var home: GameSide
    public var venue: String?
    public var broadcast: String?

    public init(id: String, startDate: Date, status: GameStatus, statusDetail: String,
                period: Int? = nil, clock: String? = nil, away: GameSide, home: GameSide,
                venue: String? = nil, broadcast: String? = nil) {
        self.id = id; self.startDate = startDate; self.status = status
        self.statusDetail = statusDetail; self.period = period; self.clock = clock
        self.away = away; self.home = home; self.venue = venue; self.broadcast = broadcast
    }

    public var hasScores: Bool { away.score != nil && home.score != nil }

    /// Winner of a completed game, nil if tied/unknown/not final.
    public var winnerIsHome: Bool? {
        guard status == .final, let a = away.score, let h = home.score, a != h else { return nil }
        return h > a
    }

    /// "Q3", "OT", "2OT" …
    public static func periodLabel(_ period: Int) -> String {
        switch period {
        case ..<1: return ""
        case 1...4: return "Q\(period)"
        case 5: return "OT"
        default: return "\(period - 4)OT"
        }
    }

    /// Compact live status, e.g. "Q3 4:32", "Halftime".
    public var liveLabel: String {
        let lower = statusDetail.lowercased()
        if lower.contains("halftime") { return "Halftime" }
        if lower.contains("end of") { return statusDetail.replacingOccurrences(of: "End of ", with: "End ") }
        guard let p = period, p > 0 else { return statusDetail }
        let label = Game.periodLabel(p)
        if let c = clock, !c.isEmpty { return "\(label) \(c)" }
        return label
    }

    public func involves(_ abbreviations: Set<String>) -> Bool {
        abbreviations.contains(away.team.abbreviation) || abbreviations.contains(home.team.abbreviation)
    }
}

public struct Slate: Codable, Sendable {
    public var dayKey: String
    public var games: [Game]
    public var fetchedAt: Date
    public var providerName: String
    public var isDemo: Bool

    public init(dayKey: String, games: [Game], fetchedAt: Date, providerName: String, isDemo: Bool) {
        self.dayKey = dayKey; self.games = games; self.fetchedAt = fetchedAt
        self.providerName = providerName; self.isDemo = isDemo
    }
}

public enum GameFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all = "ALL", live = "LIVE", upcoming = "UPCOMING", final = "FINAL"
    public var id: String { rawValue }
}

public enum GameSection: String, CaseIterable, Identifiable, Sendable {
    case live = "Live", upcoming = "Upcoming", final = "Final", other = "Postponed / Cancelled"
    public var id: String { rawValue }

    public init(_ status: GameStatus) {
        switch status {
        case .live: self = .live
        case .scheduled: self = .upcoming
        case .final: self = .final
        default: self = .other
        }
    }
}

public enum DayKey {
    /// `yyyyMMdd` in the user's calendar — also the provider's date parameter.
    public static func string(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Logo image locations on ESPN's public CDN. File names are the provider's lowercased team
/// abbreviation; the `500-dark` set is drawn for dark backgrounds.
public enum TeamLogos {
    public static let league = URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/nba.png")!
    public static func url(for abbreviation: String) -> URL {
        URL(string: "https://a.espncdn.com/i/teamlogos/nba/500-dark/\(abbreviation.lowercased()).png")!
    }
}

public enum NBATeams {
    /// (abbreviation as used by the ESPN provider, display name)
    public static let all: [(abbr: String, name: String)] = [
        ("ATL", "Atlanta Hawks"), ("BOS", "Boston Celtics"), ("BKN", "Brooklyn Nets"),
        ("CHA", "Charlotte Hornets"), ("CHI", "Chicago Bulls"), ("CLE", "Cleveland Cavaliers"),
        ("DAL", "Dallas Mavericks"), ("DEN", "Denver Nuggets"), ("DET", "Detroit Pistons"),
        ("GS", "Golden State Warriors"), ("HOU", "Houston Rockets"), ("IND", "Indiana Pacers"),
        ("LAC", "LA Clippers"), ("LAL", "Los Angeles Lakers"), ("MEM", "Memphis Grizzlies"),
        ("MIA", "Miami Heat"), ("MIL", "Milwaukee Bucks"), ("MIN", "Minnesota Timberwolves"),
        ("NO", "New Orleans Pelicans"), ("NY", "New York Knicks"), ("OKC", "Oklahoma City Thunder"),
        ("ORL", "Orlando Magic"), ("PHI", "Philadelphia 76ers"), ("PHX", "Phoenix Suns"),
        ("POR", "Portland Trail Blazers"), ("SAC", "Sacramento Kings"), ("SA", "San Antonio Spurs"),
        ("TOR", "Toronto Raptors"), ("UTAH", "Utah Jazz"), ("WSH", "Washington Wizards"),
    ]
}
