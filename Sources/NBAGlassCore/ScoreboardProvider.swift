import Foundation

public protocol ScoreboardProvider: Sendable {
    var name: String { get }
    var isDemo: Bool { get }
    /// Fetch every NBA game for the given calendar day.
    func games(on date: Date) async throws -> [Game]
}

public enum ProviderError: Error, LocalizedError {
    case badStatus(Int)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Provider returned HTTP \(code)"
        case .decoding(let why): return "Unexpected provider response (\(why))"
        }
    }
}

// MARK: - ESPN

/// Unofficial, undocumented public ESPN scoreboard endpoint. It needs no key, but it
/// can change or disappear without notice and is intended for personal use only.
/// All ESPN-specific shapes stay in this file; decoding is lenient and failures are
/// surfaced as `ProviderError.decoding` so the UI falls back to cached data.
public struct ESPNProvider: ScoreboardProvider {
    public let name = "ESPN (unofficial)"
    public let isDemo = false
    private let session: URLSession
    private let baseURL: URL
    private let calendar: Calendar

    public init(session: URLSession = .shared,
                baseURL: URL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard")!,
                calendar: Calendar = .current) {
        self.session = session
        self.baseURL = baseURL
        self.calendar = calendar
    }

    /// ESPN's `dates` parameter is the US (Eastern) game day, so a local calendar day — e.g. in
    /// Asia/Kuala_Lumpur — can span two of them. Fetch each one and keep only games that tip off
    /// within the local day.
    public func games(on date: Date) async throws -> [Game] {
        let cal = calendar
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let all = try await withThrowingTaskGroup(of: [Game].self) { group in
            for key in Self.usGameDays(coveringLocalDay: date, calendar: cal) {
                group.addTask { try await fetch(usDayKey: key) }
            }
            return try await group.reduce(into: [Game]()) { $0 += $1 }
        }
        var seen = Set<String>()
        return all.filter { (start..<end).contains($0.startDate) && seen.insert($0.id).inserted }
    }

    /// The US/Eastern game days (`yyyyMMdd`) that overlap the given local calendar day.
    public static func usGameDays(coveringLocalDay date: Date, calendar: Calendar = .current) -> [String] {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.startOfDay(for: date)
        let last = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        let first = DayKey.string(for: start, calendar: eastern), second = DayKey.string(for: last, calendar: eastern)
        return first == second ? [first] : [first, second]
    }

    private func fetch(usDayKey: String) async throws -> [Game] {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "dates", value: usDayKey),
                            URLQueryItem(name: "limit", value: "100")]
        var request = URLRequest(url: comps.url!, timeoutInterval: 15)
        request.setValue("NBAGlass/1.0 (personal desktop scoreboard)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.badStatus(http.statusCode)
        }
        return try Self.parse(data)
    }

    // Exposed for tests.
    public static func parse(_ data: Data) throws -> [Game] {
        let board: Board
        do { board = try JSONDecoder().decode(Board.self, from: data) }
        catch { throw ProviderError.decoding(String(describing: error).prefix(120).description) }
        return (board.events ?? []).compactMap(normalize)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return f
    }()

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = dateFormatter.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func normalize(_ e: Event) -> Game? {
        guard let comp = e.competitions?.first,
              let competitors = comp.competitors,
              let homeC = competitors.first(where: { $0.homeAway == "home" }),
              let awayC = competitors.first(where: { $0.homeAway == "away" }),
              let start = parseDate(e.date ?? comp.date) else { return nil }

        let st = e.status ?? comp.status
        let status = mapStatus(name: st?.type?.name, state: st?.type?.state)
        let showScores = status == .live || status == .final

        func side(_ c: Competitor) -> GameSide? {
            guard let t = c.team, let abbr = t.abbreviation else { return nil }
            let team = Team(id: t.id ?? abbr, abbreviation: abbr,
                            displayName: t.displayName ?? abbr,
                            shortName: t.shortDisplayName ?? t.name ?? abbr,
                            colorHex: t.color, alternateColorHex: t.alternateColor,
                            record: c.records?.first(where: { $0.type == "total" })?.summary)
            let lines = (c.linescores ?? []).compactMap { $0.value.map(Int.init) }
            return GameSide(team: team,
                            score: showScores ? c.score.flatMap { Int($0) } : nil,
                            periodScores: showScores ? lines : [])
        }
        guard let away = side(awayC), let home = side(homeC) else { return nil }

        let clock = st?.displayClock
        return Game(
            id: e.id ?? comp.id ?? UUID().uuidString,
            startDate: start,
            status: status,
            statusDetail: st?.type?.detail ?? st?.type?.description ?? "",
            period: status == .live ? st?.period : nil,
            clock: status == .live ? clock : nil,
            away: away, home: home,
            venue: comp.venue?.fullName,
            broadcast: comp.broadcasts?.first?.names?.first ?? comp.broadcast
        )
    }

    private static func mapStatus(name: String?, state: String?) -> GameStatus {
        let n = name ?? ""
        if n.contains("POSTPONED") { return .postponed }
        if n.contains("CANCEL") { return .cancelled }
        switch state {
        case "pre": return .scheduled
        case "in": return .live
        case "post": return n.contains("FINAL") ? .final : .unknown
        default: return .unknown
        }
    }

    // MARK: DTOs (all optional — be lenient with a provider we don't control)
    struct Board: Decodable { var events: [Event]? }
    struct Event: Decodable {
        var id: String?; var date: String?
        var status: Status?; var competitions: [Competition]?
    }
    struct Competition: Decodable {
        var id: String?; var date: String?
        var competitors: [Competitor]?; var status: Status?
        var venue: Venue?; var broadcasts: [Broadcast]?; var broadcast: String?
    }
    struct Venue: Decodable { var fullName: String? }
    struct Broadcast: Decodable { var names: [String]? }
    struct Competitor: Decodable {
        var homeAway: String?; var team: TeamDTO?; var score: String?
        var linescores: [Line]?; var records: [Record]?
    }
    struct Line: Decodable { var value: Double? }
    struct Record: Decodable { var type: String?; var summary: String? }
    struct TeamDTO: Decodable {
        var id: String?; var abbreviation: String?; var displayName: String?
        var shortDisplayName: String?; var name: String?; var color: String?
        var alternateColor: String?
    }
    struct Status: Decodable {
        var displayClock: String?; var period: Int?; var type: StatusType?
    }
    struct StatusType: Decodable {
        var name: String?; var state: String?; var description: String?; var detail: String?
    }
}

// MARK: - Demo

/// Clearly labelled sample data for offline development and screenshots. Never live.
public struct DemoProvider: ScoreboardProvider {
    public let name = "Demo data"
    public let isDemo = true
    public init() {}

    public func games(on date: Date) async throws -> [Game] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        func t(_ abbr: String, _ name: String, _ short: String, _ color: String, _ rec: String) -> Team {
            Team(id: abbr, abbreviation: abbr, displayName: name, shortName: short, colorHex: color,
                 alternateColorHex: alt[abbr], record: rec)
        }
        let alt = ["BOS": "BA9653", "NY": "F58426", "LAL": "FDB927", "DEN": "FEC524",
                   "GS": "FFC72C", "OKC": "EF3B24", "MIA": "F9A01B", "PHX": "1D1160"]
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: day)! }
        let bos = t("BOS", "Boston Celtics", "Celtics", "007A33", "3-0")
        let nyk = t("NY", "New York Knicks", "Knicks", "006BB6", "2-1")
        let lal = t("LAL", "Los Angeles Lakers", "Lakers", "552583", "2-1")
        let den = t("DEN", "Denver Nuggets", "Nuggets", "0E2240", "1-2")
        let gsw = t("GS", "Golden State Warriors", "Warriors", "1D428A", "2-1")
        let okc = t("OKC", "Oklahoma City Thunder", "Thunder", "007AC1", "3-0")
        let mia = t("MIA", "Miami Heat", "Heat", "98002E", "1-2")
        let phx = t("PHX", "Phoenix Suns", "Suns", "E56020", "1-2")
        return [
            Game(id: "demo1", startDate: at(10), status: .final, statusDetail: "Final",
                 away: GameSide(team: nyk, score: 104, periodScores: [24, 28, 22, 30]),
                 home: GameSide(team: bos, score: 112, periodScores: [30, 26, 25, 31]),
                 venue: "Demo Arena", broadcast: nil),
            Game(id: "demo2", startDate: at(11, 30), status: .live, statusDetail: "3rd Quarter",
                 period: 3, clock: "4:32",
                 away: GameSide(team: den, score: 78, periodScores: [25, 27, 26]),
                 home: GameSide(team: lal, score: 81, periodScores: [28, 24, 29]),
                 venue: "Demo Arena", broadcast: nil),
            Game(id: "demo3", startDate: at(13), status: .scheduled, statusDetail: "Scheduled",
                 away: GameSide(team: mia), home: GameSide(team: okc), venue: "Demo Arena"),
            Game(id: "demo4", startDate: at(14, 30), status: .scheduled, statusDetail: "Scheduled",
                 away: GameSide(team: phx), home: GameSide(team: gsw), venue: "Demo Arena"),
        ]
    }
}
