import Testing
import Foundation
import Combine
@testable import NBAGlassCore

private func payload(state: String, name: String, scores: (String, String), period: Int = 0,
                     clock: String = "0.0", lines: String = "[]") -> Data {
    """
    {"events":[{"id":"1","date":"2026-10-25T21:00Z","status":{"displayClock":"\(clock)","period":\(period),
      "type":{"name":"\(name)","state":"\(state)","detail":""}},
     "competitions":[{"id":"1","venue":{"fullName":"Delta Center"},
      "competitors":[
       {"homeAway":"home","score":"\(scores.1)","linescores":\(lines),
        "team":{"id":"26","abbreviation":"UTAH","displayName":"Utah Jazz","shortDisplayName":"Jazz","color":"4e008e"},
        "records":[{"type":"total","summary":"1-1"}]},
       {"homeAway":"away","score":"\(scores.0)","linescores":\(lines),
        "team":{"id":"13","abbreviation":"LAL","displayName":"Los Angeles Lakers","shortDisplayName":"Lakers"}}]}]}]}
    """.data(using: .utf8)!
}

@Suite struct ProviderTests {
    @Test func scheduledHasNoScores() throws {
        let g = try ESPNProvider.parse(payload(state: "pre", name: "STATUS_SCHEDULED", scores: ("0", "0")))[0]
        #expect(g.status == .scheduled)
        #expect(g.home.score == nil)
        #expect(g.home.team.record == "1-1")
        #expect(g.venue == "Delta Center")
        #expect(abs(g.startDate.timeIntervalSince1970 - 1_792_962_000) < 1)   // 2026-10-25T21:00Z
    }

    @Test func liveGameLabelAndLineScores() throws {
        let lines = #"[{"value":25.0},{"value":27.0}]"#
        let g = try ESPNProvider.parse(payload(state: "in", name: "STATUS_IN_PROGRESS", scores: ("52", "55"),
                                               period: 2, clock: "4:32", lines: lines))[0]
        #expect(g.status == .live)
        #expect(g.liveLabel == "Q2 4:32")
        #expect(g.home.score == 55)
        #expect(g.away.periodScores == [25, 27])
    }

    @Test func finalWinnerAndOvertimeLabels() throws {
        let g = try ESPNProvider.parse(payload(state: "post", name: "STATUS_FINAL", scores: ("100", "110")))[0]
        #expect(g.status == .final)
        #expect(g.winnerIsHome == true)
        #expect(Game.periodLabel(5) == "OT")
        #expect(Game.periodLabel(6) == "2OT")
    }

    @Test func postponedAndCancelled() throws {
        #expect(try ESPNProvider.parse(payload(state: "post", name: "STATUS_POSTPONED", scores: ("0", "0")))[0].status == .postponed)
        #expect(try ESPNProvider.parse(payload(state: "post", name: "STATUS_CANCELED", scores: ("0", "0")))[0].status == .cancelled)
    }

    @Test func malformedPayloadThrows() {
        #expect(throws: ProviderError.self) { try ESPNProvider.parse(Data("[]".utf8)) }
    }

    @Test func emptyEvents() throws {
        #expect(try ESPNProvider.parse(Data(#"{"events":[]}"#.utf8)).isEmpty)
    }
}

@Suite struct CacheTests {
    @Test func roundTripAndLimit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = ScoreCache(directory: dir)
        let games = try await DemoProvider().games(on: Date())
        for i in 0..<12 {
            cache.save(Slate(dayKey: String(format: "202610%02d", i + 1), games: games,
                             fetchedAt: Date(timeIntervalSince1970: Double(i)), providerName: "t", isDemo: false))
        }
        #expect(cache.load().count == 10)
        #expect(cache.slate(for: "20261001") == nil)
        #expect(cache.slate(for: "20261012")?.games.count == games.count)
    }
}

@Suite struct DayKeyTests {
    @Test func formatUsesGivenCalendar() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        let d = c.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 5))!
        #expect(DayKey.string(for: d, calendar: c) == "20261026")
    }

    @Test func malaysiaDaySpansTwoUSGameDays() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        let d = c.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 10))!
        // 00:00–23:59 MYT on 25 Oct = 12:00 24 Oct – 11:59 25 Oct EDT.
        #expect(ESPNProvider.usGameDays(coveringLocalDay: d, calendar: c) == ["20261024", "20261025"])
    }

    @Test func easternDayIsOneUSGameDay() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!
        let d = c.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 10))!
        #expect(ESPNProvider.usGameDays(coveringLocalDay: d, calendar: c) == ["20261025"])
    }
}

/// Serves a canned scoreboard per `dates=` value so the provider can be tested offline.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "dates" }?.value ?? ""
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.bodies[key] ?? Data(#"{"events":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct LocalDayTests {
    private func event(_ id: String, _ date: String) -> String {
        """
        {"id":"\(id)","date":"\(date)","status":{"type":{"name":"STATUS_SCHEDULED","state":"pre"}},
         "competitions":[{"competitors":[
           {"homeAway":"home","team":{"abbreviation":"UTAH","shortDisplayName":"Jazz"}},
           {"homeAway":"away","team":{"abbreviation":"LAL","shortDisplayName":"Lakers"}}]}]}
        """
    }

    @Test func keepsOnlyGamesTippingOffOnTheLocalDay() async throws {
        StubProtocol.bodies = [
            // US 24 Oct: 22:00Z = 06:00 MYT 25 Oct (keep); 00:30Z 25 Oct = 08:30 MYT 25 Oct (keep)
            "20261024": Data(#"{"events":[\#(event("a", "2026-10-24T22:00Z")),\#(event("b", "2026-10-25T00:30Z"))]}"#.utf8),
            // US 25 Oct: 21:00Z = 05:00 MYT 26 Oct (drop)
            "20261025": Data(#"{"events":[\#(event("c", "2026-10-25T21:00Z"))]}"#.utf8),
        ]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var kl = Calendar(identifier: .gregorian); kl.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        let provider = ESPNProvider(session: URLSession(configuration: config), calendar: kl)
        let day = kl.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
        let games = try await provider.games(on: day)
        #expect(Set(games.map(\.id)) == ["a", "b"])
    }
}

private struct FixedProvider: ScoreboardProvider {
    let name = "fixed"; let isDemo = false
    let games: [Game]
    func games(on date: Date) async throws -> [Game] { games }
}
private struct FailingProvider: ScoreboardProvider {
    let name = "failing"; let isDemo = false
    func games(on date: Date) async throws -> [Game] { throw URLError(.notConnectedToInternet) }
}

@MainActor @Suite(.serialized) struct StoreTests {
    private func makeStore(_ provider: ScoreboardProvider) -> (ScoreboardStore, Preferences) {
        let defaults = UserDefaults(suiteName: "nbaglass.tests.\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ScoreboardStore(prefs: prefs, cache: ScoreCache(directory: dir), provider: provider), prefs)
    }
    private func settle(_ store: ScoreboardStore) async {
        for _ in 0..<100 where store.isLoading { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test func groupsAndFiltersByStatus() async throws {
        let games = try await DemoProvider().games(on: Date())   // 1 final, 1 live, 2 scheduled
        let (store, prefs) = makeStore(FixedProvider(games: games))
        store.refresh(); await settle(store)
        #expect(store.visibleSections == [.live, .upcoming, .final])
        #expect(store.count(for: .live) == 1 && store.count(for: .upcoming) == 2 && store.count(for: .final) == 1)
        store.filter = .upcoming
        #expect(store.visibleSections == [.upcoming])
        store.filter = .all; prefs.showFinal = false
        #expect(store.visibleSections == [.live, .upcoming])
    }

    @Test func dateNavigation() {
        let (store, _) = makeStore(FixedProvider(games: []))
        store.shiftDay(1)
        #expect(!store.isToday)
        #expect(Calendar.current.isDateInTomorrow(store.selectedDate))
        store.goToToday()
        #expect(store.isToday)
    }

    @Test func midnightRolloverFollowsToday() {
        let (store, _) = makeStore(FixedProvider(games: []))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        store.calendarDayChanged(now: tomorrow)          // panel was on "today" → moves to the new day
        #expect(Calendar.current.isDate(store.selectedDate, inSameDayAs: tomorrow))
        store.shiftDay(3)
        let pinned = store.selectedDate
        store.calendarDayChanged(now: Calendar.current.date(byAdding: .day, value: 1, to: tomorrow)!)
        #expect(store.selectedDate == pinned)            // a browsed-to date is left alone
    }

    @Test func offlineFailureSetsState() async {
        let (store, _) = makeStore(FailingProvider())
        store.refresh(); await settle(store)
        #expect(store.isOffline)
        #expect(store.games.isEmpty)
        #expect(store.errorMessage == "Offline")
    }
}

@Suite struct LogoMappingTests {
    @Test func everyTeamMapsToItsOwnLogoFile() {
        for team in NBATeams.all {
            #expect(TeamLogos.url(for: team.abbr).lastPathComponent == "\(team.abbr.lowercased()).png")
        }
        #expect(Set(NBATeams.all.map(\.abbr)).count == 30)
    }
}

@Suite struct ScoreChangeTrackerTests {
    private func game(_ id: String = "g1", away: Int?, home: Int?, status: GameStatus = .live) -> Game {
        Game(id: id, startDate: Date(), status: status, statusDetail: "",
             away: GameSide(team: Team(id: "A", abbreviation: "BOS", displayName: "", shortName: ""), score: away),
             home: GameSide(team: Team(id: "H", abbreviation: "NY", displayName: "", shortName: ""), score: home))
    }
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func firstResultOnlySetsBaseline() {
        var t = ScoreChangeTracker()
        #expect(t.ingest([game(away: 98, home: 87)], dayKey: "d", at: t0).isEmpty)
    }

    @Test func detectsOnlyTheTeamThatScored() {
        var t = ScoreChangeTracker()
        _ = t.ingest([game(away: 98, home: 87)], dayKey: "d", at: t0)
        let e = t.ingest([game(away: 100, home: 87)], dayKey: "d", at: t0 + 45)
        #expect(e == [ScoringEvent(gameID: "g1", teamID: "A", points: 2)])
    }

    @Test func bothTeamsAndMultiplePointsInOneUpdate() {
        var t = ScoreChangeTracker()
        _ = t.ingest([game(away: 98, home: 87)], dayKey: "d", at: t0)
        let e = t.ingest([game(away: 103, home: 89)], dayKey: "d", at: t0 + 45)
        #expect(e == [ScoringEvent(gameID: "g1", teamID: "A", points: 5), ScoringEvent(gameID: "g1", teamID: "H", points: 2)])
    }

    @Test func unchangedDataDoesNotReplay() {
        var t = ScoreChangeTracker()
        _ = t.ingest([game(away: 98, home: 87)], dayKey: "d", at: t0)
        _ = t.ingest([game(away: 100, home: 87)], dayKey: "d", at: t0 + 45)
        #expect(t.ingest([game(away: 100, home: 87)], dayKey: "d", at: t0 + 90).isEmpty)
    }

    @Test func decreasesAndMissingScoresAreNotEvents() {
        var t = ScoreChangeTracker()
        _ = t.ingest([game(away: 100, home: 87)], dayKey: "d", at: t0)
        #expect(t.ingest([game(away: 98, home: 87)], dayKey: "d", at: t0 + 45).isEmpty)       // stat correction
        #expect(t.ingest([game(away: nil, home: 87)], dayKey: "d", at: t0 + 90).isEmpty)      // score dropped out
        #expect(t.ingest([game(away: 104, home: 87)], dayKey: "d", at: t0 + 135).isEmpty)     // reappears: new baseline
        #expect(t.ingest([game(away: 106, home: 87)], dayKey: "d", at: t0 + 180).count == 1)
    }

    @Test func dayChangeOrStaleBaselineResetsSilently() {
        var t = ScoreChangeTracker(maxBaselineAge: 600)
        _ = t.ingest([game(away: 98, home: 87)], dayKey: "d1", at: t0)
        #expect(t.ingest([game(away: 120, home: 87)], dayKey: "d2", at: t0 + 45).isEmpty)
        #expect(t.ingest([game(away: 130, home: 87)], dayKey: "d2", at: t0 + 2000).isEmpty)  // e.g. after sleep
        t.reset()
        #expect(t.ingest([game(away: 140, home: 87)], dayKey: "d2", at: t0 + 2045).isEmpty)
    }

    @Test func newGameAppearingIsNotAnEvent() {
        var t = ScoreChangeTracker()
        _ = t.ingest([game(away: 98, home: 87)], dayKey: "d", at: t0)
        #expect(t.ingest([game(away: 98, home: 87), game("g2", away: 10, home: 12)], dayKey: "d", at: t0 + 45).isEmpty)
    }
}

/// Serves a scripted sequence of slates, or fails, so store-level scoring can be tested.
private actor Script {
    var steps: [Result<[Game], URLError>]
    init(_ steps: [Result<[Game], URLError>]) { self.steps = steps }
    func next() -> Result<[Game], URLError> { steps.count > 1 ? steps.removeFirst() : steps[0] }
}
private struct ScriptedProvider: ScoreboardProvider {
    let name = "scripted"; let isDemo = false
    let script: Script
    func games(on date: Date) async throws -> [Game] { try await script.next().get() }
}

@MainActor @Suite(.serialized) struct StoreScoringTests {
    private func g(_ away: Int, _ home: Int) -> Game {
        Game(id: "g1", startDate: Date(), status: .live, statusDetail: "",
             away: GameSide(team: Team(id: "A", abbreviation: "BOS", displayName: "", shortName: ""), score: away),
             home: GameSide(team: Team(id: "H", abbreviation: "NY", displayName: "", shortName: ""), score: home))
    }
    private func settle(_ s: ScoreboardStore) async {
        try? await Task.sleep(nanoseconds: 5_000_000)
        for _ in 0..<100 where s.isLoading { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test func cacheLaunchFailureAndDateChangeNeverCelebrate() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = ScoreCache(directory: dir)
        // Old cached slate with lower scores than the first live fetch.
        cache.save(Slate(dayKey: DayKey.string(for: Date()), games: [g(80, 70)], fetchedAt: Date(timeIntervalSinceNow: -3600),
                         providerName: "t", isDemo: false))
        let script = Script([.success([g(98, 87)]), .failure(URLError(.timedOut)), .success([g(100, 87)]),
                             .success([g(100, 87)]), .success([g(110, 95)])])
        let prefs = Preferences(defaults: UserDefaults(suiteName: "nbaglass.tests.\(UUID().uuidString)")!)
        let store = ScoreboardStore(prefs: prefs, cache: cache, provider: ScriptedProvider(script: script))
        let token = { store.pulses.token(gameID: "g1", teamID: "A") }

        store.refresh(); await settle(store)          // launch: cached 80 → live 98 must not celebrate
        #expect(store.games.first?.away.score == 98 && token() == 0)
        store.refresh(); await settle(store)          // network failure: no event
        #expect(store.isOffline && token() == 0)
        store.refresh(); await settle(store)          // 98 → 100: away team only
        #expect(store.lastScoringEvents == [ScoringEvent(gameID: "g1", teamID: "A", points: 2)])
        let afterFirst = token()
        #expect(afterFirst > 0 && store.pulses.token(gameID: "g1", teamID: "H") == 0)
        store.filter = .final; store.filter = .all    // filters don't touch scoring state
        store.refresh(); await settle(store)          // unchanged data: no replay
        #expect(store.lastScoringEvents.isEmpty && token() == afterFirst)
        store.shiftDay(1); await settle(store)        // date change resets silently
        #expect(store.lastScoringEvents.isEmpty && token() == 0)
    }
}

@MainActor @Suite(.serialized) struct PerformanceBehaviourTests {
    private func makeStore(_ provider: ScoreboardProvider) -> ScoreboardStore {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "nbaglass.tests.\(UUID().uuidString)")!)
        prefs.refreshInterval = 45
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ScoreboardStore(prefs: prefs, cache: ScoreCache(directory: dir), provider: provider)
    }
    private func settle(_ s: ScoreboardStore) async {
        try? await Task.sleep(nanoseconds: 5_000_000)
        for _ in 0..<100 where s.isLoading { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    @Test func pollIntervalFollowsWhatCanChange() async throws {
        let scheduled = try await DemoProvider().games(on: Date()).filter { $0.status != .live }
        let store = makeStore(FixedProvider(games: scheduled))
        store.refresh(); await settle(store)
        #expect(store.currentInterval == 180)          // today, nothing live
        store.shiftDay(-1); await settle(store)
        #expect(store.currentInterval == 1800)         // past day
        store.shiftDay(2); await settle(store)
        #expect(store.currentInterval == 900)          // future day
        let live = makeStore(FixedProvider(games: try await DemoProvider().games(on: Date())))
        live.refresh(); await settle(live)
        #expect(live.currentInterval == 45)            // a game is live
    }

    @Test func unchangedBackgroundPollOnlyUpdatesTimestamp() async throws {
        let store = makeStore(FixedProvider(games: try await DemoProvider().games(on: Date())))
        store.refresh(); await settle(store)
        var changes = 0
        let sub = store.objectWillChange.sink { changes += 1 }
        store.refresh(userInitiated: false); await settle(store)
        sub.cancel()
        #expect(changes == 1)                          // lastUpdated only: no games/loading/flag churn
        #expect(!store.isLoading)
    }

    @Test func cacheServesFromMemoryAndWritesInBackground() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = ScoreCache(directory: dir)
        cache.save(Slate(dayKey: "20261025", games: [], fetchedAt: Date(), providerName: "t", isDemo: false))
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("scores-cache-v2.json").path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(ScoreCache(directory: dir).slate(for: "20261025") != nil)   // landed on disk
        try FileManager.default.removeItem(at: dir.appendingPathComponent("scores-cache-v2.json"))
        #expect(cache.slate(for: "20261025") != nil)                        // served from memory
    }
}
