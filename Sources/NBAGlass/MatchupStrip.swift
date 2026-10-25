import SwiftUI
import NBAGlassCore

/// Strip geometry shared by the regions, separators and content.
enum StripMetrics {
    static let centerWidth: CGFloat = 66
    /// Horizontal run of each angled separator across the strip's height.
    static let slant: CGFloat = 10
}

/// One of the three glass regions of a matchup strip, split by two parallel angled separators.
struct StripRegion: Shape {
    enum Kind { case away, center, home }
    let kind: Kind

    func path(in r: CGRect) -> Path {
        let half = StripMetrics.centerWidth / 2, s = StripMetrics.slant / 2
        let l = r.midX - half, rr = r.midX + half
        var p = Path()
        switch kind {
        case .away:   p.addLines([r.origin, CGPoint(x: l + s, y: r.minY), CGPoint(x: l - s, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
        case .center: p.addLines([CGPoint(x: l + s, y: r.minY), CGPoint(x: rr + s, y: r.minY), CGPoint(x: rr - s, y: r.maxY), CGPoint(x: l - s, y: r.maxY)])
        case .home:   p.addLines([CGPoint(x: rr + s, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: rr - s, y: r.maxY)])
        }
        p.closeSubpath()
        return p
    }
}

/// The angled line between a team region and the centre segment.
struct StripSeparator: Shape {
    let side: StripRegion.Kind   // .away = left separator, .home = right separator
    func path(in r: CGRect) -> Path {
        let x = side == .away ? r.midX - StripMetrics.centerWidth / 2 : r.midX + StripMetrics.centerWidth / 2
        let s = StripMetrics.slant / 2
        var p = Path()
        p.move(to: CGPoint(x: x + s, y: r.minY)); p.addLine(to: CGPoint(x: x - s, y: r.maxY))
        return p
    }
}

// MARK: - Strip

/// Takes plain values (no store observation) and is Equatable, so a poll or a change to another
/// game never re-renders this row — only its own game data or selection does.
struct MatchupStrip: View, Equatable {
    let game: Game
    let selected: Bool
    let onTap: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.game == b.game && a.selected == b.selected }

    private var height: CGFloat { game.status == .live ? 46 : 41 }

    var body: some View {
        let awayP = TeamPalette(game.away.team), homeP = TeamPalette(game.home.team)
        let shape = RoundedRectangle(cornerRadius: Theme.stripCorner, style: .continuous)
        VStack(spacing: 0) {
            Button(action: onTap) {
                ZStack {
                    StripGlass(game: game, away: awayP, home: homeP)
                    ScoringBurst(gameID: game.id, teamID: game.away.team.id, color: awayP.accent, region: .away)
                    ScoringBurst(gameID: game.id, teamID: game.home.team.id, color: homeP.accent, region: .home)
                    HStack(spacing: 0) {
                        TeamSegment(game: game, side: game.away, edge: .leading, palette: awayP)
                        StatusSegment(game: game).frame(width: StripMetrics.centerWidth)
                        TeamSegment(game: game, side: game.home, edge: .trailing, palette: homeP)
                    }
                }
                .frame(height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected && GameDetail.hasContent(game) {
                GameDetail(game: game).transition(.opacity)
            }
        }
        .background(Color.black.opacity(selected ? 0.22 : 0))
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected
            ? AnyShapeStyle(Theme.accent.opacity(0.65))
            : AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.06)],
                                           startPoint: .top, endPoint: .bottom)),
            lineWidth: selected ? 1 : 0.75))
    }
}

/// Layered glass for one strip: team-tinted regions, smoked centre, logo watermarks,
/// angled glowing separators and a soft top reflection. Static — redrawn only when the game changes.
struct StripGlass: View {
    let game: Game; let away: TeamPalette; let home: TeamPalette

    var body: some View {
        ZStack {
            // Translucent team-tinted glass: thin smoke plus semi-transparent team colour, so the
            // panel's wallpaper sampling still shows through each region.
            Color.black.opacity(0.06)
            StripRegion(kind: .away).fill(LinearGradient(colors: [away.tint.opacity(0.34), away.tint.opacity(0.17), away.tint.opacity(0.05)],
                                                         startPoint: .leading, endPoint: .trailing))
            StripRegion(kind: .home).fill(LinearGradient(colors: [home.tint.opacity(0.05), home.tint.opacity(0.17), home.tint.opacity(0.34)],
                                                         startPoint: .leading, endPoint: .trailing))
            // Recessed centre: darker glass with a shadowed top edge.
            StripRegion(kind: .center).fill(Color.black.opacity(0.40))
            StripRegion(kind: .center).fill(LinearGradient(colors: [.black.opacity(0.28), .clear],
                                                           startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)))
            HStack(spacing: 0) {
                LogoWatermark(abbreviation: game.away.team.abbreviation).offset(x: -14)
                Spacer(minLength: 0)
                LogoWatermark(abbreviation: game.home.team.abbreviation).offset(x: 14)
            }
            // Reflection on the upper half, slight falloff at the bottom.
            LinearGradient(stops: [.init(color: .white.opacity(0.11), location: 0), .init(color: .white.opacity(0.02), location: 0.40),
                                   .init(color: .clear, location: 0.46), .init(color: .black.opacity(0.16), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            // Separator glow is a wide faint stroke under the sharp line — no blurred shadow pass.
            ForEach([(StripRegion.Kind.away, away.accent), (.home, home.accent)], id: \.0) { side, accent in
                StripSeparator(side: side).stroke(accent.opacity(0.22), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                StripSeparator(side: side)
                    .stroke(LinearGradient(colors: [accent, accent.opacity(0.35)], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct LogoWatermark: View {
    @EnvironmentObject var logos: LogoStore
    let abbreviation: String
    var body: some View {
        // No text fallback: without the real logo there is simply no watermark.
        // Pre-blurred at decode time (LogoStore), so no blur filter runs while drawing.
        if let img = logos.team(abbreviation)?.watermark {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 86, height: 86)
                .opacity(0.17)
        }
    }
}

// MARK: - Segments

/// Logo, abbreviation and score for one team, mirrored for the home side so scores meet the centre.
struct TeamSegment: View {
    let game: Game; let side: GameSide; let edge: HorizontalEdge; let palette: TeamPalette

    private var isWinner: Bool { edge == .leading ? game.winnerIsHome == false : game.winnerIsHome == true }
    private var dimmed: Bool { game.status == .final && game.winnerIsHome != nil && !isWinner }

    var body: some View {
        HStack(spacing: 7) {
            if edge == .leading {
                logo; abbreviation; Spacer(minLength: 2); score
            } else {
                score; Spacer(minLength: 2); abbreviation; logo
            }
        }
        .padding(edge == .leading ? .leading : .trailing, 8)
        .padding(edge == .leading ? .trailing : .leading, StripMetrics.slant / 2 + 7)
        .frame(maxWidth: .infinity)
    }

    private var logo: some View {
        TeamLogo(abbreviation: side.team.abbreviation, size: 30)
    }
    private var abbreviation: some View {
        Text(side.team.abbreviation)
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(Theme.textPrimary.opacity(dimmed ? 0.62 : 1))
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            .lineLimit(1).fixedSize()
    }
    @ViewBuilder private var score: some View {
        if let s = side.score {
            AnimatedScore(value: s, gameID: game.id, teamID: side.team.id,
                          weight: dimmed ? .medium : .bold, alignment: edge == .leading ? .trailing : .leading)
                .opacity(dimmed ? 0.62 : 1)
        }
    }
}

/// Period + clock, tip-off time, or FINAL.
struct StatusSegment: View {
    let game: Game
    var body: some View {
        VStack(spacing: 1) {
            switch game.status {
            case .live:
                HStack(spacing: 3) {
                    Circle().fill(Theme.live).frame(width: 4, height: 4)
                    Text(StatusText.period(game)).font(.system(size: 8.5, weight: .bold)).tracking(0.5)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let clock = StatusText.clock(game) {
                    Text(clock).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText()).animation(.easeOut(duration: 0.25), value: clock)
                }
            case .scheduled:
                Text(game.startDate.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            case .final:
                Text(StatusText.final(game)).font(.system(size: 8.5, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Theme.textSecondary)
            case .postponed, .cancelled, .unknown:
                Text(game.status == .postponed ? "PPD" : (game.status == .cancelled ? "CXL" : "TBD"))
                    .font(.system(size: 8.5, weight: .bold)).tracking(0.5).foregroundStyle(.orange.opacity(0.9))
                    .help(game.statusDetail)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

enum StatusText {
    /// "4TH", "OT", "2OT", "HALF", "END 3RD".
    static func period(_ g: Game) -> String {
        let l = g.liveLabel
        if l == "Halftime" { return "HALF" }
        guard let p = g.period, p > 0 else { return "LIVE" }
        let name: String
        switch p {
        case 1: name = "1ST"; case 2: name = "2ND"; case 3: name = "3RD"; case 4: name = "4TH"
        default: name = Game.periodLabel(p)
        }
        return l.hasPrefix("End ") ? "END \(name)" : name
    }
    static func clock(_ g: Game) -> String? {
        if g.liveLabel == "Halftime" || g.liveLabel.hasPrefix("End ") { return nil }
        return g.clock.flatMap { $0.isEmpty ? nil : $0 }
    }
    static func final(_ g: Game) -> String {
        g.statusDetail.lowercased().contains("ot") ? "FINAL/OT" : "FINAL"
    }
}

// MARK: - Score animation

/// A score that rolls its digits when the value changes and gives a short spring pulse when
/// the team scores. Fixed-width, monospaced digits so neighbouring content never shifts.
struct AnimatedScore: View {
    @EnvironmentObject var pulses: ScoringPulses
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Int; let gameID: String; let teamID: String
    var size: CGFloat = 16
    var weight: Font.Weight = .bold
    var alignment: Alignment = .trailing

    var body: some View {
        let reduceMotion = self.reduceMotion
        return Text("\(value)")
            .font(.system(size: size, weight: weight).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(value)))
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.8), value: value)
            .keyframeAnimator(initialValue: 1.0, trigger: pulses.token(gameID: gameID, teamID: teamID)) { content, scale in
                content.scaleEffect(reduceMotion ? 1 : scale)
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    SpringKeyframe(1.16, duration: 0.14, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.42, spring: .smooth)
                }
            }
            .frame(minWidth: size * 2.0, alignment: alignment)
    }
}

/// Team-coloured light that blooms inside the scoring team's glass region, with a highlight
/// sweeping across it. Plays once per scoring event (token change), never on appear.
struct ScoringBurst: View {
    @EnvironmentObject var pulses: ScoringPulses
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let gameID: String; let teamID: String; let color: Color; let region: StripRegion.Kind

    struct Burst { var glow = 0.0; var sweep = 0.0 }

    var body: some View {
        let reduceMotion = self.reduceMotion, color = self.color, region = self.region
        return Color.clear
            .keyframeAnimator(initialValue: Burst(), trigger: pulses.token(gameID: gameID, teamID: teamID)) { _, b in
                if b.glow > 0.001 || (b.sweep > 0 && b.sweep < 1) {
                ZStack {
                    // Soft bloom from the team's end of the strip, fading toward the centre.
                    StripRegion(kind: region).fill(RadialGradient(
                        colors: [color.opacity(0.50 * b.glow), color.opacity(0.18 * b.glow), .clear],
                        center: region == .away ? .leading : .trailing, startRadius: 0, endRadius: 170))
                    if !reduceMotion && b.sweep > 0 && b.sweep < 1 {
                        GeometryReader { geo in
                            LinearGradient(colors: [.clear, .white.opacity(0.42), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.22)
                                .rotationEffect(.degrees(14))
                                .offset(x: (-0.25 + 1.3 * b.sweep) * geo.size.width)
                                .frame(maxHeight: .infinity)
                        }
                        .mask(StripRegion(kind: region))
                    }
                }
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
                }
            } keyframes: { _ in
                KeyframeTrack(\.glow) {
                    CubicKeyframe(1, duration: 0.12)
                    CubicKeyframe(0.75, duration: 0.18)
                    CubicKeyframe(0, duration: 0.45)
                }
                KeyframeTrack(\.sweep) {
                    LinearKeyframe(0.001, duration: 0.02)
                    CubicKeyframe(0.999, duration: 0.6)
                    LinearKeyframe(1, duration: 0.01)
                }
            }
    }
}

// MARK: - Detail

struct GameDetail: View {
    let game: Game

    static func hasContent(_ g: Game) -> Bool {
        !g.away.periodScores.isEmpty || g.venue != nil || g.broadcast != nil
    }

    private var periods: Int { max(game.away.periodScores.count, game.home.periodScores.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if periods > 0 { periodTable }
            VStack(alignment: .leading, spacing: 2) {
                if game.status == .scheduled || game.status == .postponed {
                    info("clock", game.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                         + " " + (TimeZone.current.abbreviation() ?? ""))
                }
                if let v = game.venue { info("mappin.and.ellipse", v) }
                if let b = game.broadcast { info("tv", b) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func info(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 8.5)).frame(width: 11)
            Text(text).font(.system(size: 10)).lineLimit(1)
        }.foregroundStyle(Theme.textSecondary)
    }

    private func label(_ i: Int) -> String { i < 4 ? "Q\(i + 1)" : (i == 4 ? "OT" : "\(i - 3)OT") }

    private var periodTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 3) {
            GridRow {
                Text("").frame(width: 40, alignment: .leading)
                ForEach(0..<periods, id: \.self) { Text(label($0)).frame(width: 30, alignment: .trailing) }
                Text("T").frame(width: 32, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.textTertiary)
            ForEach([game.away, game.home], id: \.team.id) { side in
                GridRow {
                    Text(side.team.abbreviation).font(.system(size: 10, weight: .semibold))
                        .frame(width: 40, alignment: .leading)
                    ForEach(0..<periods, id: \.self) { i in
                        Text(i < side.periodScores.count ? "\(side.periodScores[i])" : "–")
                            .frame(width: 30, alignment: .trailing)
                    }
                    Text(side.score.map(String.init) ?? "–").fontWeight(.semibold).frame(width: 32, alignment: .trailing)
                }
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
        }
    }
}
