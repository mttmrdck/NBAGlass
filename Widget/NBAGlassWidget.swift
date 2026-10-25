import WidgetKit
import SwiftUI
import NBAGlassCore

// Source for the WidgetKit extension target (see README → "Widget"). It reads the same
// cache file the app writes (App Group container) and never hits the network itself.

struct ScoreEntry: TimelineEntry {
    let date: Date
    let games: [Game]
    let updated: Date?
}

struct ScoreProvider: TimelineProvider {
    private func load() -> ScoreEntry {
        let cache = ScoreCache().load()
        // Prefer today's slate; otherwise the most recently fetched one.
        let slate = cache[DayKey.string(for: Date())] ?? cache.values.max { $0.fetchedAt < $1.fetchedAt }
        return ScoreEntry(date: Date(), games: Self.relevant(slate?.games ?? []), updated: slate?.fetchedAt)
    }

    /// Live games first, then next upcoming, then latest finals.
    static func relevant(_ games: [Game]) -> [Game] {
        let live = games.filter { $0.status == .live }
        let next = games.filter { $0.status == .scheduled }.sorted { $0.startDate < $1.startDate }
        let done = games.filter { $0.status == .final }.sorted { $0.startDate > $1.startDate }
        return live + next + done
    }

    func placeholder(in context: Context) -> ScoreEntry {
        let t = Team(id: "x", abbreviation: "---", displayName: "Team", shortName: "Team")
        let g = Game(id: "p", startDate: Date(), status: .scheduled, statusDetail: "",
                     away: GameSide(team: t), home: GameSide(team: t))
        return ScoreEntry(date: Date(), games: [g], updated: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (ScoreEntry) -> Void) { completion(load()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScoreEntry>) -> Void) {
        let entry = load()
        // WidgetKit budgets refreshes: ask for ~5 min while something is live, otherwise ~20 min.
        let minutes = entry.games.contains { $0.status == .live } ? 5 : 20
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(Double(minutes) * 60))))
    }
}

struct GameLine: View {
    let game: Game
    var body: some View {
        Link(destination: URL(string: "nbaglass://game/\(game.id)")!) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(game.away.team.abbreviation)  \(game.away.score.map(String.init) ?? "")")
                    Text("\(game.home.team.abbreviation)  \(game.home.score.map(String.init) ?? "")")
                }
                .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                Spacer()
                Text(status).font(.caption2.weight(.semibold))
                    .foregroundStyle(game.status == .live ? Color.red : Color.secondary)
            }
        }
    }
    private var status: String {
        switch game.status {
        case .live: return game.liveLabel
        case .scheduled: return game.startDate.formatted(date: .omitted, time: .shortened)
        case .final: return "FINAL"
        case .postponed: return "PPD"
        case .cancelled: return "CANC"
        case .unknown: return ""
        }
    }
}

struct NBAGlassWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: ScoreEntry

    var body: some View {
        let limit = family == .systemSmall ? 1 : 3
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "basketball.fill")
                Text("NBA").font(.caption.weight(.bold))
                Spacer()
                if let u = entry.updated {
                    Text(u, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if entry.games.isEmpty {
                Spacer()
                Text("No games to show").font(.footnote).foregroundStyle(.secondary)
                Text("Open NBAGlass to load scores").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            } else {
                ForEach(entry.games.prefix(limit)) { GameLine(game: $0) }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct NBAGlassWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NBAGlassWidget", provider: ScoreProvider()) {
            NBAGlassWidgetView(entry: $0)
        }
        .configurationDisplayName("NBA Scores")
        .description("Live, next and latest NBA games from NBAGlass.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
