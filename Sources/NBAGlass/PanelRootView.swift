import SwiftUI
import AppKit
import NBAGlassCore

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}
private extension View {
    /// Contributes this view's height to the panel's desired height.
    func reportsHeight() -> some View {
        background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
    }
}

/// Window-level actions the panel's own controls can trigger.
struct PanelActions {
    var openSettings: () -> Void
    var dockToRightEdge: () -> Void
}

struct PanelRootView: View {
    @EnvironmentObject var store: ScoreboardStore
    @EnvironmentObject var prefs: Preferences
    @StateObject private var logos = LogoStore.shared
    var actions: PanelActions
    /// Called with the height the panel would need to show everything without scrolling.
    var onDesiredHeight: (CGFloat) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            GlassBackground()
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    HeaderView(actions: actions)
                    FilterBar().padding(.horizontal, 10).padding(.bottom, 4)
                }
                .reportsHeight()
                ScoreList()
                FeaturedStrip()
                    .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
                    .reportsHeight()
            }
        }
        .onPreferenceChange(HeightKey.self) { h in onDesiredHeight(ceil(h)) }
        .environmentObject(logos)
        .environmentObject(store.pulses)
        .preferredColorScheme(.dark)
        .onAppear { logos.prefetchAll() }
    }
}

// MARK: Header

struct HeaderView: View {
    @EnvironmentObject var store: ScoreboardStore
    @EnvironmentObject var prefs: Preferences
    @State private var showPicker = false
    var actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                LeagueLogo(height: 26)
                Text("NBA").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary)
                if store.isDemo { Tag(text: "DEMO") }
                SyncIndicator()
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.clockwise", help: refreshHelp) { store.refresh() }
                    .opacity(store.isLoading ? 0.45 : 1)
                IconButton(symbol: "gearshape", help: "Settings", action: actions.openSettings)
                Menu {
                    Button("Today") { store.goToToday() }
                    Divider()
                    Button("Dock to Right Edge", action: actions.dockToRightEdge)
                    Button("Hide Scoreboard") { prefs.panelVisible = false }
                    Divider()
                    Button("Quit NBAGlass") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 26, height: 24).hoverHighlight()
                .help("More")
            }
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", help: "Previous day") { store.shiftDay(-1) }
                Button { showPicker.toggle() } label: {
                    Text(store.selectedDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 6).padding(.vertical, 2).hoverHighlight()
                }
                .buttonStyle(.plain)
                .help("Times in \(TimeZone.current.identifier) (\(TimeZone.current.abbreviation() ?? ""))")
                .popover(isPresented: $showPicker) {
                    DatePicker("", selection: Binding(get: { store.selectedDate },
                                                      set: { store.select(date: $0); showPicker = false }),
                               displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden().padding(8)
                }
                IconButton(symbol: "chevron.right", help: "Next day") { store.shiftDay(1) }
                Spacer()
                if !store.isToday {
                    Button("Today") { store.goToToday() }
                        .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.accent).padding(.horizontal, 7).padding(.vertical, 3).hoverHighlight()
                }
            }
            .padding(.leading, 6)
        }
        .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 8)
        .background(WindowDragArea())
    }

    private var refreshHelp: String {
        guard let t = store.lastUpdated else { return "Refresh" }
        return "Refresh — updated \(t.formatted(date: .omitted, time: .shortened))"
    }
}

/// Only visible when something is wrong (offline / failed / showing cached data).
struct SyncIndicator: View {
    @EnvironmentObject var store: ScoreboardStore
    var body: some View {
        if store.isOffline || store.errorMessage != nil {
            HStack(spacing: 3) {
                Image(systemName: store.isOffline ? "wifi.slash" : "exclamationmark.triangle.fill")
                Text(label)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Color.orange.opacity(0.9))
            .help(store.errorMessage ?? "")
        }
    }
    private var label: String {
        let cached = store.lastUpdated.map { " · \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return (store.isOffline ? "Offline" : "Update failed") + cached
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 8.5, weight: .bold)).tracking(0.6)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.10)))
    }
}

struct IconButton: View {
    let symbol: String; var help: String = ""; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 24).hoverHighlight()
        }
        .buttonStyle(.plain).help(help)
    }
}

// MARK: Filters

struct FilterBar: View {
    @EnvironmentObject var store: ScoreboardStore
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            ForEach(GameFilter.allCases) { f in
                let selected = store.filter == f
                Button {
                    withAnimation(.snappy(duration: 0.22)) { store.filter = f }
                } label: {
                    Text(f.rawValue)
                        .font(.system(size: 10.5, weight: .medium)).tracking(0.3)
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background {
                            if selected {
                                Capsule().fill(LinearGradient(colors: [Theme.accent.opacity(0.38), Theme.accent.opacity(0.20)],
                                                              startPoint: .top, endPoint: .bottom))
                                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.60), lineWidth: 0.75))
                                    .shadow(color: Theme.accent.opacity(0.25), radius: 4)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2.5)
        .background(Capsule().fill(Color.black.opacity(0.18)))
        .overlay(Capsule().strokeBorder(Theme.edge.opacity(0.24), lineWidth: 0.75))
    }
}

// MARK: List

struct ScoreList: View {
    @EnvironmentObject var store: ScoreboardStore

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                let sections = store.visibleSections
                if sections.isEmpty {
                    EmptyState().padding(.vertical, 26)
                } else {
                    ForEach(sections) { SectionBlock(section: $0) }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            .reportsHeight()
        }
    }
}

struct SectionBlock: View {
    @EnvironmentObject var store: ScoreboardStore
    let section: GameSection

    private var dot: Color {
        switch section {
        case .live: return Theme.live
        case .upcoming: return Theme.upcoming
        case .final: return Theme.finished
        case .other: return .orange
        }
    }

    var body: some View {
        let games = store.visibleGames(in: section)
        let collapsed = store.collapsedSections.contains(section)

        VStack(spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    if collapsed { store.collapsedSections.remove(section) } else { store.collapsedSections.insert(section) }
                }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(dot).frame(width: 6, height: 6)
                        .shadow(color: section == .live ? Theme.live.opacity(0.6) : .clear, radius: 3)
                    Text(section == .other ? "POSTPONED" : section.rawValue.uppercased())
                        .font(.system(size: 11.5, weight: .medium)).tracking(0.3).foregroundStyle(Theme.textPrimary.opacity(0.88))
                    Text("\(games.count)").font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.10)))
                    Spacer()
                    if collapsed {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 6).padding(.top, 9).padding(.bottom, 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show \(section.rawValue)" : "Hide \(section.rawValue)")

            if !collapsed {
                ForEach(games) { game in
                    let selected = store.expandedGameID == game.id
                    MatchupStrip(game: game, selected: selected) {
                        withAnimation(.snappy(duration: 0.25)) { store.expandedGameID = selected ? nil : game.id }
                    }
                    .equatable()
                    .transition(.opacity)
                }
            }
        }
    }
}

struct EmptyState: View {
    @EnvironmentObject var store: ScoreboardStore
    var body: some View {
        VStack(spacing: 6) {
            if store.isLoading && store.games.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: store.isOffline ? "wifi.slash" : (store.errorMessage != nil ? "exclamationmark.triangle" : "calendar"))
                    .font(.system(size: 17, weight: .light)).foregroundStyle(Theme.textTertiary)
            }
            Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            if let sub = subtitle {
                Text(sub).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).lineLimit(3)
            }
            if store.games.isEmpty && store.errorMessage != nil && !store.isLoading {
                Button("Retry") { store.refresh() }
                    .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3).hoverHighlight()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
    private var message: String {
        if store.isLoading && store.games.isEmpty { return "Loading games…" }
        if store.games.isEmpty { return store.errorMessage == nil ? "No games scheduled" : "Couldn't load games" }
        switch store.filter {
        case .live: return "No live games"
        case .upcoming: return "Nothing upcoming"
        case .final: return "No final scores yet"
        case .all: return "No games to show"
        }
    }
    private var subtitle: String? {
        if store.games.isEmpty, let e = store.errorMessage { return e }
        if store.games.isEmpty && !store.isLoading { return "Try another date." }
        return nil
    }
}

// MARK: Featured strip

/// The compact strip pinned to the bottom: the selected game, else the first live game, else the
/// latest final, else the next tip-off — always from real data.
struct FeaturedStrip: View {
    @EnvironmentObject var store: ScoreboardStore

    private var game: Game? {
        let games = store.games
        if let id = store.expandedGameID, let g = games.first(where: { $0.id == id }) { return g }
        if let g = games.filter({ $0.status == .live }).min(by: { $0.startDate < $1.startDate }) { return g }
        if let g = games.filter({ $0.status == .final }).max(by: { $0.startDate < $1.startDate }) { return g }
        return games.filter { $0.status == .scheduled }.min { $0.startDate < $1.startDate }
    }

    var body: some View {
        if let g = game {
            let awayP = TeamPalette(g.away.team), homeP = TeamPalette(g.home.team)
            let shape = RoundedRectangle(cornerRadius: Theme.stripCorner, style: .continuous)
            HStack(spacing: 0) {
                LeagueLogo(height: 20).frame(width: 30)
                Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 22)
                mini(g, g.away, awayP)
                Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 22)
                mini(g, g.home, homeP)
                Group {
                    if g.status == .live {
                        VStack(spacing: 0) {
                            Text(StatusText.period(g)).font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.live)
                            if let c = StatusText.clock(g) { Text(c).font(.system(size: 9.5, weight: .semibold).monospacedDigit()) }
                        }
                    } else if g.status == .scheduled {
                        Text(g.startDate.formatted(date: .omitted, time: .shortened)).font(.system(size: 9.5, weight: .semibold))
                    } else {
                        Text(StatusText.final(g)).font(.system(size: 8.5, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 60)
            }
            .frame(height: 36)
            .background {
                ZStack {
                    Color.black.opacity(0.16)
                    LinearGradient(colors: [.clear, awayP.tint.opacity(0.28), awayP.tint.opacity(0.10), homeP.tint.opacity(0.28), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.edge.opacity(0.30), lineWidth: 0.75))
            .help("\(g.away.team.displayName) at \(g.home.team.displayName)")
            .animation(.snappy(duration: 0.25), value: g.id)
        }
    }

    private func mini(_ g: Game, _ side: GameSide, _ p: TeamPalette) -> some View {
        HStack(spacing: 6) {
            TeamLogo(abbreviation: side.team.abbreviation, size: 22)
            Text(side.team.abbreviation).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 2)
            if let s = side.score {
                AnimatedScore(value: s, gameID: g.id, teamID: side.team.id, size: 14, weight: .bold)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }
}
