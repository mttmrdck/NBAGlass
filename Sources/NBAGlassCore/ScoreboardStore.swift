import Foundation
import Combine
import os

/// Per-team celebration triggers. Kept apart from the store so a scoring event only re-renders
/// the score segments that observe it. A token changes exactly once per detected scoring event.
@MainActor
public final class ScoringPulses: ObservableObject {
    @Published public private(set) var tokens: [String: Int] = [:]
    private var counter = 0
    public init() {}

    public func token(gameID: String, teamID: String) -> Int {
        tokens[ScoreChangeTracker.key(gameID: gameID, teamID: teamID)] ?? 0
    }
    func fire(_ events: [ScoringEvent]) {
        guard !events.isEmpty else { return }
        var t = tokens
        for e in events { counter += 1; t[ScoreChangeTracker.key(gameID: e.gameID, teamID: e.teamID)] = counter }
        tokens = t
    }
    func clear() { if !tokens.isEmpty { tokens = [:] } }
}

@MainActor
public final class ScoreboardStore: ObservableObject {
    @Published public var selectedDate: Date
    @Published public var filter: GameFilter
    @Published public private(set) var games: [Game] = []
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isOffline = false
    @Published public private(set) var isStale = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isDemo = false
    @Published public var expandedGameID: String?
    @Published public var collapsedSections: Set<GameSection> = []

    public let prefs: Preferences
    public let pulses = ScoringPulses()
    /// Most recent scoring events, for diagnostics and tests.
    public private(set) var lastScoringEvents: [ScoringEvent] = []
    private var tracker = ScoreChangeTracker()
    private let log = Logger(subsystem: "com.nbaglass.app", category: "scoring")
    private let cache: ScoreCache
    private let liveProvider: ScoreboardProvider
    private let demoProvider: ScoreboardProvider
    private var fetchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    /// Day/provider currently on screen; cached data is only restored when this changes.
    private var displayedKey: String?
    private var cancellables = Set<AnyCancellable>()

    public init(prefs: Preferences, cache: ScoreCache = ScoreCache(),
                provider: ScoreboardProvider = ESPNProvider(),
                demoProvider: ScoreboardProvider = DemoProvider()) {
        self.prefs = prefs; self.cache = cache
        self.liveProvider = provider; self.demoProvider = demoProvider
        self.filter = prefs.defaultFilter
        self.selectedDate = Calendar.current.date(byAdding: .day, value: prefs.defaultDay.offset, to: Date())!
        self.isDemo = prefs.useDemoData

        // Switching between live and demo data reloads immediately.
        prefs.$useDemoData.dropFirst().removeDuplicates().sink { [weak self] (_: Bool) in
            DispatchQueue.main.async { self?.resetScoring(); self?.refresh() }
        }.store(in: &cancellables)
        // At local midnight, a panel that was showing "today" moves on to the new day.
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.calendarDayChanged() } }
            .store(in: &cancellables)
    }

    func calendarDayChanged(now: Date = Date()) {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        guard Calendar.current.isDate(selectedDate, inSameDayAs: yesterday) else { return }
        selectedDate = now
        selectionChanged()
    }

    private var provider: ScoreboardProvider { prefs.useDemoData ? demoProvider : liveProvider }

    // MARK: Date navigation
    public func shiftDay(_ delta: Int) {
        selectedDate = Calendar.current.date(byAdding: .day, value: delta, to: selectedDate)!
        selectionChanged()
    }
    public func goToToday() { selectedDate = Date(); selectionChanged() }
    public func select(date: Date) { selectedDate = date; selectionChanged() }
    public var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }

    private func resetScoring() { tracker.reset(); pulses.clear(); lastScoringEvents = [] }

    private func selectionChanged() {
        resetScoring()
        expandedGameID = nil
        consecutiveFailures = 0
        refresh()
    }

    // MARK: Derived
    public var hasLiveGames: Bool { games.contains { $0.status == .live } }

    public func visibleGames(in section: GameSection) -> [Game] {
        games.filter { GameSection($0.status) == section }
            .filter { _ in prefs.showFinal || section != .final }
            .sorted { a, b in
                let fa = a.involves(prefs.favourites), fb = b.involves(prefs.favourites)
                if fa != fb { return fa }
                return section == .final ? a.startDate > b.startDate : a.startDate < b.startDate
            }
    }

    public var visibleSections: [GameSection] {
        let allowed: [GameSection]
        switch filter {
        case .all: allowed = GameSection.allCases
        case .live: allowed = [.live]
        case .upcoming: allowed = [.upcoming, .other]
        case .final: allowed = [.final]
        }
        return allowed.filter { !visibleGames(in: $0).isEmpty }
    }

    public func count(for filter: GameFilter) -> Int {
        switch filter {
        case .all: return GameSection.allCases.reduce(0) { $0 + visibleGames(in: $1).count }
        case .live: return visibleGames(in: .live).count
        case .upcoming: return visibleGames(in: .upcoming).count + visibleGames(in: .other).count
        case .final: return visibleGames(in: .final).count
        }
    }

    // MARK: Fetching
    /// Assigns only when the value differs, so unchanged data never publishes a redraw.
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<ScoreboardStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Cancels any in-flight request and fetches. When the day (or provider) changes, cached data for
    /// it is shown immediately. Background polls (`userInitiated: false`) don't toggle the loading
    /// state, so an unchanged result causes no visible update beyond the timestamp.
    public func refresh(userInitiated: Bool = true, caller: String = #function) {
        log.debug("refresh from \(caller, privacy: .public) user=\(userInitiated, privacy: .public)")
        fetchTask?.cancel()
        let date = selectedDate
        let key = DayKey.string(for: date)
        let provider = self.provider
        let demo = provider.isDemo
        update(\.isDemo, demo)

        let shownKey = "\(key)|\(demo)"
        if displayedKey != shownKey {
            displayedKey = shownKey
            if let cached = cache.slate(for: key), cached.isDemo == demo {
                games = cached.games; lastUpdated = cached.fetchedAt
                isStale = true
            } else {
                games = []; lastUpdated = nil
            }
        }
        if userInitiated || games.isEmpty { update(\.isLoading, true) }

        fetchTask = Task { [weak self] in
            do {
                let fetched = try await provider.games(on: date)
                try Task.checkCancellation()
                guard let self else { return }
                let slate = Slate(dayKey: key, games: fetched, fetchedAt: Date(),
                                  providerName: provider.name, isDemo: demo)
                if !demo { self.cache.save(slate) }
                let events = self.tracker.ingest(fetched, dayKey: key)
                self.log.debug("fetched \(fetched.count) games, \(events.count) scoring events")
                self.lastScoringEvents = events
                for e in events { self.log.notice("score +\(e.points) game=\(e.gameID, privacy: .public) team=\(e.teamID, privacy: .public)") }
                self.update(\.games, fetched)
                self.lastUpdated = slate.fetchedAt
                self.pulses.fire(events)
                self.update(\.isStale, false); self.update(\.isOffline, false); self.update(\.errorMessage, nil)
                self.consecutiveFailures = 0
                self.update(\.isLoading, false)
            } catch is CancellationError {
                return
            } catch let e as URLError where e.code == .cancelled {
                return
            } catch {
                guard let self else { return }
                self.consecutiveFailures += 1
                self.update(\.isStale, !self.games.isEmpty)
                if let u = error as? URLError,
                   [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                    .cannotConnectToHost, .dnsLookupFailed, .timedOut].contains(u.code) {
                    self.update(\.isOffline, true)
                    self.update(\.errorMessage, "Offline")
                } else {
                    self.update(\.isOffline, false)
                    self.update(\.errorMessage, error.localizedDescription)
                }
                self.update(\.isLoading, false)
            }
        }
    }

    // MARK: Polling
    /// The user's interval while games are live; 3 min today with nothing live; 15 min for future
    /// days and 30 min for past days (their games can't change often). Doubles per consecutive
    /// failure (max 8x).
    public var currentInterval: TimeInterval {
        let base = max(15, prefs.refreshInterval)
        let idle: TimeInterval
        if hasLiveGames { idle = base }
        else if isToday { idle = max(base, 180) }
        else if selectedDate < Date() { idle = max(base, 1800) }
        else { idle = max(base, 900) }
        return idle * pow(2, Double(min(consecutiveFailures, 3)))
    }

    /// Starts (or resumes) polling. Fetches immediately only if the data is older than one interval.
    public func startPolling() {
        pollTask?.cancel()
        refreshIfStale()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.currentInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                self?.refresh(userInitiated: false)
            }
        }
    }

    public func stopPolling() { pollTask?.cancel(); pollTask = nil; fetchTask?.cancel(); update(\.isLoading, false) }

    /// Refresh only if the data is older than one polling interval (or is cached from an earlier run).
    public func refreshIfStale() {
        if displayedKey != nil, !isStale, let t = lastUpdated, Date().timeIntervalSince(t) < currentInterval { return }
        refresh(userInitiated: false)
    }
}
